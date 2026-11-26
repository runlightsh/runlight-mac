import Foundation
import Testing
@testable import Runlight

@MainActor
struct DetailTests {
    func connected(clock: (@Sendable () -> Date)? = nil) async throws -> (Harness, AppModel, SiteKey) {
        let harness = Harness()
        harness.server.on("GET", "/api/stats", fixture: "stats-today")
        harness.server.on("GET", "/api/series", fixture: "series-today")
        harness.server.on("GET", "/api/goals", fixture: "goals-today")
        harness.server.on("GET", "/api/realtime", fixture: "realtime")
        harness.server.on("GET", "/api/breakdown") { request in
            .init(status: 200, body: Fixture.data(request.url?.query?.contains("dimension=source") == true ? "breakdown-source" : "breakdown-page"))
        }
        harness.server.on("GET", "/api/icon", fixture: "icon-none")
        let model = clock.map { AppModel(store: harness.store, vault: harness.vault, session: harness.server.session, defaults: harness.defaults, now: $0) } ?? harness.model()
        let state = try await model.connect(address: harness.server.baseURL.absoluteString, token: "rl_good")
        return (harness, model, SiteKey(connection: state.id, site: "dailyphototips.com"))
    }

    @Test func liveNumbersAreFetchedOnlyForTheOpenSiteWhileThePopoverIsUp() async throws {
        let (_, model, key) = try await connected()
        model.period = .today
        let poller = Poller(model: model)
        model.poller = poller

        poller.reconcile()
        #expect(poller.due[.realtime(key)] == nil)

        // Open but with the popover away: nothing yet.
        model.expandedSite = key
        #expect(poller.due[.realtime(key)] == nil)

        model.popoverOpened()
        #expect(poller.due[.realtime(key)] != nil)
        #expect(poller.due[.breakdown(key, .today)] != nil)
        #expect(poller.due.keys.filter { if case .realtime = $0 { true } else { false } }.count == 1)

        model.popoverClosed()
        #expect(poller.due[.realtime(key)] == nil)
        #expect(poller.due[.breakdown(key, .today)] == nil)

        model.popoverOpened()
        model.expandedSite = nil
        #expect(poller.due[.realtime(key)] == nil)
    }

    @Test func liveNumbersRefreshEveryFifteenSecondsAndStopWhenClosed() async throws {
        let (harness, model, key) = try await connected(clock: { Date() })
        model.period = .today
        let poller = Poller(model: model)
        poller.intervals.realtime = 0.2
        model.poller = poller
        model.expandedSite = key
        model.popoverOpened()
        poller.start()
        func fetches() -> Int { harness.server.requests.filter { $0.url?.path == "/api/realtime" }.count }

        // Three fetches in a row while open, waiting as long as a busy test run needs.
        let deadline = Date().addingTimeInterval(10)
        while fetches() < 3 && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(fetches() >= 3, "only \(fetches()) realtime fetches while open")

        model.popoverClosed()
        // A fetch already on its way may still land; after that, nothing more.
        try await Task.sleep(for: .milliseconds(400))
        let closed = fetches()
        try await Task.sleep(for: .milliseconds(1000))
        #expect(fetches() == closed)
        poller.stop()

        // And the real interval is 15 seconds.
        #expect(Poller.Intervals().realtime == 15)
        #expect(Poller.Intervals().breakdown == 120)
    }

    @Test func theOpenSiteKeepsItsLiveNumbersAndTopLists() async throws {
        let (_, model, key) = try await connected()
        #expect(await model.perform(.realtime(key)))
        #expect(model.inFlight == 0)
        #expect(model.details[key]?.realtime?.visitors == 52)
        #expect(model.details[key]?.liveVisitors(at: model.now()) == 52)
        #expect(model.details[key]?.liveVisitors(at: model.now().addingTimeInterval(100)) == nil)

        #expect(await model.perform(.breakdown(key, .today)))
        let lists = try #require(model.details[key]?.breakdowns[.today])
        #expect(lists.pages.first?.value == "/")
        #expect(lists.sources.first?.value == "photzy.com")
    }

