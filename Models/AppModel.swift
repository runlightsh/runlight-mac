import Foundation
import Observation

/// Why connecting didn't work, said so the person knows what to fix, next to the field to fix.
struct ConnectError: Error, Equatable, Sendable {
    enum Field: Sendable { case address, token }

    let field: Field
    let message: String

    static let emptyAddress = ConnectError(field: .address, message: "Enter the install's address.")
    static let emptyToken = ConnectError(field: .token, message: "Paste a read-only token.")
    static let notRunlight = ConnectError(field: .address, message: "That address didn't answer like a Runlight install. Check it, including any /runlight on the end.")
    static let tokenRejected = ConnectError(field: .token, message: "Token rejected. Check it was copied whole and hasn't been deleted.")
    static let manageToken = ConnectError(field: .token, message: "This is a manage token, which changes one site. Connect with a read-only token; manage tokens are added per site later.")
    static let embedToken = ConnectError(field: .token, message: "This is a dashboard key for a CMS plugin. Make a read-only token in Settings, MCP & API.")
    static let installSecret = ConnectError(field: .token, message: "This is the install's own secret, which can change everything. Make a read-only token in Settings, MCP & API instead.")
    static let alreadyConnected = ConnectError(field: .address, message: "This install is already connected. Replace its token in Settings, Connections.")

    static func scope(_ scope: String) -> ConnectError {
        ConnectError(field: .token, message: "This token's scope is \u{201C}\(scope)\u{201D}. Make a read-only token in Settings, MCP & API.")
    }

    static func network(_ error: RunlightError) -> ConnectError {
        ConnectError(field: .address, message: error.message)
    }
}

/// The steps of connecting, for the button's label while it works.
enum ConnectStep: Equatable, Sendable {
    case finding, checkingToken, loadingSites

    var label: String {
        switch self {
        case .finding: "Finding Runlight…"
        case .checkingToken: "Checking token…"
        case .loadingSites: "Loading sites…"
        }
    }
}

/// How a connection is doing, shown on its row in Settings and as a banner in the popover.
enum ConnectionStatus: Equatable, Sendable {
    case ok
    case checking
    case tokenRejected
    /// The Keychain has no token for it, as after a token is removed by hand.
    case tokenMissing
    case offline
    case problem(String)

    var isOK: Bool { self == .ok }
    /// Fixed only by a new token.
    var needsToken: Bool { self == .tokenRejected || self == .tokenMissing }
}

/// One install as the app sees it: its details, its sites, and how it's doing.
struct ConnectionState: Identifiable, Equatable, Sendable {
    var connection: Connection
    var sites: [Site]
    var status: ConnectionStatus
    var token: TokenInfo?
    var lastChecked: Date?

    var id: UUID { connection.id }
}

/// One site of one connection: sites from two installs may share an id.
struct SiteKey: Hashable, Codable, Sendable {
    let connection: UUID
    let site: String

    /// "<connection>/<site>", for UserDefaults.
    var storageKey: String { "\(connection.uuidString)/\(site)" }

    init(connection: UUID, site: String) {
        self.connection = connection
        self.site = site
    }

    init?(storageKey: String) {
        guard let slash = storageKey.firstIndex(of: "/"), let id = UUID(uuidString: String(storageKey[..<slash])) else { return nil }
        self.init(connection: id, site: String(storageKey[storageKey.index(after: slash)...]))
    }
}

/// Everything the views read: connections, their sites, and the numbers for each.
@MainActor
@Observable
final class AppModel {
    private(set) var connections: [ConnectionState] = [] {
        didSet {
            // A connection that starts working again catches up at once.
            for state in connections where state.status == .ok {
                if let before = oldValue.first(where: { $0.id == state.id }), before.status != .ok, before.status != .checking {
                    poller?.retry(connection: state.id)
                }
            }
        }
    }
    /// Whether Settings shows the Add Connection sheet. The popover sets it before opening Settings.
    var addingConnection = false

