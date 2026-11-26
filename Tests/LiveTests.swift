import Foundation
import Testing
@testable import Runlight

/// Against a real install, only when asked:
///   TEST_RUNNER_RUNLIGHT_LIVE_URL=https://analytics.example TEST_RUNNER_RUNLIGHT_LIVE_TOKEN=rl_... xcodebuild test ...
/// The token stays in memory: the vault is a dictionary and the store a scratch folder.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["RUNLIGHT_LIVE_TOKEN"] != nil))
struct LiveTests {
    let address = ProcessInfo.processInfo.environment["RUNLIGHT_LIVE_URL"] ?? ""
    let token = ProcessInfo.processInfo.environment["RUNLIGHT_LIVE_TOKEN"] ?? ""
    let expectedSites = Int(ProcessInfo.processInfo.environment["RUNLIGHT_LIVE_SITES"] ?? "")

    func model() -> AppModel {
        AppModel(store: ConnectionStore(directory: FileManager.default.temporaryDirectory.appending(path: "runlight-live-\(UUID().uuidString)")), vault: MemoryVault(), defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    @Test func connectsAndListsEverySite() async throws {
        let state = try await model().connect(address: address, token: token)
        if let expectedSites { #expect(state.sites.count == expectedSites) }
        #expect(!state.sites.isEmpty)
        #expect(state.token?.scope == .read)
    }

    /// Everything the popover, the detail, and spike alerts fetch, for every site, decodes.
    @Test func everyNumberLoads() async throws {
        let model = model()
        let state = try await model.connect(address: address, token: token)
        for site in state.sites {
            let key = SiteKey(connection: state.id, site: site.id)
            var jobs: [Job] = [.icon(key), .realtime(key), .baseline(key), .sources(key)]
            for period in Period.allCases {
                jobs += [.stats(key, period), .series(key, period), .goals(key, period), .breakdown(key, period)]
            }
            for job in jobs {
                let worked = await model.perform(job)
                #expect(worked, "\(job) failed for \(site.id): \(model.failures[key].map(\.message) ?? "")")
            }
            #expect(model.snapshot(key, .today)?.stats != nil)
            #expect(model.snapshot(key, .today)?.series?.points.count ?? 0 >= 23)
            #expect(model.details[key]?.realtime != nil)
            #expect(model.details[key]?.breakdowns[.today] != nil)
        }
    }

    @Test func aWrongTokenIsRejected() async throws {
        await #expect(throws: ConnectError.tokenRejected) {
            try await model().connect(address: address, token: "rl_0000000000000000000000000000000000000000")
        }
    }
}

/// Editing against a real install, only when asked, with a throwaway site's manage token:
///   TEST_RUNNER_RUNLIGHT_LIVE_URL=... TEST_RUNNER_RUNLIGHT_LIVE_TOKEN=rl_read... \
///   TEST_RUNNER_RUNLIGHT_LIVE_MANAGE_TOKEN=rl_manage... TEST_RUNNER_RUNLIGHT_LIVE_SITE=site-id xcodebuild test ...
/// It makes a goal and a link, changes them, and deletes them, checking each step through the
/// read API the dashboard uses. Never point it at a site whose goals and links matter.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["RUNLIGHT_LIVE_MANAGE_TOKEN"] != nil))
struct LiveManageTests {
    let env = ProcessInfo.processInfo.environment

    @Test func goalsAndLinksMadeInTheAppShowUpAtOnce() async throws {
        let model = AppModel(store: ConnectionStore(directory: FileManager.default.temporaryDirectory.appending(path: "runlight-live-\(UUID().uuidString)")), vault: MemoryVault(), defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let state = try await model.connect(address: env["RUNLIGHT_LIVE_URL"] ?? "", token: env["RUNLIGHT_LIVE_TOKEN"] ?? "")
        let key = SiteKey(connection: state.id, site: env["RUNLIGHT_LIVE_SITE"] ?? "")
        let reader = try #require(model.client(for: state.id))

        // A read token can't edit.
        await #expect(throws: ConnectError.self) { try await model.addManageToken(key, token: env["RUNLIGHT_LIVE_TOKEN"] ?? "") }
        #expect(!model.canEdit(key))
        try await model.addManageToken(key, token: env["RUNLIGHT_LIVE_MANAGE_TOKEN"] ?? "")
        #expect(model.canEdit(key))

        let manager = SiteManager(key: key, model: model)
        await manager.load()
        #expect(manager.loaded)
        let tag = String(UUID().uuidString.prefix(6)).lowercased()

        // A goal: made, renamed, deleted, each seen at once by the dashboard's own reads.
        try await manager.saveGoal(GoalInput(name: "Mac test \(tag)", kind: .page, match: "/mac-test-\(tag)*"), editing: nil)
        var goals = try await reader.goalDefinitions(site: key.site)
        let goal = try #require(goals.first { $0.name == "Mac test \(tag)" })
        #expect(goal.match == "/mac-test-\(tag)*")
        var edit = GoalInput(editing: goal)
        edit.name = "Mac test \(tag) renamed"
        edit.fixedValue = 12.5
        try await manager.saveGoal(edit, editing: goal.id)
        goals = try await reader.goalDefinitions(site: key.site)
        let renamed = try #require(goals.first { $0.id == goal.id })
        #expect(renamed.name == "Mac test \(tag) renamed")
        #expect(renamed.fixedValue == 12.5)
        try await manager.deleteGoal(renamed)
        goals = try await reader.goalDefinitions(site: key.site)
        #expect(!goals.contains { $0.id == goal.id })

        // A link: the same.
        let link = try await manager.saveLink(LinkInput(url: "https://example.com/mac-test", slug: "mac-\(tag)", name: "Mac test"), editing: nil)
        var links = try await reader.links(site: key.site).links
        #expect(links.contains { $0.id == link.id && $0.slug == "mac-\(tag)" })
        try await manager.saveLink(LinkInput(name: "Mac test renamed"), editing: link.id)
        links = try await reader.links(site: key.site).links
        #expect(links.first { $0.id == link.id }?.name == "Mac test renamed")
        #expect(links.first { $0.id == link.id }?.url == "https://example.com/mac-test")
        try await manager.deleteLink(link)
        links = try await reader.links(site: key.site).links
        #expect(!links.contains { $0.id == link.id })
    }
}