    @Test func switchingTheOpenSiteOffFoldsItAway() async throws {
        let (_, model, key) = try await connected()
        model.toggleExpanded(key)
        #expect(model.expandedSite == key)
        model.setShown(key, false)
        #expect(model.expandedSite == nil)
    }

    @Test func aSingleSiteIsAlwaysOpen() async throws {
        let (_, model, key) = try await connected()
        #expect(model.openSite == nil)
        for entry in model.allSites where entry.site.id != key.site {
            model.setShown(SiteKey(connection: entry.connection.id, site: entry.site.id), false)
        }
        #expect(model.onlySite == key)
        #expect(model.openSite == key)
        // Clicking it or pressing Escape doesn't fold it away.
        model.toggleExpanded(key)
        #expect(model.openSite == key)
        #expect(!model.collapse())
        // Live numbers come for it while the popover is up.
        model.popoverOpened()
        #expect(model.watchedSite == key)

        // A second site shown: back to folded rows.
        model.setShown(SiteKey(connection: key.connection, site: "tulvane.com"), true)
        #expect(model.openSite == nil)
    }

    @Test func escapeFoldsTheSiteBeforeClosing() async throws {
        let (_, model, key) = try await connected()
        #expect(!model.collapse())
        model.toggleExpanded(key)
        #expect(model.collapse())
        #expect(model.expandedSite == nil)
    }

    @Test func refreshingHoldsThroughGapsBetweenFetches() async throws {
        let (_, model, key) = try await connected()
        #expect(!model.isRefreshing)
        await model.perform(.stats(key, .today))
        // Done fetching, but a staggered round may start the next one any moment.
        #expect(model.inFlight == 0)
        #expect(model.isRefreshing)
        model.inFlight += 1
        try await Task.sleep(for: .milliseconds(500))
        #expect(model.isRefreshing)
        model.inFlight -= 1
        try await Task.sleep(for: .milliseconds(700))
        #expect(!model.isRefreshing)
    }

    @Test func theChosenPeriodIsRememberedAcrossLaunches() async throws {
        let (harness, model, _) = try await connected()
        model.period = .thirtyDays
        #expect(harness.model().period == .thirtyDays)
        model.period = .sevenDays
        #expect(harness.model().period == .sevenDays)
    }

    @Test func theMenuBarShowsTheIconTheTotalOrAPinnedSite() async throws {
        let (harness, model, key) = try await connected()
        await model.perform(.stats(key, .today))
        #expect(model.menuBarDisplay == .total)
        #expect(model.menuBarNumber?.value == 1273)

        model.menuBarDisplay = .icon
        #expect(model.menuBarNumber == nil)

        model.menuBarDisplay = .site(key)
        #expect(model.menuBarNumber?.value == 1273)
        #expect(model.menuBarNumber?.description.hasPrefix("DailyPhotoTips:") == true)
        #expect(harness.model().menuBarDisplay == .site(key))

        // Switching the pinned site off goes back to the total.
        model.setShown(key, false)
        #expect(model.menuBarDisplay == .total)
    }

    @Test func aPinnedSitesLiveCountComesEveryMinute() async throws {
        let (_, model, key) = try await connected()
        let poller = Poller(model: model)
        model.poller = poller
        poller.reconcile()
        #expect(poller.due[.realtime(key)] == nil)
        model.menuBarDisplay = .site(key)
        #expect(poller.due[.realtime(key)] != nil)
        #expect(poller.interval(for: .realtime(key)) == 60)
        // Opened in the popover, it's every 15 seconds.
        model.expandedSite = key
        model.popoverOpened()
        #expect(poller.interval(for: .realtime(key)) == 15)
    }

    @Test func theRefreshIntervalSetsHowOftenNumbersCome() async throws {
        let (harness, model, key) = try await connected()
        let poller = Poller(model: model)
        model.poller = poller
        model.refreshMinutes = 1
        #expect(poller.interval(for: .stats(key, .today)) == 60)
        #expect(poller.interval(for: .series(key, .today)) == 300)
        model.refreshMinutes = 15
        #expect(poller.interval(for: .stats(key, .today)) == 900)
        #expect(poller.interval(for: .goals(key, .today)) == 900)
        #expect(harness.model().refreshMinutes == 15)
    }

