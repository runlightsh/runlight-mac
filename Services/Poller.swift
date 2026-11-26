import Foundation

/// Keeps the numbers fresh. Each job (a site's stats, series, or goals for a period, its icon, a
/// connection's site list) has its own interval; the poller sleeps until the next one is due rather
/// than ticking, runs a few at a time, and staggers new jobs so fourteen sites never fire at once.
///
/// The open site adds its live numbers every 15 seconds and its top lists every 2 minutes, only
/// while the popover is up.
///
/// Nothing goes out while the Mac sleeps or has no network; on waking or reconnecting, everything
/// that fell due catches up within a few seconds. Low Power Mode doubles the background intervals.
/// A job that keeps failing waits longer each time, and a connection whose token was rejected is
/// left alone until the token works again.
@MainActor
final class Poller {
    struct Intervals {
        var stats: TimeInterval = 120
        var series: TimeInterval = 300
        var goals: TimeInterval = 300
        var sites: TimeInterval = 6 * 3600
        var icon: TimeInterval = 7 * 86400
        /// While a site is open.
        var realtime: TimeInterval = 15
        var breakdown: TimeInterval = 120
        /// A pinned site's live count, for its row, while nothing is open.
        var pinnedRealtime: TimeInterval = 60
        /// For spike alerts, while they're on.
        var baseline: TimeInterval = 3600
        var sources: TimeInterval = 300
    }

    var intervals = Intervals()
    let maxConcurrent = 4

    enum PauseReason: Hashable { case sleep, offline }
    /// Why polling is stopped, if it is. Polling runs only when this is empty.
    private(set) var paused: Set<PauseReason> = []
    /// How long after waking to start again, so the network has a moment to come back.
    var wakeDelay: TimeInterval = 2
    /// Low Power Mode: background jobs come half as often. The open site's live view doesn't change.
    var lowPower = false
    /// The longest a failing job waits between tries.
    let maxBackoff: TimeInterval = 30 * 60
    /// How many times in a row each job has failed.
    private(set) var failureCounts: [Job: Int] = [:]
    private var resumeTask: Task<Void, Never>?
    /// Space between new jobs, so a fresh start fans out over a couple of seconds.
    let stagger: TimeInterval = 0.12

