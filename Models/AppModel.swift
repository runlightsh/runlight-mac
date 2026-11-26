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
    case offline
    case problem(String)

    var isOK: Bool { self == .ok }
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
    private(set) var connections: [ConnectionState] = []
    /// Whether Settings shows the Add Connection sheet. The popover sets it before opening Settings.
    var addingConnection = false

    /// The period the popover shows, kept between launches.
    var period: Period = .today {
        didSet {
            defaults.set(period.rawValue, forKey: "period")
            poller?.reconcile()
        }
    }
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
    /// How many fetches are under way, for the refresh button.
    var inFlight = 0
    /// True while the network is down; numbers stay, greyed.
    var offline = false

    @ObservationIgnored var poller: Poller?
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
        hiddenSites = Set((defaults.stringArray(forKey: "hiddenSites") ?? []).compactMap(SiteKey.init(storageKey:)))
        self.vault = vault
        self.session = session
        self.now = now
        connections = store.loadConnections().map { connection in
            ConnectionState(connection: connection, sites: store.cached([Site].self, Self.sitesKey(connection.id)) ?? [], status: .ok)
        }
        loadCache()
    }

    var isEmpty: Bool { connections.isEmpty }

    /// Every site across every connection, in connection order, switched off or not.
    var allSites: [(connection: ConnectionState, site: Site)] {
        connections.flatMap { state in state.sites.map { (state, $0) } }
    }

    /// The sites that are switched on.
    var shownSites: [(connection: ConnectionState, site: Site)] {
        allSites.filter { !hiddenSites.contains(SiteKey(connection: $0.connection.id, site: $0.site.id)) }
    }

    func isShown(_ key: SiteKey) -> Bool { !hiddenSites.contains(key) }

    func setShown(_ key: SiteKey, _ shown: Bool) {
        if !shown, expandedSite == key { expandedSite = nil }
        if shown { hiddenSites.remove(key) } else { hiddenSites.insert(key) }
    }

    /// The site whose live numbers should be fetched now: the open one, while the popover is up.
    var watchedSite: SiteKey? {
        guard popoverVisible, let key = expandedSite, isShown(key) else { return nil }
        return connections.contains { $0.id == key.connection && $0.sites.contains { $0.id == key.site } } ? key : nil
    }

    func toggleExpanded(_ key: SiteKey) {
        expandedSite = expandedSite == key ? nil : key
    }

    /// Escape folds an open site away before it closes the popover. Returns whether it did.
    func collapse() -> Bool {
        guard expandedSite != nil else { return false }
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
        guard let index = connections.firstIndex(where: { $0.id == id }), let client = client(for: id) else { return }
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
