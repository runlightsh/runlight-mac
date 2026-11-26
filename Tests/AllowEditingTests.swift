import Foundation
import Testing
@testable import Runlight

/// "Allow Editing": the install's OAuth server is a stub, the app's loopback listener is real, and
/// the test plays the browser, following the authorize address back to it.
@MainActor
struct AllowEditingTests {
    /// A connected model with the stub answering OAuth the way Runlight does.
    func setUp(grantSite: String = "dailyphototips.com") async throws -> (Harness, AppModel, SiteKey) {
        let harness = Harness()
        let base = harness.server.baseURL.absoluteString
        harness.server.on("GET", "/.well-known/oauth-authorization-server") { _ in
            .init(status: 200, body: Data(#"{"issuer":"\#(base)","authorization_endpoint":"\#(base)/oauth/authorize","token_endpoint":"\#(base)/oauth/token","registration_endpoint":"\#(base)/oauth/register"}"#.utf8))
        }
        harness.server.on("POST", "/oauth/register") { _ in .init(status: 201, body: Data(#"{"client_id":"client-1"}"#.utf8)) }
        harness.server.on("POST", "/oauth/token") { _ in
            .init(status: 200, body: Data(#"{"access_token":"rl_from_oauth","token_type":"Bearer","scope":"manage","site":"\#(grantSite)"}"#.utf8))
        }
        let model = harness.model()
        let state = try await model.connect(address: base, token: "rl_read")
        harness.server.on("GET", "/api/token", fixture: "token-manage")
        return (harness, model, SiteKey(connection: state.id, site: "dailyphototips.com"))
    }

    /// The browser: allows the app (or not) and follows the redirect to the app's loopback address.
    nonisolated static func browse(_ authorize: URL, answer: @escaping @Sendable ([String: String]) -> [String: String]) {
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: authorize, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        var back = URLComponents(string: query["redirect_uri"]!)!
        back.queryItems = answer(query).map { URLQueryItem(name: $0.key, value: $0.value) }
        Task.detached { _ = try? await URLSession(configuration: .ephemeral).data(from: back.url!) }
    }

    @Test func allowingInTheBrowserTurnsOnEditing() async throws {
        let (harness, model, key) = try await setUp()
        nonisolated(unsafe) var asked: URL?
        try await model.allowEditing(key) { url in
            asked = url
            Self.browse(url) { query in ["code": "code-1", "state": query["state"]!] }
        }
        #expect(model.canEdit(key))
        #expect(harness.vault.token(for: VaultAccount.manage(key.connection, site: key.site)) == "rl_from_oauth")

        // The page asked for manage on this site, with PKCE.
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: try #require(asked), resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["scope"] == "manage")
        #expect(query["site"] == "dailyphototips.com")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["redirect_uri"]?.hasPrefix("http://127.0.0.1:") == true)

        // The code was swapped with the verifier that matches the challenge.
        let swap = try #require(Array(zip(harness.server.requests, harness.server.requestBodies)).last { $0.0.url?.path == "/oauth/token" }?.1)
        let form = Dictionary(uniqueKeysWithValues: (URLComponents(string: "?" + String(decoding: swap, as: UTF8.self))?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(form["code"] == "code-1")
        #expect(OAuthLoopback.challenge(for: try #require(form["code_verifier"])) == query["code_challenge"])
    }

    @Test func sayingNoLeavesItReadOnly() async throws {
        let (_, model, key) = try await setUp()
        do {
            try await model.allowEditing(key) { url in
                Self.browse(url) { query in ["error": "access_denied", "state": query["state"]!] }
            }
            Issue.record("Expected a refusal")
        } catch {
            #expect(error.message.hasPrefix("Editing wasn't allowed."))
        }
        #expect(!model.canEdit(key))
    }

    @Test func anAnswerForAnotherRequestIsRefused() async throws {
        let (_, model, key) = try await setUp()
        do {
            try await model.allowEditing(key) { url in
                Self.browse(url) { _ in ["code": "stolen", "state": "someone-elses"] }
            }
            Issue.record("Expected a refusal")
        } catch {
            #expect(error.message.hasPrefix("The answer from the browser didn't match"))
        }
        #expect(!model.canEdit(key))
    }

    @Test func allowingAnotherSiteIsCaught() async throws {
        let (_, model, key) = try await setUp(grantSite: "tulvane.com")
        do {
            try await model.allowEditing(key) { url in
                Self.browse(url) { query in ["code": "code-1", "state": query["state"]!] }
            }
            Issue.record("Expected a refusal")
        } catch {
            #expect(error.message == "That allowed editing Tulvane, not DailyPhotoTips. Try again and pick DailyPhotoTips on the page.")
        }
        #expect(!model.canEdit(key))
    }

    @Test func noAnswerTimesOut() async throws {
        let (_, model, key) = try await setUp()
        do {
            try await model.allowEditing(key, timeout: 0.5) { _ in }
            Issue.record("Expected a time out")
        } catch {
            #expect(error.message.hasPrefix("Nothing came back from the browser."))
        }
    }
}