    @Test func theOldMenuBarSwitchCarriesOver() {
        let defaults = UserDefaults(suiteName: "sh.runlight.mac.tests.\(UUID().uuidString)")!
        defaults.set(false, forKey: "menuBarTotal")
        let model = AppModel(store: ConnectionStore(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)), vault: MemoryVault(), defaults: defaults)
        #expect(model.menuBarDisplay == .icon)
    }

    @Test func theMenuBarTotalFollowsThePeriod() async throws {
        let (harness, model, key) = try await connected()
        harness.server.on("GET", "/api/stats") { request in
            .init(status: 200, body: Fixture.data(request.url?.query?.contains("period=7d") == true ? "stats-7d" : "stats-today"))
        }
        await model.perform(.stats(key, .today))
        await model.perform(.stats(key, .sevenDays))
        model.period = .today
        let today = try #require(model.totals.visitors)
        model.period = .sevenDays
        let week = try #require(model.totals.visitors)
        #expect(today == 1273)
        #expect(week > today)
    }

    @Test func dashboardLinksOpenTheSiteOnThePeriodShown() {
        let hub = AppModel.dashboardURL(base: URL(string: "https://analytics.joncp.dev")!, site: "dailyphototips.com", period: .sevenDays)
        #expect(hub?.absoluteString == "https://analytics.joncp.dev/?site=dailyphototips.com&period=7d")
        let embedded = AppModel.dashboardURL(base: URL(string: "https://example.com/runlight")!, site: "example.com", period: .today)
        #expect(embedded?.absoluteString == "https://example.com/runlight/?site=example.com&period=today")
    }

    @Test func theLinePassesThroughItsPeaksWithoutOvershooting() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 50), CGPoint(x: 20, y: 0), CGPoint(x: 30, y: 0), CGPoint(x: 40, y: 20)]
        let bounds = Sparkline.smooth(points).cgPath.boundingBoxOfPath
        // The curve reaches the peak exactly and never dips below the floor between the zeros.
        #expect(abs(bounds.maxY - 50) < 0.001)
        #expect(abs(bounds.minY - 0) < 0.001)
    }

    @Test func detailNumbersRead() {
        #expect(NumberText.duration(48_400) == "48s")
        #expect(NumberText.duration(125_000) == "2m 05s")
        #expect(NumberText.duration(4_320_000) == "1h 12m")
        #expect(NumberText.share(0.4146) == "41%")
        #expect(NumberText.share(0.0730) == "7.3%")
        #expect(NumberText.share(0.05) == "5%")
        #expect(NumberText.share(0.0004) == "<0.1%")
        #expect(SeriesChart.niceCeiling(86) == 100)
        #expect(SeriesChart.niceCeiling(140) == 200)
        #expect(SeriesChart.niceCeiling(2400) == 2500)
        #expect(SeriesChart.niceCeiling(0) == 1)
    }
}

@MainActor
struct SiteOrderTests {
    @Test func draggingASiteReordersThePopoverAndIsRemembered() async throws {
        let harness = Harness()
        let model = harness.model()
        let state = try await model.connect(address: harness.server.baseURL.absoluteString, token: "rl_good")
        let ids = model.allSites.map(\.site.id)
        let last = SiteKey(connection: state.id, site: ids.last!)
        let first = SiteKey(connection: state.id, site: ids.first!)
        #expect(!model.usesCustomOrder)

        model.moveSite(last, to: first)
        #expect(model.usesCustomOrder)
        #expect(model.allSites.map(\.site.id) == [ids.last!] + ids.dropLast())
        #expect(model.rankedSites.map(\.key.site) == [ids.last!] + ids.dropLast())

        let relaunched = harness.model()
        #expect(relaunched.usesCustomOrder)
        #expect(relaunched.allSites.map(\.site.id) == [ids.last!] + ids.dropLast())

        // Moving down lands it where the target was.
        model.moveSite(last, to: SiteKey(connection: state.id, site: ids[1]))
        #expect(model.allSites.map(\.site.id) == [ids[0], ids[1], ids.last!] + ids[2..<ids.count - 1])
    }
}
