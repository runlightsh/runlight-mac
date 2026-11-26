import Foundation
import Testing
@testable import Runlight

@MainActor
struct ManageTokenTests {
    func connected() async throws -> (Harness, AppModel, SiteKey) {
        let harness = Harness()
        let model = harness.model()
        let state = try await model.connect(address: harness.server.baseURL.absoluteString, token: "rl_read")
        return (harness, model, SiteKey(connection: state.id, site: "dailyphototips.com"))
    }

    @Test func aManageTokenForTheSiteTurnsOnEditing() async throws {
        let (harness, model, key) = try await connected()
        #expect(!model.canEdit(key))
        harness.server.on("GET", "/api/token", fixture: "token-manage")
        try await model.addManageToken(key, token: " rl_manage\n")
        #expect(model.canEdit(key))
        #expect(harness.vault.token(for: VaultAccount.manage(key.connection, site: key.site)) == "rl_manage")
        // Only that site.
        #expect(!model.canEdit(SiteKey(connection: key.connection, site: "tulvane.com")))

        model.removeManageToken(key)
        #expect(!model.canEdit(key))
    }

    @Test func aReadTokenIsNotAManageToken() async throws {
        let (_, model, key) = try await connected()
        do {
            try await model.addManageToken(key, token: "rl_read")
            Issue.record("Expected to refuse a read token")
        } catch {
            #expect(error.message.hasPrefix("This is a read-only token."))
        }
        #expect(!model.canEdit(key))
    }

    @Test func aTokenForAnotherSiteSaysWhichSite() async throws {
        let (harness, model, _) = try await connected()
        harness.server.on("GET", "/api/token", fixture: "token-manage")
        let tulvane = SiteKey(connection: model.connections[0].id, site: "tulvane.com")
        do {
            try await model.addManageToken(tulvane, token: "rl_manage")
            Issue.record("Expected to refuse another site's token")
        } catch {
            #expect(error.message.hasPrefix("This manage token is for DailyPhotoTips, not Tulvane."))
        }
        #expect(!model.canEdit(tulvane))
    }

    @Test func aRejectedTokenIsRejected() async throws {
        let (harness, model, key) = try await connected()
        harness.server.on("GET", "/api/token", fixture: "error-unauthorized")
        await #expect(throws: ConnectError.tokenRejected) { try await model.addManageToken(key, token: "rl_gone") }
    }
}

@MainActor
struct SiteManagerTests {
    /// A connected site with a manage token, and the hub answering for goals and links.
    func managing() async throws -> (Harness, AppModel, SiteManager) {
        let harness = Harness()
        harness.server.on("GET", "/api/goals", fixture: "goals-30d")
        harness.server.on("GET", "/api/links", fixture: "links")
        let model = harness.model()
        let state = try await model.connect(address: harness.server.baseURL.absoluteString, token: "rl_read")
        let key = SiteKey(connection: state.id, site: "dailyphototips.com")
        try harness.vault.setToken("rl_manage", for: VaultAccount.manage(key.connection, site: key.site))
        let manager = SiteManager(key: key, model: model)
        await manager.load()
        return (harness, model, manager)
    }

    func requests(_ harness: Harness, _ method: String, _ path: String) -> [URLRequest] {
        harness.server.requests.filter { $0.httpMethod == method && $0.url?.path == path }
    }

    @Test func loadsGoalsAndLinksWithTheReadToken() async throws {
        let (harness, model, manager) = try await managing()
        defer { withExtendedLifetime(model) {} }
        #expect(manager.loaded)
        #expect(manager.goals.count == 3)
        #expect(!manager.links.isEmpty)
        #expect(manager.shortURL(manager.links[0]) == "https://hub.example/go/yt")
        #expect(requests(harness, "GET", "/api/goals").last?.value(forHTTPHeaderField: "Authorization") == "Bearer rl_read")
    }

    @Test func addingAGoalUsesTheManageToken() async throws {
        let (harness, model, manager) = try await managing()
        defer { withExtendedLifetime(model) {} }
        harness.server.on("POST", "/api/goals", fixture: "goal-create")
        try await manager.saveGoal(GoalInput(name: "Download preset", kind: .event, match: "Download"), editing: nil)
        let post = try #require(requests(harness, "POST", "/api/goals").last)
        #expect(post.value(forHTTPHeaderField: "Authorization") == "Bearer rl_manage")
        #expect(post.url?.query?.contains("site=dailyphototips.com") == true)
        // The lists load again afterwards.
        #expect(requests(harness, "GET", "/api/goals").count >= 2)
    }

    @Test func anEditKeepsTheFieldsTheFormDoesNotShow() throws {
        let goal = Goal(id: "g", site: "s", name: "Order", kind: .event, match: "Purchase", clickBy: "", valueMode: "prop", value: 0, valueProp: "total", currency: "EUR")
        var input = GoalInput(editing: goal)
        input.name = "Orders"
        let json = try #require(String(data: RunlightClient.encoder.encode(input), encoding: .utf8))
        #expect(json.contains(#""valueMode":"prop""#))
        #expect(json.contains(#""valueProp":"total""#))
        #expect(json.contains(#""currency":"EUR""#))
        #expect(json.contains(#""name":"Orders""#))
    }

