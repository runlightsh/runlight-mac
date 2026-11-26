import Foundation
import Testing
@testable import Runlight

/// A hub stub with the fixture answers a connect needs, and a model on a scratch folder.
@MainActor
struct Harness {
    let server = StubServer()
    let vault = MemoryVault()
    let directory = FileManager.default.temporaryDirectory.appending(path: "runlight-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    var store: ConnectionStore { ConnectionStore(directory: directory) }

    init(token: String = "token-read") {
        server.on("GET", "/api", fixture: "api")
        server.on("GET", "/api/token", fixture: token)
        server.on("GET", "/api/sites", fixture: "sites")
    }

    /// Settings for this test alone, never the app's own.
    let defaults = UserDefaults(suiteName: "sh.runlight.mac.tests.\(UUID().uuidString)")!

    func model() -> AppModel {
        AppModel(store: store, vault: vault, session: server.session, defaults: defaults, now: { Date(timeIntervalSince1970: 1_795_638_600) })
    }

    func files() -> [URL] {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).filter { !$0.hasDirectoryPath }
    }
}

@MainActor
struct ConnectTests {
    @Test func connectsAndListsEverySite() async throws {
        let harness = Harness()
        let model = harness.model()
        var steps: [ConnectStep] = []
        let state = try await model.connect(address: harness.server.baseURL.absoluteString, token: "  rl_good\n") { steps.append($0) }

        #expect(steps == [.finding, .checkingToken, .loadingSites])
        #expect(state.sites.count == 4)
        #expect(state.connection.version == "0.5.3")
        #expect(state.connection.name == harness.server.host)
        #expect(state.token?.scope == .read)
        #expect(model.allSites.count == 4)
        // The token is trimmed, kept in the vault, and sent as a bearer.
        #expect(harness.vault.token(for: VaultAccount.read(state.id)) == "rl_good")
        #expect(harness.server.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer rl_good")
    }

    @Test func noFileOnDiskHoldsTheToken() async throws {
        let harness = Harness()
        try await harness.model().connect(address: harness.server.baseURL.absoluteString, token: "rl_secret_value")
        let files = harness.files()
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("rl_secret_value"), "\(file.lastPathComponent) holds the token")
        }
    }

    @Test func survivesARelaunch() async throws {
        let harness = Harness()
        let state = try await harness.model().connect(address: harness.server.baseURL.absoluteString, token: "rl_good")
        let relaunched = harness.model()
        #expect(relaunched.connections.map(\.id) == [state.id])
        #expect(relaunched.allSites.count == 4)
        #expect(relaunched.client(for: state.id)?.token == "rl_good")
    }

    @Test func wrongTokenIsRejected() async throws {
        let harness = Harness()
        harness.server.on("GET", "/api/token", fixture: "error-unauthorized")
        harness.server.on("GET", "/api/sites", fixture: "error-unauthorized")
        let model = harness.model()
        await #expect(throws: ConnectError.tokenRejected) {
            try await model.connect(address: harness.server.baseURL.absoluteString, token: "rl_wrong")
        }
        #expect(model.isEmpty)
        #expect(harness.vault.count == 0)
    }

    @Test func wrongAddressSaysSo() async throws {
        let harness = Harness()
        harness.server.on("GET", "/api") { _ in .init(status: 200, body: Data("<html>Hello</html>".utf8), contentType: "text/html") }
        await #expect(throws: ConnectError.notRunlight) {
            try await harness.model().connect(address: harness.server.baseURL.absoluteString, token: "rl_good")
        }
    }

    @Test func unreachableAddressSaysSo() async throws {
        let model = AppModel(store: ConnectionStore(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)), vault: MemoryVault(), session: OfflineProtocol.session, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        do {
            try await model.connect(address: "https://example.com", token: "rl_good")
            Issue.record("Expected to fail")
        } catch {
            #expect(error.field == .address)
            #expect(error.message == "Offline.")
        }
    }

    @Test func manageTokenIsTurnedAway() async throws {
        let harness = Harness(token: "token-manage")
        await #expect(throws: ConnectError.manageToken) {
            try await harness.model().connect(address: harness.server.baseURL.absoluteString, token: "rl_manage")
        }
    }

    @Test func embedTokenIsTurnedAway() async throws {
        let harness = Harness()
        harness.server.on("GET", "/api/token") { _ in .init(status: 200, body: Data(#"{"scope":"embed","site":"x"}"#.utf8)) }
        await #expect(throws: ConnectError.embedToken) {
            try await harness.model().connect(address: harness.server.baseURL.absoluteString, token: "rl_embed")
        }
    }

    @Test func installSecretIsTurnedAway() async throws {
        // /api/token doesn't know the install's own secret, but it reads everything.
        let harness = Harness()
        harness.server.on("GET", "/api/token", fixture: "error-unauthorized")
        await #expect(throws: ConnectError.installSecret) {
            try await harness.model().connect(address: harness.server.baseURL.absoluteString, token: "the-install-secret")
        }
    }

    @Test func emptyFieldsNameTheField() async throws {
        let harness = Harness()
        let model = harness.model()
        await #expect(throws: ConnectError.emptyAddress) { try await model.connect(address: "  ", token: "rl_x") }
        await #expect(throws: ConnectError.emptyToken) { try await model.connect(address: "example.com", token: " ") }
        #expect(harness.server.requests.isEmpty)
    }

    @Test func connectingTwiceIsCaught() async throws {
        let harness = Harness()
        let model = harness.model()
        try await model.connect(address: harness.server.baseURL.absoluteString, token: "rl_good")
        await #expect(throws: ConnectError.alreadyConnected) {
            try await model.connect(address: harness.server.baseURL.absoluteString + "/", token: "rl_good")
        }
        #expect(model.connections.count == 1)
    }
}