    /// The period the popover shows, kept between launches.
    var period: Period = .today {
        didSet {
            defaults.set(period.rawValue, forKey: "period")
            poller?.reconcile()
        }
    }
    /// The order sites were dragged into in Settings, as storage keys. Sites not in it follow, in the install's order.
    var siteOrder: [SiteKey] = [] {
        didSet { defaults.set(siteOrder.map(\.storageKey), forKey: "siteOrder") }
    }
    /// Changes when a manage token is added or removed, so views asking `canEdit` look again.
    var manageTokens = 0
    /// The site being dragged in Settings, shown as a placeholder while the others move around it.
    var draggingSite: SiteKey?
    /// Whether the popover lists sites in that order rather than busiest first.
    var usesCustomOrder = false {
        didSet { defaults.set(usesCustomOrder, forKey: "customSiteOrder") }
    }
    /// Spike alert settings, kept as one value.
    var alertSettings = AlertSettings() {
        didSet {
            if let data = try? JSONEncoder().encode(alertSettings) { defaults.set(data, forKey: "alerts") }
            if alertSettings.enabled != oldValue.enabled || alertSettings.mutedSites != oldValue.mutedSites { poller?.reconcile() }
            if !alertSettings.enabled { spikes = [:] }
        }
    }
    /// macOS said no when asked for notifications, so Settings shows where to allow them.
    var notificationsRefused = false
    /// What spike alerts are measured against, per site.
    var baselines: [SiteKey: Baseline] = [:]
    /// Today's sources and conversions per goal, counted every few minutes for the last two hours.
    @ObservationIgnored var sourceHistory: [SiteKey: [Tally]] = [:]
    @ObservationIgnored var goalHistory: [SiteKey: [Tally]] = [:]
    /// Sites spiking now, for the badge on their rows.
    var spikes: [SiteKey: Spike] = [:]
    /// When each site last alerted, per kind, so one spike doesn't alert again for two hours.
    @ObservationIgnored var lastAlerts: [String: Date] = [:] {
        didSet { defaults.set(lastAlerts.mapValues(\.timeIntervalSince1970), forKey: "lastAlerts") }
    }
    /// The menu bar lamp lights after an alert, until the popover is opened.
    var spikeLit = false
    @ObservationIgnored var notifier: any Notifier = SystemNotifier()
    /// Whether a site opens in Runlight's dashboard window, or else the default browser.
    var opensSitesInWindow = true {
        didSet { defaults.set(opensSitesInWindow, forKey: "openSitesInWindow") }
    }
    /// Told when a connection is removed, so its dashboard window can close.
    @ObservationIgnored var connectionRemoved: (UUID) -> Void = { _ in }
    /// What sits beside the icon in the menu bar: nothing, the total, or one pinned site.
    var menuBarDisplay: MenuBarDisplay = .total {
        didSet {
            defaults.set(menuBarDisplay.stored, forKey: "menuBar")
            if menuBarDisplay != oldValue { poller?.reconcile() }
        }
    }
    /// How often the numbers are fetched in the background, in minutes: 1, 2, 5, or 15.
    var refreshMinutes = 2 {
        didSet {
            defaults.set(refreshMinutes, forKey: "refreshMinutes")
            poller?.setRefresh(minutes: refreshMinutes)
        }
    }
    static let refreshChoices = [1, 2, 5, 15]
    /// The last good numbers for each period and site.
    var snapshots: [Period: [SiteKey: SiteSnapshot]] = [:]
    /// Why a site's last fetch failed, until one works.
    var failures: [SiteKey: RunlightError] = [:]
    /// Each site's icon, as fetched, and when it was last asked for (an empty Data means it has none).
    var icons: [SiteKey: IconEntry] = [:]
    /// Sites switched off in Settings: left out of the list, the totals, the menu bar, and polling.
    var hiddenSites: Set<SiteKey> = [] {
        didSet {
            defaults.set(hiddenSites.map(\.storageKey).sorted(), forKey: "hiddenSites")
            poller?.reconcile()
        }
    }
    /// The site opened up under its row, if any. Only one at a time.
    var expandedSite: SiteKey? {
        didSet { if expandedSite != oldValue { poller?.reconcile() } }
    }
    /// Live visitors and top pages and sources, fetched only for the site that's open.
    var details: [SiteKey: SiteDetail] = [:]
    /// Whether the popover is on screen. Live numbers are fetched only while it is.
    @ObservationIgnored private(set) var popoverVisible = false
    /// How many fetches are under way.
    var inFlight = 0 {
        didSet { settleRefreshing() }
    }
    /// Whether the refresh button turns: true while fetches are under way, and until none has run
    /// for a moment, so a round of quick staggered fetches reads as one refresh rather than a flicker.
    var isRefreshing = false
    @ObservationIgnored var settleTask: Task<Void, Never>?
    /// True while the network is down; numbers stay, greyed.
    var offline = false

