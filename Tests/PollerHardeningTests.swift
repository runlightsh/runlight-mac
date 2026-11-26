import Foundation
import Testing
@testable import Runlight

@MainActor
struct PollerHardeningTests {
    /// A model on a real clock with a poller that runs every job every 0.2 seconds.
    func running() async throws -> (Harness, AppModel, Poller, SiteKey) {
        let harness = Harness()
        harness.server.on("GET", "/api/stats", fixture: "stats-today")
        harness.server.on("GET", "/api/series", fixture: "series-today")
        harness.server.on("GET", "/api/goals", fixture: "goals-today")
        harness.server.on("GET", "/api/icon", fixture: "icon-none")
        let model = AppModel(store: harness.store, vault: harness.vault, session: harness.server.session, defaults: harness.defaults)
        let state = try await model.connect(address: harness.server.baseURL.absoluteString, token: "rl_good")
        model.period = .today
        let poller = Poller(model: model)
        poller.intervals.stats = 0.2
        poller.intervals.series = 0.2
        poller.intervals.goals = 0.2
        poller.wakeDelay = 0.1
        model.poller = poller
        return (harness, model, poller, SiteKey(connection: state.id, site: "dailyphototips.com"))
    }

    func count(_ harness: Harness) -> Int { harness.server.requests.count }

    func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    }

    @Test func nothingGoesOutWhileTheMacSleepsAndPollingResumesOnWaking() async throws {
        let (harness, model, poller, _) = try await running()
        poller.start()
        let before = count(harness)
        try await waitFor { count(harness) > before + 10 }

        model.conditionsChanged(.sleep)
        // Anything already on its way lands; then silence.
        try await Task.sleep(for: .milliseconds(300))
        let asleep = count(harness)
        try await Task.sleep(for: .milliseconds(1000))
        #expect(count(harness) == asleep, "requests went out while asleep")

        model.conditionsChanged(.wake)
        let woke = Date()
        try await waitFor { count(harness) > asleep + 5 }
        #expect(count(harness) > asleep + 5)
        #expect(Date().timeIntervalSince(woke) < 30)
        poller.stop()
    }

    @Test func nothingGoesOutWhileOffline() async throws {
        let (harness, model, poller, _) = try await running()
        poller.start()
        try await waitFor { count(harness) > 10 }

        model.conditionsChanged(.online(false))
        #expect(model.offline)
        try await Task.sleep(for: .milliseconds(300))
        let offline = count(harness)
        // The popover opening or the refresh button doesn't send anything either.
        model.popoverOpened()
        model.refreshNow()
        try await Task.sleep(for: .milliseconds(800))
        #expect(count(harness) == offline)

        model.conditionsChanged(.online(true))
        #expect(!model.offline)
        try await waitFor { count(harness) > offline + 5 }
        #expect(count(harness) > offline + 5)
        poller.stop()
    }

    @Test func sleepingWhileOfflineWaitsForBoth() async throws {
        let (_, model, poller, _) = try await running()
        model.conditionsChanged(.sleep)
        model.conditionsChanged(.online(false))
        model.conditionsChanged(.wake)
        #expect(poller.paused == [.offline])
        model.conditionsChanged(.online(true))
        #expect(poller.paused.isEmpty)
    }

    @Test func lowPowerModeDoublesBackgroundIntervalsButNotTheOpenSite() async throws {
        let (_, model, poller, key) = try await running()
        poller.intervals = Poller.Intervals()
        #expect(poller.interval(for: .stats(key, .today)) == 120)
        model.expandedSite = key
        model.popoverOpened()
        poller.lowPower = true
        #expect(poller.interval(for: .stats(key, .today)) == 240)
        #expect(poller.interval(for: .series(key, .today)) == 600)
        #expect(poller.interval(for: .realtime(key)) == 15)
        #expect(poller.interval(for: .breakdown(key, .today)) == 120)
    }

    @Test func failingJobsBackOffAndRecover() async throws {
        let (harness, model, poller, key) = try await running()
        poller.intervals = Poller.Intervals()
        harness.server.on("GET", "/api/stats") { _ in .init(status: 500, body: Data(#"{"error":"boom","code":"internal"}"#.utf8)) }
        poller.start()
        var waits: [TimeInterval] = []
        for _ in 0..<7 {
            await model.perform(.stats(key, .today))
            poller.noteResult(.stats(key, .today), worked: false)
            waits.append(poller.interval(for: .stats(key, .today)))
        }
        #expect(waits == [60, 120, 240, 480, 960, 1800, 1800])

        harness.server.on("GET", "/api/stats", fixture: "stats-today")
        await model.perform(.stats(key, .today))
        poller.noteResult(.stats(key, .today), worked: true)
        #expect(poller.interval(for: .stats(key, .today)) == 120)
        poller.stop()
    }

    @Test func aRejectedTokenIsLeftAloneUntilItWorksAgain() async throws {
        let (harness, model, poller, key) = try await running()
        poller.intervals = Poller.Intervals()
        model.period = .today
        poller.reconcile()
        harness.server.on("GET", "/api/stats", fixture: "error-unauthorized")
        await model.perform(.stats(key, .today))
        #expect(model.connections.first?.status == .tokenRejected)
        #expect(poller.interval(for: .stats(key, .today)) == 1800)

        // A working token again: the connection's jobs come due now rather than in half an hour.
        harness.server.on("GET", "/api/token", fixture: "token-read")
        try await model.replaceToken(key.connection, with: "rl_new")
        let due = try #require(poller.due[.stats(key, .today)])
        #expect(due.timeIntervalSince(model.now()) < 5)
        #expect(poller.interval(for: .stats(key, .today)) == 120)
    }
}
