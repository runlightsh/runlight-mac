import Foundation
import Testing
@testable import Runlight

/// Hourly points from midnight, with yesterday's lined up by position.
func hourlySeries(today: [Int], yesterday: [Int], start: Date = Date(timeIntervalSince1970: 1_795_582_800)) -> SeriesResponse {
    func points(_ values: [Int], from: Date) -> [SeriesPoint] {
        values.enumerated().map { SeriesPoint(start: from.addingTimeInterval(Double($0.offset) * 3600), visitors: $0.element, visits: $0.element, pageviews: $0.element) }
    }
    return SeriesResponse(
        site: "s", range: ReportRange(from: "2026-11-25", to: "2026-11-25"), compare: nil,
        points: points(today, from: start), previous: points(yesterday, from: start.addingTimeInterval(-86400))
    )
}

struct SameTimeTests {
    let midnight = Date(timeIntervalSince1970: 1_795_582_800)

    @Test func countsEndedHoursWholeAndTheCurrentHourInPart() throws {
        let series = hourlySeries(today: [10, 20, 30] + Array(repeating: 0, count: 21), yesterday: Array(repeating: 8, count: 24))
        // Half past two: two hours over, the third half gone.
        let sums = try #require(Numbers.sameTime(series, now: midnight.addingTimeInterval(2.5 * 3600)))
        #expect(sums.today == 60)
        #expect(sums.yesterday == 8 + 8 + 4)
    }

    @Test func neverComparesPartOfTodayWithAllOfYesterday() throws {
        let series = hourlySeries(today: Array(repeating: 1, count: 24), yesterday: Array(repeating: 100, count: 24))
        let sums = try #require(Numbers.sameTime(series, now: midnight.addingTimeInterval(60)))
        #expect(sums.yesterday < 2)
    }

    @Test func aWholeDayComparesWhole() throws {
        let series = hourlySeries(today: Array(repeating: 3, count: 24), yesterday: Array(repeating: 2, count: 24))
        let sums = try #require(Numbers.sameTime(series, now: midnight.addingTimeInterval(86400 + 60)))
        #expect(sums.today == 72)
        #expect(sums.yesterday == 48)
    }

    @Test func aDayWithAnExtraHourStillLinesUp() throws {
        // The night the clocks go back has 25 hours; yesterday has 24. The last hour has nothing to match.
        let series = hourlySeries(today: Array(repeating: 1, count: 25), yesterday: Array(repeating: 1, count: 24))
        let sums = try #require(Numbers.sameTime(series, now: midnight.addingTimeInterval(25 * 3600)))
        #expect(sums.today == 25)
        #expect(sums.yesterday == 24)
    }

    @Test func noComparisonWithoutYesterday() {
        var series = hourlySeries(today: [1, 2], yesterday: [1, 2])
        series.previous = nil
        #expect(Numbers.sameTime(series, now: midnight.addingTimeInterval(7200)) == nil)
    }

    @Test func theFixtureComparesUpToHalfPastThreeInToronto() throws {
        // The fixtures' clock: 3:30 pm in Toronto, so 15 hours are over and the 16th is half gone.
        let series = try Fixture.decode(SeriesResponse.self, "series-today")
        let now = Date(timeIntervalSince1970: 1_795_638_600)
        let sums = try #require(Numbers.sameTime(series, now: now))
        let previous: [Double] = series.previous!.map { Double($0.visitors) }
        let endedHours: Double = previous[0..<15].reduce(0, +)
        let halfHour: Double = previous[15] / 2
        let today: Int = series.points[0...15].reduce(0) { $0 + $1.visitors }
        #expect(sums.yesterday == endedHours + halfHour)
        #expect(sums.today == Double(today))
    }
}

struct SummaryTests {
    let now = Date(timeIntervalSince1970: 1_795_638_600)

    func snapshot() throws -> SiteSnapshot {
        SiteSnapshot(
            stats: try Fixture.decode(StatsResponse.self, "stats-today"), statsAt: now,
            series: try Fixture.decode(SeriesResponse.self, "series-today"), seriesAt: now,
            goals: try Fixture.decode(GoalsResponse.self, "goals-today"), goalsAt: now
        )
    }

    @Test func todayUsesTheSameTimeYesterday() throws {
        let snapshot = try snapshot()
        let summary = Numbers.summary(snapshot, period: .today, now: now)
        #expect(summary.visitors == 1273)
        let sums = try #require(Numbers.sameTime(snapshot.series!, now: now))
        #expect(summary.change == (sums.today - sums.yesterday) / sums.yesterday)
        // The spike makes today well ahead of yesterday at this hour.
        #expect((summary.change ?? 0) > 0.3)
        // The line stops at now: 16 of 24 hours.
        #expect(summary.sparkline.count == 16)
        #expect(summary.sparklineSlots == 24)
        #expect(summary.sparklineCompare.count == 24)
        let conversions: Int = snapshot.goals!.goals.reduce(0) { $0 + $1.numbers.conversions }
        #expect(summary.conversions == conversions)
    }

