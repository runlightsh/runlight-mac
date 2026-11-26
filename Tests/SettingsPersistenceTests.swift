import Foundation
import Testing
@testable import Runlight

/// Milestone 8's promise: every setting survives a relaunch.
@MainActor
struct SettingsPersistenceTests {
    @Test func everySettingSurvivesARelaunch() async throws {
        let harness = Harness()
        let model = harness.model()
        let state = try await model.connect(address: harness.server.baseURL.absoluteString, token: "rl_good")
        let ids = model.allSites.map(\.site.id)
        let first = SiteKey(connection: state.id, site: ids[0])
        let last = SiteKey(connection: state.id, site: ids[ids.count - 1])
        let hidden = SiteKey(connection: state.id, site: ids[1])

        model.period = .thirtyDays
        model.setShown(hidden, false)
        model.moveSite(last, to: first)
        model.menuBarDisplay = .site(first)
        model.refreshMinutes = 5
        model.opensSitesInWindow = false
        model.alertSettings = AlertSettings(enabled: true, multiplier: 1.5, conversions: false, quietHours: true, quietStart: 21 * 60, quietEnd: 7 * 60, mutedSites: [first.storageKey])
        let alertedAt = model.now()
        model.lastAlerts = ["\(first.storageKey)#visitors": alertedAt]

        let relaunched = harness.model()
        #expect(relaunched.period == .thirtyDays)
        #expect(!relaunched.isShown(hidden))
        #expect(relaunched.usesCustomOrder)
        #expect(relaunched.allSites.first?.site.id == last.site)
        #expect(relaunched.menuBarDisplay == .site(first))
        #expect(relaunched.refreshMinutes == 5)
        #expect(!relaunched.opensSitesInWindow)
        #expect(relaunched.alertSettings == model.alertSettings)
        #expect(relaunched.lastAlerts["\(first.storageKey)#visitors"]?.timeIntervalSince1970 == alertedAt.timeIntervalSince1970)
        // The connection and its sites come back too, with the token from the Keychain.
        #expect(relaunched.connections.map(\.id) == [state.id])
        #expect(relaunched.client(for: state.id) != nil)
    }
}
