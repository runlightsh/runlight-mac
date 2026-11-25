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

/// Everything the views read. Connections and their sites live here; numbers join in milestone 4.
@MainActor
@Observable
final class AppModel {
    private(set) var connections: [ConnectionState] = []
    /// Whether Settings shows the Add Connection sheet. The popover sets it before opening Settings.
    var addingConnection = false

    private let store: ConnectionStore
    private let vault: TokenVault
    private let session: URLSession
    private let now: @Sendable () -> Date

    init(store: ConnectionStore = .standard, vault: TokenVault = Keychain(), session: URLSession = .shared, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.vault = vault
        self.session = session
        self.now = now
        connections = store.loadConnections().map { connection in
            ConnectionState(connection: connection, sites: store.cached([Site].self, Self.sitesKey(connection.id)) ?? [], status: .ok)
        }
    }

    var isEmpty: Bool { connections.isEmpty }

    /// Every site across every connection, in connection order.
    var allSites: [(connection: ConnectionState, site: Site)] {
        connections.flatMap { state in state.sites.map { (state, $0) } }
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
        persist()
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

    private func update(_ id: UUID, _ change: (inout ConnectionState) -> Void) {
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