    @ObservationIgnored var poller: Poller?
    @ObservationIgnored var conditions: SystemConditions?
    @ObservationIgnored var saveTasks: [String: Task<Void, Never>] = [:]

    let store: ConnectionStore
    /// Where choices like the period and hidden sites are kept; tests pass their own.
    let defaults: UserDefaults
    private let vault: TokenVault
    let session: URLSession
    let now: @Sendable () -> Date

    init(store: ConnectionStore = .standard, vault: TokenVault = Keychain(), session: URLSession = .shared, defaults: UserDefaults = .standard, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.defaults = defaults
        period = Period(rawValue: defaults.string(forKey: "period") ?? "") ?? .today
        // An earlier version had only a switch for the total.
        menuBarDisplay = defaults.string(forKey: "menuBar").flatMap(MenuBarDisplay.init(stored:))
            ?? (defaults.object(forKey: "menuBarTotal") as? Bool == false ? .icon : .total)
        refreshMinutes = Self.refreshChoices.contains(defaults.integer(forKey: "refreshMinutes")) ? defaults.integer(forKey: "refreshMinutes") : 2
        siteOrder = (defaults.stringArray(forKey: "siteOrder") ?? []).compactMap(SiteKey.init(storageKey:))
        usesCustomOrder = defaults.bool(forKey: "customSiteOrder")
        opensSitesInWindow = defaults.object(forKey: "openSitesInWindow") as? Bool ?? true
        alertSettings = defaults.data(forKey: "alerts").flatMap { try? JSONDecoder().decode(AlertSettings.self, from: $0) } ?? AlertSettings()
        lastAlerts = ((defaults.dictionary(forKey: "lastAlerts") as? [String: Double]) ?? [:]).mapValues(Date.init(timeIntervalSince1970:))
        hiddenSites = Set((defaults.stringArray(forKey: "hiddenSites") ?? []).compactMap(SiteKey.init(storageKey:)))
        self.vault = vault
        self.session = session
        self.now = now
        connections = store.loadConnections().map { connection in
            ConnectionState(
                connection: connection, sites: store.cached([Site].self, Self.sitesKey(connection.id)) ?? [],
                status: vault.token(for: VaultAccount.read(connection.id)) == nil ? .tokenMissing : .ok
            )
        }
        loadCache()
    }

    var isEmpty: Bool { connections.isEmpty }

    /// Every site across every connection, in connection order and then the order set in Settings,
    /// switched off or not.
    var allSites: [(connection: ConnectionState, site: Site)] {
        connections.flatMap { state in orderedSites(state).map { (state, $0) } }
    }

