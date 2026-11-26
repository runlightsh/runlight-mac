import Foundation

/// Keeps the numbers fresh. Each job (a site's stats, series, or goals for a period, its icon, a
/// connection's site list) has its own interval; the poller sleeps until the next one is due rather
/// than ticking, runs a few at a time, and staggers new jobs so fourteen sites never fire at once.
///
/// The open site adds its live numbers every 15 seconds and its top lists every 2 minutes, only
/// while the popover is up. Milestone 6 adds pausing on sleep and offline, Low Power Mode, and backing off after failures.
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
    }

    var intervals = Intervals()
    let maxConcurrent = 4
    /// Space between new jobs, so a fresh start fans out over a couple of seconds.
    let stagger: TimeInterval = 0.12

    private unowned let model: AppModel
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
        let periods = Set([Period.today, model.period])
        for state in model.connections {
            want(.sites(state.id), last: state.lastChecked, every: intervals.sites)
            for site in state.sites {
                let key = SiteKey(connection: state.id, site: site.id)
                // A switched-off site keeps its icon for Settings but fetches no numbers.
                want(.icon(key), last: model.icons[key]?.checkedAt, every: intervals.icon)
                guard model.isShown(key) else { continue }
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

    private func wake() {
        guard started else { return }
        loop?.cancel()
        loop = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        while !Task.isCancelled {
            let now = model.now()
            // The open site's jobs go first: someone is looking at them.
            let ready = due.filter { $0.value <= now && !running.contains($0.key) }.sorted {
                $0.key.isDetail != $1.key.isDetail ? $0.key.isDetail : $0.value < $1.value
            }
            for (job, _) in ready.prefix(max(0, maxConcurrent - running.count)) {
                running.insert(job)
                Task { [weak self] in
                    guard let self else { return }
                    let worked = await model.perform(job)
                    running.remove(job)
                    if due[job] != nil {
                        due[job] = model.now().addingTimeInterval(interval(for: job, worked: worked))
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

    private func interval(for job: Job, worked: Bool) -> TimeInterval {
        let base: TimeInterval = switch job {
        case .stats: intervals.stats
        case .series: intervals.series
        case .goals: intervals.goals
        case .sites: intervals.sites
        case .icon: intervals.icon
        case .realtime: intervals.realtime
        case .breakdown: intervals.breakdown
        }
        // A failed icon or site list waits its full interval; a failed number tries again in a minute.
        if !worked, case .stats = job { return 60 }
        if !worked, case .series = job { return 60 }
        if !worked, case .goals = job { return 60 }
        if !worked, case .breakdown = job { return 60 }
        return base
    }
}
