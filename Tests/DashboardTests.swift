import Foundation
import Testing
@testable import Runlight

struct DashboardPolicyTests {
    let hub = URL(string: "https://analytics.joncp.dev")!
    let wordpress = URL(string: "https://example.com/runlight")!

    @Test func theInstallsOwnPagesStayInTheWindow() {
        #expect(DashboardPolicy.route(URL(string: "https://analytics.joncp.dev/?site=x&period=7d")!, base: hub) == .stay)
        #expect(DashboardPolicy.route(URL(string: "https://analytics.joncp.dev/login?next=/")!, base: hub) == .stay)
        // A CMS's own login sits in front of its Runlight, on the same site.
        #expect(DashboardPolicy.route(URL(string: "https://example.com/wp-login.php?redirect_to=x")!, base: wordpress) == .stay)
        #expect(DashboardPolicy.route(URL(string: "https://example.com:443/runlight/")!, base: wordpress) == .stay)
        #expect(DashboardPolicy.route(URL(string: "blob:https://analytics.joncp.dev/abc")!, base: hub) == .stay)
    }

    @Test func everythingElseLeavesIt() {
        #expect(DashboardPolicy.route(URL(string: "https://photzy.com/article")!, base: hub) == .elsewhere)
        #expect(DashboardPolicy.route(URL(string: "http://analytics.joncp.dev/")!, base: hub) == .elsewhere)
        #expect(DashboardPolicy.route(URL(string: "https://analytics.joncp.dev:8443/")!, base: hub) == .elsewhere)
        #expect(DashboardPolicy.route(URL(string: "mailto:hi@example.com")!, base: hub) == .elsewhere)
    }

    @Test func downloadsNeverOverwrite() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "downloads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(DashboardWindowController.freeDestination("pages.csv", in: folder).lastPathComponent == "pages.csv")
        try Data().write(to: folder.appending(path: "pages.csv"))
        try Data().write(to: folder.appending(path: "pages 2.csv"))
        #expect(DashboardWindowController.freeDestination("pages.csv", in: folder).lastPathComponent == "pages 3.csv")
    }
}

@MainActor
struct DashboardModelTests {
    @Test func linksFindTheirConnection() async throws {
        let harness = Harness()
        let model = harness.model()
        let state = try await model.connect(address: harness.server.baseURL.absoluteString, token: "rl_good")
        let page = harness.server.baseURL.appending(path: "").appending(queryItems: [URLQueryItem(name: "site", value: "dailyphototips.com")])
        #expect(model.connection(for: page)?.id == state.id)
        #expect(model.connection(for: URL(string: "https://elsewhere.test/")!) == nil)
        #expect(model.opensSitesInWindow)
        model.opensSitesInWindow = false
        #expect(!harness.model().opensSitesInWindow)
    }
}