    /// A connection's sites in the order dragged into in Settings; new ones go at the end.
    func orderedSites(_ state: ConnectionState) -> [Site] {
        let position = Dictionary(siteOrder.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return state.sites.enumerated().sorted { a, b in
            let left = position[SiteKey(connection: state.id, site: a.element.id)] ?? Int.max
            let right = position[SiteKey(connection: state.id, site: b.element.id)] ?? Int.max
            return left != right ? left < right : a.offset < b.offset
        }.map(\.element)
    }

    /// Moves a site to where another one is, within its connection, and lists the popover in that order.
    func moveSite(_ moving: SiteKey, to target: SiteKey) {
        guard moving != target, moving.connection == target.connection,
              let state = connections.first(where: { $0.id == moving.connection }) else { return }
        var keys = orderedSites(state).map { SiteKey(connection: state.id, site: $0.id) }
        guard let from = keys.firstIndex(of: moving), let to = keys.firstIndex(of: target) else { return }
        keys.remove(at: from)
        keys.insert(moving, at: to)
        siteOrder = siteOrder.filter { $0.connection != state.id } + keys
        usesCustomOrder = true
    }

    /// The sites that are switched on.
    var shownSites: [(connection: ConnectionState, site: Site)] {
        allSites.filter { !hiddenSites.contains(SiteKey(connection: $0.connection.id, site: $0.site.id)) }
    }

    func isShown(_ key: SiteKey) -> Bool { !hiddenSites.contains(key) }

    func setShown(_ key: SiteKey, _ shown: Bool) {
        if !shown, expandedSite == key { expandedSite = nil }
        // A site switched off can't stay pinned.
        if !shown, menuBarDisplay == .site(key) { menuBarDisplay = .total }
        if shown { hiddenSites.remove(key) } else { hiddenSites.insert(key) }
    }

    /// The site whose live numbers should be fetched now: the open one, while the popover is up.
    var watchedSite: SiteKey? {
        guard popoverVisible, let key = openSite, isShown(key) else { return nil }
        return connections.contains { $0.id == key.connection && $0.sites.contains { $0.id == key.site } } ? key : nil
    }

    /// The only site shown, when there is just one: it stays open, since there's nothing to choose between.
    var onlySite: SiteKey? {
        let shown = shownSites
        guard shown.count == 1, let entry = shown.first else { return nil }
        return SiteKey(connection: entry.connection.id, site: entry.site.id)
    }

    /// The site whose detail shows: the only one, or the one clicked open.
    var openSite: SiteKey? { onlySite ?? expandedSite }

    func toggleExpanded(_ key: SiteKey) {
        guard onlySite == nil else { return }
        expandedSite = expandedSite == key ? nil : key
    }

    /// Escape folds an open site away before it closes the popover. Returns whether it did.
    func collapse() -> Bool {
        guard onlySite == nil, expandedSite != nil else { return false }
        expandedSite = nil
        return true
    }

    func setPopoverVisible(_ visible: Bool) {
        guard popoverVisible != visible else { return }
        popoverVisible = visible
        poller?.reconcile()
    }

    /// The site in the web dashboard, on the same period.
    func dashboardURL(_ key: SiteKey) -> URL? {
        connections.first { $0.id == key.connection }.flatMap { Self.dashboardURL(base: $0.connection.baseURL, site: key.site, period: period) }
    }

    /// The connection a dashboard address belongs to: the one whose address it starts with, the longest if several do.
    func connection(for url: URL) -> Connection? {
        connections.map(\.connection)
            .filter { DashboardPolicy.sameOrigin(url, $0.baseURL) && url.path.hasPrefix($0.baseURL.path) }
            .max { $0.baseURL.path.count < $1.baseURL.path.count }
    }

    /// The dashboard is served where the API is, and reads the site and period from the query.
    static func dashboardURL(base: URL, site: String, period: Period) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        if !components.percentEncodedPath.hasSuffix("/") { components.percentEncodedPath += "/" }
        components.queryItems = [URLQueryItem(name: "site", value: site), URLQueryItem(name: "period", value: period.rawValue)]
        return components.url
    }

    func client(for id: UUID) -> RunlightClient? {
        guard let state = connections.first(where: { $0.id == id }), let token = vault.token(for: VaultAccount.read(id)) else { return nil }
        return RunlightClient(baseURL: state.connection.baseURL, token: token, session: session)
    }