    @Test func aFieldErrorLandsOnItsField() async throws {
        let (harness, model, manager) = try await managing()
        defer { withExtendedLifetime(model) {} }
        harness.server.on("POST", "/api/goals") { _ in .init(status: 400, body: Fixture.data("error-goal-name")) }
        do {
            try await manager.saveGoal(GoalInput(name: "", kind: .page, match: "/thanks"), editing: nil)
            Issue.record("Expected a field error")
        } catch {
            #expect(error.field == .name)
            #expect(error.message == "Give the goal a name")
            #expect(!error.needsManageToken)
        }
        harness.server.on("POST", "/api/links") { _ in .init(status: 400, body: Fixture.data("error-link-taken")) }
        do {
            try await manager.saveLink(LinkInput(url: "https://example.com", slug: "yt"), editing: nil)
            Issue.record("Expected a field error")
        } catch {
            #expect(error.field == .slug)
        }
    }

    @Test func aTokenThatCantEditAsksForANewOne() async throws {
        let (harness, model, manager) = try await managing()
        defer { withExtendedLifetime(model) {} }
        harness.server.on("POST", "/api/goals") { _ in .init(status: 403, body: Fixture.data("error-token-read-only")) }
        do {
            try await manager.saveGoal(GoalInput(name: "x", kind: .event, match: "x"), editing: nil)
            Issue.record("Expected a refusal")
        } catch {
            #expect(error.needsManageToken)
        }
    }

    @Test func withoutAManageTokenNothingIsSent() async throws {
        let (harness, model, manager) = try await managing()
        model.removeManageToken(manager.key)
        #expect(!manager.canEdit)
        do {
            try await manager.saveGoal(GoalInput(name: "x", kind: .event, match: "x"), editing: nil)
            Issue.record("Expected a refusal")
        } catch {
            #expect(error.needsManageToken)
        }
        #expect(requests(harness, "POST", "/api/goals").isEmpty)
    }

    @Test func deletingRemovesFromTheList() async throws {
        let (harness, model, manager) = try await managing()
        defer { withExtendedLifetime(model) {} }
        harness.server.on("DELETE", "/api/links/b8f9f51c270fa89a4eb457fd", fixture: "link-delete")
        let link = try #require(manager.links.first { $0.id == "b8f9f51c270fa89a4eb457fd" })
        try await manager.deleteLink(link)
        #expect(!manager.links.contains { $0.id == link.id })
        #expect(requests(harness, "DELETE", "/api/links/b8f9f51c270fa89a4eb457fd").first?.value(forHTTPHeaderField: "Authorization") == "Bearer rl_manage")
    }

    @Test func siteSettingsReachTheSiteList() async throws {
        let (harness, model, manager) = try await managing()
        harness.server.on("PATCH", "/api/sites/dailyphototips.com", fixture: "site-update")
        // The site list the app reloads afterwards has the new name.
        harness.server.on("GET", "/api/sites") { _ in
            .init(status: 200, body: Data(String(decoding: Fixture.data("sites"), as: UTF8.self).replacingOccurrences(of: "\"DailyPhotoTips\"", with: "\"Daily Photo Tips\"").utf8))
        }
        try await manager.saveSettings(SitePatch(name: "Daily Photo Tips", timezone: "America/New_York"))
        let patch = try #require(requests(harness, "PATCH", "/api/sites/dailyphototips.com").first)
        #expect(patch.value(forHTTPHeaderField: "Authorization") == "Bearer rl_manage")
        #expect(model.allSites.first { $0.site.id == "dailyphototips.com" }?.site.name == "Daily Photo Tips")
    }
}

@MainActor
struct SiteSectionsTests {
    @Test func aFunnelSendsOnlyItsSteps() throws {
        let input = FunnelInput(name: "Signup", steps: [FunnelStep(kind: "page", match: "/pricing", visits: 120), FunnelStep(kind: "event", match: "Signup", visits: 9)])
        let json = String(decoding: try RunlightClient.encoder.encode(input), as: UTF8.self)
        #expect(json == #"{"name":"Signup","steps":[{"kind":"page","match":"\/pricing"},{"kind":"event","match":"Signup"}]}"#)
    }

    @Test func shareLinksAreFullAddresses() async throws {
        let harness = Harness()
        let model = harness.model()
        let state = try await model.connect(address: harness.server.baseURL.absoluteString, token: "rl_read")
        let manager = SiteManager(key: SiteKey(connection: state.id, site: "dailyphototips.com"), model: model)
        let share = ShareLink(id: "abc", site: "dailyphototips.com", name: "Client", createdAt: nil, path: "/share/abc")
        #expect(manager.shareURL(share) == harness.server.baseURL.absoluteString + "/share/abc")
        withExtendedLifetime(model) {}
    }

    @Test func settingsOnlyAManageTokenReadsStayEmptyWithoutOne() async throws {
        let harness = Harness()
        harness.server.on("GET", "/api/goals", fixture: "goals-30d")
        harness.server.on("GET", "/api/links", fixture: "links")
        harness.server.on("GET", "/api/shares") { _ in .init(status: 200, body: Data(#"{"shares":[{"id":"s1","site":"dailyphototips.com","name":"Client","createdAt":1795638600000,"path":"/share/s1"}]}"#.utf8)) }
        let model = harness.model()
        let state = try await model.connect(address: harness.server.baseURL.absoluteString, token: "rl_read")
        let key = SiteKey(connection: state.id, site: "dailyphototips.com")
        let manager = SiteManager(key: key, model: model)
        await manager.load()
        #expect(manager.shares.isEmpty)
        #expect(!harness.server.requests.contains { $0.url?.path == "/api/shares" })

        try harness.vault.setToken("rl_manage", for: VaultAccount.manage(key.connection, site: key.site))
        await manager.load()
        #expect(manager.shares.map(\.id) == ["s1"])
        #expect(harness.server.requests.last { $0.url?.path == "/api/shares" }?.value(forHTTPHeaderField: "Authorization") == "Bearer rl_manage")
    }
}
