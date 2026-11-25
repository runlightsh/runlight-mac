import Foundation

/// A site's icon as cached: the image bytes, or empty when the site has none, and when it was asked for.
struct IconEntry: Codable, Equatable, Sendable {
    var data: Data
    var checkedAt: Date
}

/// One thing the poller fetches.
enum Job: Hashable, Sendable {
    case stats(SiteKey, Period)
    case series(SiteKey, Period)
    case goals(SiteKey, Period)
    case icon(SiteKey)
    case sites(UUID)

    var connection: UUID {
        switch self {
        case .stats(let key, _), .series(let key, _), .goals(let key, _), .icon(let key): key.connection
        case .sites(let id): id
        }
    }
}

extension AppModel {
    // MARK: What the views read

    func snapshot(_ key: SiteKey, _ period: Period? = nil) -> SiteSnapshot? {
        snapshots[period ?? self.period]?[key]
    }

    func summary(_ key: SiteKey) -> SiteSummary {
        Numbers.summary(snapshot(key), period: period, now: now())
    }

    var totals: Numbers.Totals {
        Numbers.totals(Array((snapshots[period] ?? [:]).filter { key, _ in isLive(key) }.values), period: period, now: now())
    }

    /// Visitors today across every site, for the menu bar.
    var visitorsToday: Int? {
        let today = (snapshots[.today] ?? [:]).filter { key, _ in isLive(key) }.values.compactMap(\.stats)
        return today.isEmpty ? nil : today.reduce(0) { $0 + $1.stats.visitors }
    }

    /// Sites in the order the list shows them: the most visitors first, sites with no numbers yet last.
    var rankedSites: [(key: SiteKey, connection: ConnectionState, site: Site)] {
        let entries = shownSites.map { (key: SiteKey(connection: $0.connection.id, site: $0.site.id), connection: $0.connection, site: $0.site) }
        return entries.enumerated().sorted { a, b in
            let left = snapshot(a.element.key)?.stats?.stats.visitors ?? -1
            let right = snapshot(b.element.key)?.stats?.stats.visitors ?? -1
            return left != right ? left > right : a.offset < b.offset
        }.map(\.element)
    }

    /// When the numbers on screen last changed.
    var updatedAt: Date? {
        (snapshots[period] ?? [:]).filter { key, _ in isLive(key) }.values.compactMap(\.updatedAt).max()
    }

    var isRefreshing: Bool { inFlight > 0 }

    /// Still on its install and switched on.
    private func isLive(_ key: SiteKey) -> Bool {
        isShown(key) && connections.contains { $0.id == key.connection && $0.sites.contains { $0.id == key.site } }
    }

    // MARK: Fetching

    /// Runs one job and keeps what comes back. Returns whether it worked, so the poller can back off.
    @discardableResult
    func perform(_ job: Job) async -> Bool {
        guard let client = client(for: job.connection) else { return false }
        inFlight += 1
        defer { inFlight -= 1 }
        do throws(RunlightError) {
            switch job {
            case .stats(let key, let period):
                let stats = try await client.stats(site: key.site, period: period)
                keep(key, period) { $0.stats = stats; $0.statsAt = now() }
            case .series(let key, let period):
                let series = try await client.series(site: key.site, period: period, interval: Numbers.interval(for: period), compare: "previous")
                keep(key, period) { $0.series = series; $0.seriesAt = now() }
            case .goals(let key, let period):
                let goals = try await client.goals(site: key.site, period: period)
                keep(key, period) { $0.goals = goals; $0.goalsAt = now() }
            case .icon(let key):
                let data = try await client.icon(site: key.site) ?? Data()
                icons[key] = IconEntry(data: data, checkedAt: now())
                saveIcons(key.connection)
            case .sites(let id):
                await refreshSites(id)
                return connections.first { $0.id == id }?.status.isOK ?? false
            }
            if case .stats(let key, _) = job { failures[key] = nil }
            if offline { offline = false }
            if connections.first(where: { $0.id == job.connection })?.status != .ok {
                update(job.connection) { $0.status = .ok }
            }
            return true
        } catch {
            note(error, for: job)
            return false
        }
    }

    private func keep(_ key: SiteKey, _ period: Period, _ change: (inout SiteSnapshot) -> Void) {
        var snapshot = snapshots[period]?[key] ?? SiteSnapshot()
        change(&snapshot)
        snapshots[period, default: [:]][key] = snapshot
        scheduleSave(key.connection, period)
    }

    /// Sorts a failure into the connection's status, the site's row, or the whole app being offline.
    private func note(_ error: RunlightError, for job: Job) {
        if error == .offline {
            offline = true
            return
        }
        if error.isTokenRejected {
            update(job.connection) { $0.status = .tokenRejected }
            return
        }
        switch job {
        case .stats(let key, _), .series(let key, _), .goals(let key, _):
            failures[key] = error
            // A site removed on the install drops out at the next sites refresh.
            if error.isUnknownSite { Task { await refreshSites(key.connection) } }
        case .icon(let key):
            // No icon is an answer too; try again in a week.
            icons[key] = IconEntry(data: Data(), checkedAt: now())
        case .sites:
            break
        }
    }

    // MARK: Cache

    func loadCache() {
        for state in connections {
            for period in Period.allCases {
                for (site, snapshot) in store.cached([String: SiteSnapshot].self, Self.snapshotsKey(state.id, period)) ?? [:] {
                    snapshots[period, default: [:]][SiteKey(connection: state.id, site: site)] = snapshot
                }
            }
            for (site, icon) in store.cached([String: IconEntry].self, Self.iconsKey(state.id)) ?? [:] {
                icons[SiteKey(connection: state.id, site: site)] = icon
            }
        }
    }

    /// Writes a connection's numbers for a period a moment after the last change, so a round of
    /// fourteen sites makes one write rather than forty-two.
    private func scheduleSave(_ connection: UUID, _ period: Period) {
        let name = Self.snapshotsKey(connection, period)
        saveTasks[name]?.cancel()
        saveTasks[name] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            let entries = (snapshots[period] ?? [:]).filter { $0.key.connection == connection }
            store.cache(Dictionary(uniqueKeysWithValues: entries.map { ($0.key.site, $0.value) }), name)
        }
    }

    private func saveIcons(_ connection: UUID) {
        let entries = icons.filter { $0.key.connection == connection }
        store.cache(Dictionary(uniqueKeysWithValues: entries.map { ($0.key.site, $0.value) }), Self.iconsKey(connection))
    }

    static func snapshotsKey(_ connection: UUID, _ period: Period) -> String { "\(connection.uuidString)/numbers-\(period.rawValue)" }
    static func iconsKey(_ connection: UUID) -> String { "\(connection.uuidString)/icons" }

    // MARK: Polling

    func startPolling() {
        if poller == nil { poller = Poller(model: self) }
        poller?.start()
    }

    /// The popover opened: anything older than a minute is fetched now, so it's fresh within seconds.
    func popoverOpened() {
        poller?.refresh(olderThan: 60)
    }

    /// The refresh button: everything on screen, now.
    func refreshNow() {
        poller?.refresh(olderThan: 0)
    }
}