    @Test func otherPeriodsUseThePreviousPeriod() throws {
        let stats = try Fixture.decode(StatsResponse.self, "stats-7d")
        let summary = Numbers.summary(SiteSnapshot(stats: stats), period: .sevenDays, now: now)
        #expect(summary.change == Numbers.change(Double(stats.stats.visitors), from: Double(stats.previous!.visitors)))
    }

    @Test func nothingBeforeMeansNoChange() {
        #expect(Numbers.change(10, from: 0) == nil)
        #expect(Numbers.change(0, from: 0) == nil)
        #expect(Numbers.change(15, from: 10) == 0.5)
        #expect(Numbers.change(5, from: 10) == -0.5)
    }

    @Test func anEmptySiteHasZeroAndNoChange() throws {
        let snapshot = SiteSnapshot(
            stats: try Fixture.decode(StatsResponse.self, "stats-today-empty"),
            series: try Fixture.decode(SeriesResponse.self, "series-today-empty")
        )
        let summary = Numbers.summary(snapshot, period: .today, now: now)
        #expect(summary.visitors == 0)
        #expect(summary.change == nil)
    }

    @Test func totalsAddSitesUpAndCompareOnTheSameTerms() throws {
        let busy = try snapshot()
        let quiet = SiteSnapshot(stats: try Fixture.decode(StatsResponse.self, "stats-today-london"), series: try Fixture.decode(SeriesResponse.self, "series-today-london"))
        let totals = Numbers.totals([busy, quiet], period: .today, now: now)
        let visitors: Int = busy.stats!.stats.visitors + quiet.stats!.stats.visitors
        #expect(totals.visitors == visitors)
        let a = Numbers.sameTime(busy.series!, now: now)!
        let b = Numbers.sameTime(quiet.series!, now: now)!
        let change = Numbers.change(a.today + b.today, from: a.yesterday + b.yesterday)
        #expect(totals.change == change)
        let conversions: Int = busy.goals!.goals.reduce(0) { $0 + $1.numbers.conversions }
        #expect(totals.conversions == conversions)
    }

    @Test func totalsWaitForNumbers() {
        #expect(Numbers.totals([], period: .today, now: now) == Numbers.Totals())
    }
}

struct NumberTextTests {
    @Test(arguments: [(0, "0"), (999, "999"), (1_273, "1,273"), (9_999, "9,999"), (12_400, "12.4k"), (99_949, "99.9k"), (124_000, "124k"), (1_250_000, "1.2M")])
    func compact(value: Int, text: String) {
        #expect(NumberText.compact(value) == text)
    }

    @Test func percents() {
        #expect(NumberText.percent(0.123) == "12%")
        #expect(NumberText.percent(-0.5) == "50%")
        #expect(NumberText.percent(0.004) == "<1%")
        #expect(NumberText.percent(12) == "12×")
    }

    @Test func spoken() {
        #expect(NumberText.spokenChange(0.12, period: .today) == "up 12% from this time yesterday")
        #expect(NumberText.spokenChange(-0.3, period: .sevenDays) == "down 30% from the previous 7 days")
        #expect(NumberText.spokenChange(nil, period: .today) == "")
    }
}

@MainActor
struct FetchingTests {
    func connected() async throws -> (Harness, AppModel, SiteKey) {
        let harness = Harness()
        harness.server.on("GET", "/api/stats", fixture: "stats-today")
        harness.server.on("GET", "/api/series", fixture: "series-today")
        harness.server.on("GET", "/api/goals", fixture: "goals-today")
        harness.server.on("GET", "/api/icon") { _ in .init(status: 200, body: Data([0x89, 0x50, 0x4E, 0x47]), contentType: "image/png") }
        let model = harness.model()
        let state = try await model.connect(address: harness.server.baseURL.absoluteString, token: "rl_good")
        return (harness, model, SiteKey(connection: state.id, site: "dailyphototips.com"))
    }

    @Test func eachJobKeepsWhatItFetched() async throws {
        let (_, model, key) = try await connected()
        #expect(await model.perform(.stats(key, .today)))
        #expect(await model.perform(.series(key, .today)))
        #expect(await model.perform(.goals(key, .today)))
        #expect(await model.perform(.icon(key)))
        let snapshot = try #require(model.snapshot(key, .today))
        #expect(snapshot.stats?.stats.visitors == 1273)
        #expect(snapshot.series?.points.count == 24)
        #expect(snapshot.goals?.goals.count == 3)
        #expect(model.icons[key]?.data.count == 4)
        #expect(model.visitorsToday == 1273)
        #expect(model.inFlight == 0)
    }

    @Test func numbersSurviveARelaunch() async throws {
        let (harness, model, key) = try await connected()
        await model.perform(.stats(key, .today))
        await model.perform(.goals(key, .today))
        await model.perform(.icon(key))
        // Saves wait a moment so a round of sites writes once.
        try await Task.sleep(for: .seconds(2.5))
        let relaunched = harness.model()
        #expect(relaunched.snapshot(key, .today)?.stats?.stats.visitors == 1273)
        #expect(relaunched.snapshot(key, .today)?.goals?.goals.count == 3)
        #expect(relaunched.icons[key]?.data.count == 4)
    }