    // MARK: Manage tokens

    /// Whether a site can be edited: a manage token for it is in the Keychain. Read through
    /// `manageTokens` so views update when one is added or removed.
    func canEdit(_ key: SiteKey) -> Bool {
        _ = manageTokens
        return vault.token(for: VaultAccount.manage(key.connection, site: key.site)) != nil
    }

    /// A client that edits one site, with its manage token.
    func manageClient(for key: SiteKey) -> RunlightClient? {
        guard let state = connections.first(where: { $0.id == key.connection }),
              let token = vault.token(for: VaultAccount.manage(key.connection, site: key.site)) else { return nil }
        return RunlightClient(baseURL: state.connection.baseURL, token: token, session: session)
    }

    /// Checks a pasted manage token against the install and keeps it for this one site.
    func addManageToken(_ key: SiteKey, token rawToken: String) async throws(ConnectError) {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ConnectError(field: .token, message: "Paste the site's manage token.") }
        guard let state = connections.first(where: { $0.id == key.connection }) else { return }
        let name = state.sites.first { $0.id == key.site }?.name ?? key.site
        let info: TokenInfo
        do {
            info = try await RunlightClient(baseURL: state.connection.baseURL, token: token, session: session).tokenInfo()
        } catch {
            if error.isTokenRejected { throw .tokenRejected }
            throw .network(error)
        }
        switch info.scope {
        case .manage where info.site == key.site:
            break
        case .manage:
            let other = state.sites.first { $0.id == info.site }?.name ?? info.site
            throw ConnectError(field: .token, message: "This manage token is for \(other). Make one for \(name) in the dashboard, under Settings, MCP & API.")
        case .read:
            throw ConnectError(field: .token, message: "This is a read-only token. Editing \(name) needs a manage token made for it, under Settings, MCP & API.")
        default:
            throw ConnectError(field: .token, message: "This isn't a manage token. Make one for \(name) in the dashboard, under Settings, MCP & API.")
        }
        do {
            try vault.setToken(token, for: VaultAccount.manage(key.connection, site: key.site))
        } catch {
            throw ConnectError(field: .token, message: "Couldn't save the token in the Keychain (\(error)).")
        }
        manageTokens += 1
    }

    /// Allows editing a site by signing in to the install in the browser and allowing the app there,
    /// rather than copying a token: the install hands back a manage token for this one site.
    func allowEditing(_ key: SiteKey, timeout: TimeInterval = 300, open: @escaping @MainActor (URL) -> Void) async throws(ConnectError) {
        guard let state = connections.first(where: { $0.id == key.connection }) else { return }
        let name = state.sites.first { $0.id == key.site }?.name ?? key.site
        let grant: OAuthLoopback.Grant
        do {
            grant = try await OAuthLoopback.token(base: state.connection.baseURL, scope: "manage", site: key.site, session: session, timeout: timeout, open: open)
        } catch {
            throw ConnectError(field: .token, message: error.message)
        }
        // The page lets the person pick another site; this window is for one.
        if let site = grant.site, site != key.site {
            let other = state.sites.first { $0.id == site }?.name ?? site
            throw ConnectError(field: .token, message: "That allowed editing \(other), not \(name). Try again and pick \(name) on the page.")
        }
        try await addManageToken(key, token: grant.access_token)
    }

    /// Forgets a site's manage token; the site goes back to read-only.
    func removeManageToken(_ key: SiteKey) {
        vault.removeToken(for: VaultAccount.manage(key.connection, site: key.site))
        manageTokens += 1
    }

    // MARK: Connecting

    /// Checks an address and a token and, when both are right, saves the connection: the token in
    /// the Keychain, the rest on disk. Reports each step so the button can say what it's doing.
    @discardableResult
    func connect(address: String, token rawToken: String, progress: @MainActor (ConnectStep) -> Void = { _ in }) async throws(ConnectError) -> ConnectionState {
        let verified = try await verify(address: address, token: rawToken, progress: progress)
        if connections.contains(where: { $0.connection.baseURL == verified.baseURL }) { throw .alreadyConnected }

        let connection = Connection(id: UUID(), name: Self.name(for: verified.baseURL), baseURL: verified.baseURL, version: verified.info.version, addedAt: now())
        do {
            try vault.setToken(verified.token, for: VaultAccount.read(connection.id))
        } catch {
            throw ConnectError(field: .token, message: "Couldn't save the token in the Keychain (\(error)).")
        }
        let state = ConnectionState(connection: connection, sites: verified.sites, status: .ok, token: verified.tokenInfo, lastChecked: now())
        connections.append(state)
        persist()
        store.cache(verified.sites, Self.sitesKey(connection.id))
        poller?.reconcile()
        return state
    }

    /// Gives a connection a new token, after checking it against the same install. The old token
    /// stays until the new one is known to work.
    func replaceToken(_ id: UUID, with rawToken: String) async throws(ConnectError) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        let verified = try await verify(address: connections[index].connection.baseURL.absoluteString, token: rawToken)
        do {
            try vault.setToken(verified.token, for: VaultAccount.read(id))
        } catch {
            throw ConnectError(field: .token, message: "Couldn't save the token in the Keychain (\(error)).")
        }
        connections[index].sites = verified.sites
        connections[index].token = verified.tokenInfo
        connections[index].status = .ok
        connections[index].connection.version = verified.info.version
        connections[index].lastChecked = now()
        persist()
        store.cache(verified.sites, Self.sitesKey(id))
        poller?.reconcile()
    }

    /// Asks the install again: is it there, does the token still work, which sites does it see.
    func test(_ id: UUID) async {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        guard let client = client(for: id) else {
            connections[index].status = .tokenMissing
            return
        }
        connections[index].status = .checking
        let status: ConnectionStatus
        do {
            let info = try await client.install()
            let tokenInfo = try await client.tokenInfo()
            let sites = try await client.sites()
            update(id) { state in
                state.connection.version = info.version
                state.token = tokenInfo
                state.sites = sites
            }
            store.cache(sites, Self.sitesKey(id))
            status = .ok
        } catch {
            status = Self.status(for: error)
        }
        update(id) { state in
            state.status = status
            state.lastChecked = now()
        }
        persist()
        poller?.reconcile()
    }

    /// Refreshes the site list only, for the six-hourly poll and after a 404 `unknown_site`.
    func refreshSites(_ id: UUID) async {
        guard let client = client(for: id) else { return }
        do {
            let sites = try await client.sites()
            update(id) { state in
                state.sites = sites
                state.status = .ok
            }
            store.cache(sites, Self.sitesKey(id))
            poller?.reconcile()
        } catch {
            update(id) { $0.status = Self.status(for: error) }
        }
    }

    /// Forgets a connection: its token, its details, and its cached numbers. The token itself stays
    /// valid on the install until it's deleted there.
    func remove(_ id: UUID) {
        vault.removeToken(for: VaultAccount.read(id))
        for site in connections.first(where: { $0.id == id })?.sites ?? [] {
            vault.removeToken(for: VaultAccount.manage(id, site: site.id))
        }
        store.removeCache(for: id)
        connections.removeAll { $0.id == id }
        for period in Period.allCases { snapshots[period] = snapshots[period]?.filter { $0.key.connection != id } }
        failures = failures.filter { $0.key.connection != id }
        icons = icons.filter { $0.key.connection != id }
        details = details.filter { $0.key.connection != id }
        if expandedSite?.connection == id { expandedSite = nil }
        hiddenSites = hiddenSites.filter { $0.connection != id }
        siteOrder = siteOrder.filter { $0.connection != id }
        if case .site(let pinned) = menuBarDisplay, pinned.connection == id { menuBarDisplay = .total }
        connectionRemoved(id)
        baselines = baselines.filter { $0.key.connection != id }
        spikes = spikes.filter { $0.key.connection != id }
        persist()
        poller?.reconcile()
    }

    // MARK: Checking

    private struct Verified {
        let baseURL: URL
        let info: InstallInfo
        let token: String
        let tokenInfo: TokenInfo
        let sites: [Site]
    }

    private func verify(address: String, token rawToken: String, progress: @MainActor (ConnectStep) -> Void = { _ in }) async throws(ConnectError) -> Verified {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw .emptyAddress }
        if token.isEmpty { throw .emptyToken }

        progress(.finding)
        let found: (baseURL: URL, info: InstallInfo)
        do {
            found = try await RunlightClient.probe(address, session: session)
        } catch {
            throw error == .notRunlight ? .notRunlight : .network(error)
        }

        progress(.checkingToken)
        let client = RunlightClient(baseURL: found.baseURL, token: token, session: session)
        let tokenInfo: TokenInfo
        do {
            tokenInfo = try await client.tokenInfo()
        } catch where error.isTokenRejected {
            // The install's own secret isn't a token /api/token knows, yet it reads everything.
            if (try? await client.sites()) != nil { throw .installSecret }
            throw .tokenRejected
        } catch {
            throw .network(error)
        }
        switch tokenInfo.scope {
        case .read: break
        case .manage: throw .manageToken
        case .embed: throw .embedToken
        case .other(let scope): throw .scope(scope)
        }

        progress(.loadingSites)
        do {
            return Verified(baseURL: found.baseURL, info: found.info, token: token, tokenInfo: tokenInfo, sites: try await client.sites())
        } catch where error.isTokenRejected {
            throw .tokenRejected
        } catch {
            throw .network(error)
        }
    }

    // MARK: Helpers

    func update(_ id: UUID, _ change: (inout ConnectionState) -> Void) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        change(&connections[index])
    }

    private func persist() {
        try? store.saveConnections(connections.map(\.connection))
    }

    static func status(for error: RunlightError) -> ConnectionStatus {
        if error.isTokenRejected { return .tokenRejected }
        if error == .offline { return .offline }
        return .problem(error.message)
    }

    static func sitesKey(_ id: UUID) -> String { "\(id.uuidString)/sites" }

    /// analytics.joncp.dev, or example.com/runlight for an install inside an app.
    static func name(for baseURL: URL) -> String {
        let host = baseURL.host() ?? baseURL.absoluteString
        let port = baseURL.port.map { ":\($0)" } ?? ""
        let path = baseURL.path == "/" ? "" : baseURL.path
        return host + port + path
    }
}

