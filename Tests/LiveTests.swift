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
