import Foundation

/// The numbers spike alerts are measured against: the last 30 days by the hour, and the goals over
/// the same days for the usual conversion rate. Fetched hourly.
struct Baseline: Equatable, Sendable {
    var month: SeriesResponse?
    var goals: GoalsResponse?
    var at: Date
}

extension AppModel {
    // MARK: Settings

    func alertsOn(_ key: SiteKey) -> Bool {
        alertSettings.enabled && isShown(key) && !alertSettings.mutedSites.contains(key.storageKey)
    }

    func setAlerts(_ key: SiteKey, on: Bool) {
        if on { alertSettings.mutedSites.remove(key.storageKey) } else { alertSettings.mutedSites.insert(key.storageKey) }
    }

    /// Turning alerts on asks macOS for permission the first time; if it's refused, they stay off
    /// and Settings says where to allow them.
    func setAlertsEnabled(_ on: Bool) async {
        guard on else {
            alertSettings.enabled = false
            return
        }
        let allowed = await notifier.requestPermission()
        notificationsRefused = !allowed
        alertSettings.enabled = allowed
    }

    /// A sample alert, so the look and sound can be checked.
    func sendTestAlert() {
        guard let entry = rankedSites.first else { return }
        let spike = Spike(kind: .visitors, count: 420, usual: 70, top: "photzy.com", at: now())
        let text = Self.alertText(spike, siteName: entry.site.name)
        notifier.post(id: "test-\(UUID().uuidString)", title: text.title, body: text.body, site: entry.key)
    }

    // MARK: Checking

    /// Looks for a visitor or conversion spike on a site after fresh numbers arrive, and sends an
    /// alert unless one went out for it lately or it's quiet hours.
    func checkSpikes(_ key: SiteKey) async {
        guard alertsOn(key), let site = allSites.first(where: { $0.connection.id == key.connection && $0.site.id == key.site })?.site,
              let month = baselines[key]?.month else { return }
        let timeZone = TimeZone(identifier: site.timezone) ?? .current
        let now = now()

        if let today = snapshot(key, .today)?.series,
           var spike = SpikeDetector.visitorSpike(today: today, month: month, timeZone: timeZone, now: now, multiplier: alertSettings.multiplier) {
            spike.top = await topSource(key)
            spikes[key] = spike
            fire(spike, key: key, siteName: site.name)
        } else {
            spikes[key] = nil
        }

        if alertSettings.conversions, let spike = conversionSpike(key, month: month, timeZone: timeZone, now: now) {
            fire(spike, key: key, siteName: site.name)
        }
    }

    private func conversionSpike(_ key: SiteKey, month: SeriesResponse, timeZone: TimeZone, now: Date) -> Spike? {
        guard let history = goalHistory[key], let current = history.last, let before = Tally.hourAgo(history, now: now),
              let goals = baselines[key]?.goals, let monthVisitors = goals.visitors, monthVisitors > 0,
              let usual = SpikeDetector.usualByHour(month, timeZone: timeZone, now: now) else { return nil }
        let sameDay = current.day == before.day
        let conversions = sameDay ? current.total - before.total : current.total
        let monthConversions = goals.goals.reduce(0) { $0 + $1.numbers.conversions }
        // The visitors the last sixty minutes usually bring, across the hour boundary.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let hour = calendar.component(.hour, from: now)
        let passed = Double(calendar.component(.minute, from: now)) / 60
        let usualVisitors = usual[hour] * passed + usual[(hour + 23) % 24] * (1 - passed)
        guard var spike = SpikeDetector.conversionSpike(
            lastHour: conversions, usualVisitors: usualVisitors,
            monthRate: Double(monthConversions) / Double(monthVisitors), now: now, multiplier: alertSettings.multiplier
        ) else { return nil }
        spike.top = SpikeDetector.topGrowth(now: current.counts, before: sameDay ? before.counts : nil)
        return spike
    }

    /// The source that sent the most visitors in the last hour, from two counts of today's sources
    /// an hour apart; until there is one an hour old, the top source of the last five minutes.
    private func topSource(_ key: SiteKey) async -> String? {
        if let history = sourceHistory[key], let current = history.last, let before = Tally.hourAgo(history, now: now()),
           let top = SpikeDetector.topGrowth(now: current.counts, before: current.day == before.day ? before.counts : nil) {
            return Self.sourceName(top)
        }
        var realtime = details[key]?.realtime
        if realtime == nil, let client = client(for: key.connection) {
            realtime = try? await client.realtime(site: key.site)
        }
        return realtime?.sources.first.map { Self.sourceName($0.value) }
    }

    static func sourceName(_ value: String) -> String { value.isEmpty ? "Direct" : value }

    private func fire(_ spike: Spike, key: SiteKey, siteName: String) {
        let id = "\(key.storageKey)#\(spike.kind.rawValue)"
        let now = now()
        if let last = lastAlerts[id], now.timeIntervalSince(last) < SpikeDetector.cooldown { return }
        // Quiet hours drop the alert rather than save it for the morning.
        if alertSettings.isQuiet(at: now) { return }
        lastAlerts[id] = now
        spikeLit = true
        let text = Self.alertText(spike, siteName: siteName)
        notifier.post(id: "\(id)@\(Int(now.timeIntervalSince1970))", title: text.title, body: text.body, site: key)
    }

    /// "DailyPhotoTips is spiking" / "420 visitors in the last hour, 6× usual. Top source: photzy.com."
    nonisolated static func alertText(_ spike: Spike, siteName: String) -> (title: String, body: String) {
        switch spike.kind {
        case .visitors:
            let top = spike.top.map { " Top source: \($0)." } ?? ""
            return ("\(siteName) is spiking", "\(spike.count.formatted(.number)) visitors in the last hour, \(spike.ratioText).\(top)")
        case .conversions:
            let top = spike.top.map { " Most from \($0)." } ?? ""
            let noun = spike.count == 1 ? "conversion" : "conversions"
            return ("\(siteName) conversions are up", "\(spike.count.formatted(.number)) \(noun) in the last hour, \(spike.ratioText).\(top)")
        }
    }

    /// An alert was clicked: open the popover on that site, today.
    func openFromAlert(_ key: SiteKey) {
        guard allSites.contains(where: { $0.connection.id == key.connection && $0.site.id == key.site }) else { return }
        period = .today
        if onlySite == nil { expandedSite = key }
    }

    // MARK: Keeping counts

    func keepSources(_ key: SiteKey, _ response: BreakdownResponse) {
        let counts = Dictionary(response.rows.map { ($0.value, $0.visitors) }, uniquingKeysWith: +)
        sourceHistory[key] = Self.trimmed((sourceHistory[key] ?? []) + [Tally(at: now(), day: response.range.from, counts: counts)], now: now())
    }

    func keepGoals(_ key: SiteKey, _ response: GoalsResponse) {
        let counts = Dictionary(response.goals.map { ($0.goal.name, $0.numbers.conversions) }, uniquingKeysWith: +)
        goalHistory[key] = Self.trimmed((goalHistory[key] ?? []) + [Tally(at: now(), day: response.range?.from ?? "", counts: counts)], now: now())
    }

    /// Two hours of counts is plenty to find one an hour old.
    private static func trimmed(_ history: [Tally], now: Date) -> [Tally] {
        history.filter { now.timeIntervalSince($0.at) <= 2 * 3600 }
    }
}