    /// Weak: the model owns the poller, and a fetch still on its way must not outlive it.
    private weak var model: AppModel?
    private(set) var due: [Job: Date] = [:]
    private var running: Set<Job> = []
    private var loop: Task<Void, Never>?
    private var started = false

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        started = true
        reconcile()
    }

    func stop() {
        started = false
        loop?.cancel()
        loop = nil
    }

    /// Works out which jobs should exist now (today for the menu bar, plus the period on screen, for
    /// every site) and adds the new ones, due when their cached copy goes stale.
    func reconcile() {
        guard let model else { return }
        let now = model.now()
        var wanted: [Job: Date] = [:]
        var fresh = 0
        func want(_ job: Job, last: Date?, every interval: TimeInterval) {
            if let existing = due[job] {
                wanted[job] = existing
            } else if let last, last.addingTimeInterval(interval) > now {
                wanted[job] = last.addingTimeInterval(interval)
            } else {
                wanted[job] = now.addingTimeInterval(Double(fresh) * stagger)
                fresh += 1
            }
        }
        // The open site's live numbers and top lists come first, and only while the popover is up.
        if let key = model.watchedSite {
            let detail = model.details[key]
            want(.realtime(key), last: detail?.realtimeAt, every: intervals.realtime)
            want(.breakdown(key, model.period), last: detail?.breakdowns[model.period]?.at, every: intervals.breakdown)
        }
        // A pinned site's live count, every minute, popover or not.
        if let key = model.pinnedSite, model.isShown(key), key != model.watchedSite {
            want(.realtime(key), last: model.details[key]?.realtimeAt, every: intervals.pinnedRealtime)
        }
        let periods = Set([Period.today, model.period])
        for state in model.connections {
            want(.sites(state.id), last: state.lastChecked, every: intervals.sites)
            for site in state.sites {
                let key = SiteKey(connection: state.id, site: site.id)
                // A switched-off site keeps its icon for Settings but fetches no numbers.
                want(.icon(key), last: model.icons[key]?.checkedAt, every: intervals.icon)
                guard model.isShown(key) else { continue }
                if model.alertsOn(key) {
                    want(.baseline(key), last: model.baselines[key]?.at, every: intervals.baseline)
                    want(.sources(key), last: model.sourceHistory[key]?.last?.at, every: intervals.sources)
                }
                for period in Period.allCases where periods.contains(period) {
                    let snapshot = model.snapshot(key, period)
                    want(.stats(key, period), last: snapshot?.statsAt, every: intervals.stats)
                    want(.series(key, period), last: snapshot?.seriesAt, every: intervals.series)
                    want(.goals(key, period), last: snapshot?.goalsAt, every: intervals.goals)
                }
            }
        }
        due = wanted
        wake()
    }

    /// Makes every number job for the period on screen due now if its copy is older than `age`.
    func refresh(olderThan age: TimeInterval, stagger: TimeInterval? = nil) {
        guard let model else { return }
        let stagger = stagger ?? self.stagger
        let now = model.now()
        var index = 0
        for job in due.keys {
            let (last, period): (Date?, Period?) = switch job {
            case .stats(let key, let period): (model.snapshot(key, period)?.statsAt, period)
            case .series(let key, let period): (model.snapshot(key, period)?.seriesAt, period)
            case .goals(let key, let period): (model.snapshot(key, period)?.goalsAt, period)
            case .realtime(let key): (model.details[key]?.realtimeAt, model.period)
            case .breakdown(let key, let period): (model.details[key]?.breakdowns[period]?.at, period)
            default: (nil, nil)
            }
            guard let period, period == model.period || period == .today else { continue }
            if last.map({ now.timeIntervalSince($0) >= age }) ?? true {
                due[job] = now.addingTimeInterval(Double(index) * stagger)
                index += 1
            }
        }
        wake()
    }

    /// The refresh interval from Settings: today's headline numbers every so many minutes, and the
    /// charts and goals no more often than every five.
    func setRefresh(minutes: Int) {
        let seconds = TimeInterval(minutes * 60)
        intervals.stats = seconds
        intervals.series = max(300, seconds)
        intervals.goals = max(300, seconds)
    }

    // MARK: Pausing

    func pause(_ reason: PauseReason) {
        resumeTask?.cancel()
        paused.insert(reason)
        loop?.cancel()
        loop = nil
    }

    /// Lifts one reason to pause. When none is left, everything that fell due while paused runs,
    /// staggered, after a short wait on waking.
    func resume(_ reason: PauseReason) {
        guard paused.contains(reason) else { return }
        paused.remove(reason)
        guard paused.isEmpty else { return }
        resumeTask?.cancel()
        let delay = reason == .sleep ? wakeDelay : 0
        resumeTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self, paused.isEmpty else { return }
            catchUp()
        }
    }

    /// After a pause: jobs that fell due, or failed on the way into it, run now, a little apart.
    private func catchUp() {
        guard let model else { return }
        let now = model.now()
        let behind = due.filter { $0.value <= now || failureCounts[$0.key] != nil }.sorted { $0.value < $1.value }
        for (index, entry) in behind.enumerated() {
            due[entry.key] = now.addingTimeInterval(Double(index) * stagger)
        }
        // A fresh start: failures from before the pause were most likely the pause itself.
        failureCounts = [:]
        wake()
    }

    /// A connection that works again (a new token, say) catches up at once rather than waiting out its back-off.
    func retry(connection: UUID) {
        guard let model else { return }
        let now = model.now()
        var index = 0
        for job in due.keys where job.connection == connection {
            failureCounts[job] = nil
            due[job] = now.addingTimeInterval(Double(index) * stagger)
            index += 1
        }
        wake()
    }

    private func wake() {
        guard started, paused.isEmpty else { return }
        loop?.cancel()
        loop = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        while !Task.isCancelled {
            guard let model else { return }
            let now = model.now()
            // The open site's jobs go first: someone is looking at them.
            let ready = due.filter { $0.value <= now && !running.contains($0.key) }.sorted {
                $0.key.isDetail != $1.key.isDetail ? $0.key.isDetail : $0.value < $1.value
            }
            for (job, _) in ready.prefix(max(0, maxConcurrent - running.count)) {
                running.insert(job)
                Task { [weak self] in
                    guard let self, let model = self.model else { return }
                    let worked = await model.perform(job)
                    running.remove(job)
                    noteResult(job, worked: worked)
                    if due[job] != nil {
                        due[job] = model.now().addingTimeInterval(interval(for: job))
                    }
                    wake()
                }
            }
            let waiting = due.filter { !running.contains($0.key) }.values
            guard let next = waiting.min() else { return }
            let pause = max(0.05, next.timeIntervalSince(model.now()))
            if running.count >= maxConcurrent { return } // A finishing job wakes the loop.
            do { try await Task.sleep(for: .seconds(pause)) } catch { return }
        }
    }

    /// Counts a job's failures in a row; a success clears them.
    func noteResult(_ job: Job, worked: Bool) {
        failureCounts[job] = worked ? nil : (failureCounts[job] ?? 0) + 1
    }

    /// How long until a job runs again, after it just ran.
    func interval(for job: Job) -> TimeInterval {
        let base: TimeInterval = switch job {
        case .stats: intervals.stats
        case .series: intervals.series
        case .goals: intervals.goals
        case .sites: intervals.sites
        case .icon: intervals.icon
        case .realtime(let key): model?.watchedSite == key ? intervals.realtime : intervals.pinnedRealtime
        case .breakdown: intervals.breakdown
        case .baseline: intervals.baseline
        case .sources: intervals.sources
        }
        // A rejected token won't start working by itself; check back now and then.
        if model?.connections.first(where: { $0.id == job.connection })?.status.needsToken == true {
            return maxBackoff
        }
        if let failures = failureCounts[job] {
            switch job {
            case .realtime:
                // Someone is watching: keep trying, a little slower.
                return min(base * Double(failures + 1), 60)
            case .icon, .sites:
                // These wait their full interval anyway.
                return base
            default:
                // A minute, then two, four, eight, and so on, up to half an hour.
                return min(60 * pow(2, Double(failures - 1)), maxBackoff)
            }
        }
        return lowPower && !job.isDetail ? base * 2 : base
    }
}