@MainActor
struct ManageConnectionTests {
    @Test func removeForgetsEverything() async throws {
        let harness = Harness()
        let model = harness.model()
        let state = try await model.connect(address: harness.server.baseURL.absoluteString, token: "rl_good")
        try harness.vault.setToken("rl_manage", for: VaultAccount.manage(state.id, site: "dailyphototips.com"))

        model.remove(state.id)
        #expect(model.isEmpty)
        #expect(harness.vault.count == 0)
        #expect(harness.model().isEmpty)
        #expect(harness.files().allSatisfy { $0.lastPathComponent == "connections.json" })
    }

    @Test func aRejectedReplacementKeepsTheOldToken() async throws {
        let harness = Harness()
        let model = harness.model()
        let state = try await model.connect(address: harness.server.baseURL.absoluteString, token: "rl_old")
        harness.server.on("GET", "/api/token", fixture: "error-unauthorized")
        harness.server.on("GET", "/api/sites", fixture: "error-unauthorized")
        await #expect(throws: ConnectError.tokenRejected) { try await model.replaceToken(state.id, with: "rl_bad") }
        #expect(harness.vault.token(for: VaultAccount.read(state.id)) == "rl_old")
    }

    @Test func aGoodReplacementTakesOver() async throws {
        let harness = Harness()
        let model = harness.model()
        let state = try await model.connect(address: harness.server.baseURL.absoluteString, token: "rl_old")
        try await model.replaceToken(state.id, with: "rl_new")
        #expect(harness.vault.token(for: VaultAccount.read(state.id)) == "rl_new")
        #expect(model.connections.first?.status == .ok)
    }

    @Test func testNoticesADeletedToken() async throws {
        let harness = Harness()
        let model = harness.model()
        let state = try await model.connect(address: harness.server.baseURL.absoluteString, token: "rl_good")
        harness.server.on("GET", "/api/token", fixture: "error-unauthorized")
        await model.test(state.id)
        #expect(model.connections.first?.status == .tokenRejected)
        // The sites from before stay on screen.
        #expect(model.allSites.count == 4)
    }

    @Test func testRecoversWhenTheTokenWorksAgain() async throws {
        let harness = Harness()
        let model = harness.model()
        let state = try await model.connect(address: harness.server.baseURL.absoluteString, token: "rl_good")
        harness.server.on("GET", "/api/token", fixture: "error-unauthorized")
        await model.test(state.id)
        harness.server.on("GET", "/api/token", fixture: "token-read")
        await model.test(state.id)
        #expect(model.connections.first?.status == .ok)
    }

    @Test func aConnectionWithNoTokenSaysSo() async throws {
        let harness = Harness()
        let model = harness.model()
        let state = try await model.connect(address: harness.server.baseURL.absoluteString, token: "rl_good")
        // The token goes from the Keychain behind the app's back.
        harness.vault.removeToken(for: VaultAccount.read(state.id))
        #expect(harness.model().connections.first?.status == .tokenMissing)

        let key = SiteKey(connection: state.id, site: "dailyphototips.com")
        #expect(await model.perform(.stats(key, .today)) == false)
        #expect(model.connections.first?.status == .tokenMissing)
        #expect(model.connections.first?.status.needsToken == true)

        // A new token puts it right.
        try await model.replaceToken(state.id, with: "rl_new")
        #expect(model.connections.first?.status == .ok)
    }

    @Test func namesReadLikeAddresses() {
        #expect(AppModel.name(for: URL(string: "https://analytics.joncp.dev")!) == "analytics.joncp.dev")
        #expect(AppModel.name(for: URL(string: "https://example.com/runlight")!) == "example.com/runlight")
        #expect(AppModel.name(for: URL(string: "http://localhost:4800/runlight")!) == "localhost:4800/runlight")
    }
}

/// The real Keychain, with an account no one else uses, cleaned up after.
struct KeychainTests {
    @Test func roundTrip() throws {
        let keychain = Keychain(service: "sh.runlight.mac.tests")
        let account = "test-\(UUID().uuidString)"
        defer { keychain.removeToken(for: account) }
        #expect(keychain.token(for: account) == nil)
        try keychain.setToken("rl_first", for: account)
        #expect(keychain.token(for: account) == "rl_first")
        try keychain.setToken("rl_second", for: account)
        #expect(keychain.token(for: account) == "rl_second")
        keychain.removeToken(for: account)
        #expect(keychain.token(for: account) == nil)
    }
}