/// What the menu bar shows beside the Runlight icon.
enum MenuBarDisplay: Hashable, Sendable {
    case icon
    case total
    /// One site's visitors.
    case site(SiteKey)

    var stored: String {
        switch self {
        case .icon: "icon"
        case .total: "total"
        case .site(let key): "site:" + key.storageKey
        }
    }

    init?(stored: String) {
        switch stored {
        case "icon": self = .icon
        case "total": self = .total
        default:
            guard stored.hasPrefix("site:"), let key = SiteKey(storageKey: String(stored.dropFirst(5))) else { return nil }
            self = .site(key)
        }
    }
}

extension AppModel {
    /// The pinned site, if one is.
    var pinnedSite: SiteKey? {
        if case .site(let key) = menuBarDisplay { key } else { nil }
    }

    /// The number beside the menu bar icon and what it means, or nil for the icon alone.
    var menuBarNumber: (value: Int, description: String)? {
        let when = period == .today ? "today" : "in the last \(period.title)"
        switch menuBarDisplay {
        case .icon:
            return nil
        case .total:
            return totals.visitors.map { ($0, "\($0.formatted(.number)) total site visits \(when), across every site") }
        case .site(let key):
            guard let site = allSites.first(where: { $0.connection.id == key.connection && $0.site.id == key.site })?.site,
                  let visitors = summary(key).visitors else { return nil }
            return (visitors, "\(site.name): \(visitors.formatted(.number)) visitors \(when)")
        }
    }
}