    @Test func aRejectedTokenMarksTheConnection() async throws {
        let (harness, model, key) = try await connected()
        harness.server.on("GET", "/api/stats", fixture: "error-unauthorized")
        #expect(await model.perform(.stats(key, .today)) == false)
        #expect(model.connections.first?.status == .tokenRejected)
    }

    @Test func aHubThatCantReachOneSiteMarksOnlyThatRow() async throws {
        let (harness, model, key) = try await connected()
        harness.server.on("GET", "/api/stats") { request in
            request.url?.query?.contains("tulvane.com") == true
                ? .init(status: 504, body: Data(#"{"error":"tulvane.com took too long","code":"remote_slow","params":{"host":"tulvane.com"}}"#.utf8))
                : .init(status: 200, body: Fixture.data("stats-today"))
        }
        let tulvane = SiteKey(connection: key.connection, site: "tulvane.com")
        #expect(await model.perform(.stats(tulvane, .today)) == false)
        #expect(await model.perform(.stats(key, .today)))
        #expect(model.failures[tulvane]?.isSiteUnreachable == true)
        #expect(model.failures[key] == nil)
        #expect(model.connections.first?.status == .ok)
    }

    @Test func aSiteWithNoIconIsRememberedAsHavingNone() async throws {
        let (harness, model, key) = try await connected()
        harness.server.on("GET", "/api/icon", fixture: "icon-none")
        #expect(await model.perform(.icon(key)))
        #expect(model.icons[key]?.data.isEmpty == true)
    }

    @Test func hiddenSitesLeaveTheListAndTheTotals() async throws {
        let (_, model, key) = try await connected()
        let other = SiteKey(connection: key.connection, site: "joncphillips.com")
        await model.perform(.stats(key, .today))
        await model.perform(.stats(other, .today))
        #expect(model.visitorsToday == 1273 * 2)
        model.setShown(other, false)
        #expect(model.visitorsToday == 1273)
        #expect(!model.rankedSites.contains { $0.key == other })
        #expect(model.allSites.count == 4)
    }

    @Test func busiestSitesComeFirst() async throws {
        let (harness, model, key) = try await connected()
        harness.server.on("GET", "/api/stats") { request in
            .init(status: 200, body: Fixture.data(request.url?.query?.contains("newsite.dev") == true ? "stats-today-empty" : "stats-today"))
        }
        let empty = SiteKey(connection: key.connection, site: "newsite.dev")
        await model.perform(.stats(empty, .today))
        await model.perform(.stats(key, .today))
        let order = model.rankedSites.map(\.key.site)
        #expect(order.first == "dailyphototips.com")
        // Sites with numbers come before sites still waiting, and zero before waiting.
        #expect(order.firstIndex(of: "newsite.dev")! < order.firstIndex(of: "tulvane.com")!)
    }
}

@MainActor
struct PollerTests {
    @Test func plansTodayAndThePeriodOnScreenForEveryShownSite() async throws {
        let harness = Harness()
        let model = harness.model()
        let state = try await model.connect(address: harness.server.baseURL.absoluteString, token: "rl_good")
        let poller = Poller(model: model)
        model.period = .today
        poller.reconcile()
        // Four sites: stats, series, and goals for today, and an icon each, plus the site list.
        let today: Int = 4 * 4 + 1
        #expect(poller.due.count == today)

        model.period = .sevenDays
        poller.reconcile()
        let sevenDays: Int = 4 * 7 + 1
        #expect(poller.due.count == sevenDays)

        model.setShown(SiteKey(connection: state.id, site: "tulvane.com"), false)
        poller.reconcile()
        // Three shown sites with seven jobs each, the hidden site's icon, and the site list.
        let expected: Int = 3 * 7 + 1 + 1
        #expect(poller.due.count == expected)
    }

    @Test func newJobsAreStaggered() async throws {
        let harness = Harness()
        let model = harness.model()
        try await model.connect(address: harness.server.baseURL.absoluteString, token: "rl_good")
        model.period = .today
        let poller = Poller(model: model)
        poller.reconcile()
        let times = Set(poller.due.values)
        #expect(times.count > 10)
    }

    @Test func freshCachedNumbersWaitTheirTurn() async throws {
        let harness = Harness()
        harness.server.on("GET", "/api/stats", fixture: "stats-today")
        let model = harness.model()
        let state = try await model.connect(address: harness.server.baseURL.absoluteString, token: "rl_good")
        model.period = .today
        let key = SiteKey(connection: state.id, site: "dailyphototips.com")
        await model.perform(.stats(key, .today))
        let poller = Poller(model: model)
        poller.reconcile()
        let due = try #require(poller.due[.stats(key, .today)])
        #expect(due.timeIntervalSince(model.now()) > 100)
    }
}
