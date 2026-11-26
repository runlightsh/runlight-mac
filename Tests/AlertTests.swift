import Foundation
import Testing
@testable import Runlight

/// Keeps what would have been posted.
@MainActor
final class RecordingNotifier: Notifier {
    var allow = true
    var asked = 0
    var posted: [(title: String, body: String, site: SiteKey)] = []

    func requestPermission() async -> Bool {
        asked += 1
        return allow
    }

    func post(id: String, title: String, body: String, site: SiteKey) {
        posted.append((title, body, site))
    }
}

/// Hourly series built by hand: a steady month, and a today with chosen hours.
enum SyntheticSeries {
    static let toronto = TimeZone(identifier: "America/Toronto")!
    /// The harness's clock: 2026-11-25 at 15:30 in Toronto.
    static let now = Date(timeIntervalSince1970: 1_795_638_600)

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = toronto
        return calendar
    }

    static func point(_ start: Date, _ visitors: Int) -> SeriesPoint {
        SeriesPoint(start: start, visitors: visitors, visits: visitors, pageviews: visitors)
    }

    static func range(_ from: String) -> ReportRange {
        ReportRange(from: from, to: "2026-11-25", interval: "hour", timezone: "America/Toronto")
    }

    /// `days` days before today at `perHour` visitors every hour, then today so far at the same rate.
    static func month(perHour: Int, days: Int = 29) -> SeriesResponse {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -days, to: today)!
        var points: [SeriesPoint] = []
        var hour = start
        while hour < today.addingTimeInterval(24 * 3600) {
            points.append(point(hour, perHour))
            hour = calendar.date(byAdding: .hour, value: 1, to: hour)!
        }
        return SeriesResponse(site: "dailyphototips.com", range: range("2026-10-27"), points: points)
    }

    /// Today's 24 hours at `perHour`, with some hours set.
    static func today(perHour: Int, hours: [Int: Int] = [:]) -> SeriesResponse {
        let today = calendar.startOfDay(for: now)
        let points = (0..<24).map { hour in
            point(calendar.date(byAdding: .hour, value: hour, to: today)!, hours[hour] ?? perHour)
        }
        return SeriesResponse(site: "dailyphototips.com", range: range("2026-11-25"), points: points)
    }

    static func json(_ series: SeriesResponse) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try! encoder.encode(series)
    }
}

struct SpikeDetectorTests {
    @Test func usualIsTheAverageForEachHourOfTheDay() throws {
        let usual = try #require(SpikeDetector.usualByHour(SyntheticSeries.month(perHour: 10), timeZone: SyntheticSeries.toronto, now: SyntheticSeries.now))
        #expect(usual.count == 24)
        #expect(usual.allSatisfy { $0 == 10 })
    }

    @Test func aWeekIsNeededBeforeAnythingIsUsual() {
        #expect(SpikeDetector.usualByHour(SyntheticSeries.month(perHour: 10, days: 5), timeZone: SyntheticSeries.toronto, now: SyntheticSeries.now) == nil)
    }

    @Test func theHourUnderWayCountsOnlyThePartThatHasPassed() throws {
        let usual = [Double](repeating: 10, count: 24)
        // 15:30: all of 14:00 plus half of 15:00.
        let window = try #require(SpikeDetector.lastHour(SyntheticSeries.today(perHour: 10), usual: usual, timeZone: SyntheticSeries.toronto, now: SyntheticSeries.now))
        #expect(window.count == 20)
        #expect(window.usual == 15)
    }

    @Test func aSpikeNeedsBothTheLevelAndEnoughExtraVisitors() {
        // A quiet site going from 2 to 8 is four times usual, and means nothing.
        #expect(!SpikeDetector.isSpike(count: 8, usual: 2, multiplier: 2, minExtra: 20))
        #expect(SpikeDetector.isSpike(count: 60, usual: 20, multiplier: 2, minExtra: 20))
        #expect(!SpikeDetector.isSpike(count: 35, usual: 20, multiplier: 2, minExtra: 20))
        // At 25% more, 50 against 30 is enough.
        #expect(SpikeDetector.isSpike(count: 50, usual: 30, multiplier: 1.25, minExtra: 20))
    }

    @Test func theTopSourceIsWhatGrewMostInTheHour() {
        let before = ["Google": 100, "photzy.com": 5]
        let now = ["Google": 110, "photzy.com": 305, "Bing": 3]
        #expect(SpikeDetector.topGrowth(now: now, before: before) == "photzy.com")
        // From another day, today's counts stand as they are.
        #expect(SpikeDetector.topGrowth(now: ["Google": 40, "Bing": 3], before: nil) == "Google")
        #expect(SpikeDetector.topGrowth(now: ["Google": 40], before: ["Google": 40]) == nil)
    }

    @Test func quietHoursCanRunPastMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = SyntheticSeries.toronto
        var settings = AlertSettings()
        settings.quietHours = true
        settings.quietStart = 22 * 60
        settings.quietEnd = 8 * 60
        func at(_ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: SyntheticSeries.now)!
        }
        #expect(settings.isQuiet(at: at(23), calendar: calendar))
        #expect(settings.isQuiet(at: at(3), calendar: calendar))
        #expect(!settings.isQuiet(at: at(8), calendar: calendar))
        #expect(!settings.isQuiet(at: at(15, 30), calendar: calendar))
        settings.quietHours = false
        #expect(!settings.isQuiet(at: at(23), calendar: calendar))
    }

    @Test func alertsReadPlainly() {
        let visitors = Spike(kind: .visitors, count: 420, usual: 70, top: "photzy.com", at: .now)
        let text = AppModel.alertText(visitors, siteName: "DailyPhotoTips")
        #expect(text.title == "DailyPhotoTips is spiking")
        #expect(text.body == "420 visitors in the last hour, 6× usual. Top source: photzy.com.")
        let smaller = Spike(kind: .visitors, count: 58, usual: 40, top: nil, at: .now)
        #expect(AppModel.alertText(smaller, siteName: "X").body == "58 visitors in the last hour, 45% above usual.")
        let conversions = Spike(kind: .conversions, count: 12, usual: 3, top: "Newsletter signup", at: .now)
        #expect(AppModel.alertText(conversions, siteName: "X").body == "12 conversions in the last hour, 4× usual. Most from Newsletter signup.")
    }
}

@MainActor
struct SpikeAlertTests {
    /// A connected model with alerts on, a steady month of 10 visitors an hour, and today's last
    /// hour and a half at `spike` visitors an hour.
    func spiking(_ spike: Int = 100) async throws -> (Harness, AppModel, RecordingNotifier, SiteKey) {
        let harness = Harness()
        let month = SyntheticSeries.json(SyntheticSeries.month(perHour: 10))
        let today = SyntheticSeries.json(SyntheticSeries.today(perHour: 10, hours: [14: spike, 15: spike]))
        harness.server.on("GET", "/api/series") { request in
            .init(status: 200, body: request.url?.query?.contains("period=30d") == true ? month : today)
        }
        harness.server.on("GET", "/api/goals") { request in
            .init(status: 200, body: Fixture.data(request.url?.query?.contains("period=30d") == true ? "goals-30d" : "goals-today"))
        }
        harness.server.on("GET", "/api/breakdown") { _ in
            .init(status: 200, body: Data(#"{"site":"dailyphototips.com","range":{"from":"2026-11-25","to":"2026-11-25","interval":"hour","timezone":"America/Toronto"},"dimension":"source","rows":[{"value":"photzy.com","visitors":305},{"value":"Google","visitors":110}]}"#.utf8))
        }
        harness.server.on("GET", "/api/realtime", fixture: "realtime")
        let notifier = RecordingNotifier()
        let model = harness.model()
        model.notifier = notifier
        let state = try await model.connect(address: harness.server.baseURL.absoluteString, token: "rl_good")
        await model.setAlertsEnabled(true)
        let key = SiteKey(connection: state.id, site: "dailyphototips.com")
        // Sources an hour ago, so the last hour's growth can be found.
        model.sourceHistory[key] = [Tally(at: model.now().addingTimeInterval(-3600), day: "2026-11-25", counts: ["photzy.com": 5, "Google": 100])]
        return (harness, model, notifier, key)
    }

    @Test func aSpikeSendsOneAlertNamingTheTopSource() async throws {
        let (_, model, notifier, key) = try await spiking()
        #expect(await model.perform(.baseline(key)))
        #expect(await model.perform(.sources(key)))
        #expect(notifier.posted.isEmpty)

        #expect(await model.perform(.series(key, .today)))
        try #require(notifier.posted.count == 1)
        #expect(notifier.posted[0].title == "DailyPhotoTips is spiking")
        // 200 visitors in 14:00 and half of 15:00, against 15 usually.
        #expect(notifier.posted[0].body == "200 visitors in the last hour, 13× usual. Top source: photzy.com.")
        #expect(notifier.posted[0].site == key)
        #expect(model.spikes[key]?.count == 200)
        #expect(model.spikeLit)

        // Fresh numbers five minutes later: still spiking, but it already said so.
        #expect(await model.perform(.series(key, .today)))
        #expect(notifier.posted.count == 1)

        // Opening the popover puts the lamp out.
        model.popoverOpened()
        #expect(!model.spikeLit)
    }

    @Test func theCooldownOutlastsARelaunch() async throws {
        let (harness, model, notifier, key) = try await spiking()
        await model.perform(.baseline(key))
        await model.perform(.series(key, .today))
        #expect(notifier.posted.count == 1)

        let relaunched = harness.model()
        let again = RecordingNotifier()
        relaunched.notifier = again
        await relaunched.perform(.baseline(key))
        await relaunched.perform(.series(key, .today))
        #expect(again.posted.isEmpty)
    }

    @Test func quietHoursSkipTheAlert() async throws {
        let (_, model, notifier, key) = try await spiking()
        let minute = Calendar.current.component(.hour, from: model.now()) * 60
        model.alertSettings.quietHours = true
        model.alertSettings.quietStart = minute
        model.alertSettings.quietEnd = minute + 60
        await model.perform(.baseline(key))
        await model.perform(.series(key, .today))
        #expect(notifier.posted.isEmpty)
        // The row still shows it.
        #expect(model.spikes[key] != nil)
    }

    @Test func aMutedOrHiddenSiteDoesNotAlert() async throws {
        let (_, model, notifier, key) = try await spiking()
        model.setAlerts(key, on: false)
        await model.perform(.baseline(key))
        await model.perform(.series(key, .today))
        #expect(notifier.posted.isEmpty)

        model.setAlerts(key, on: true)
        model.setShown(key, false)
        await model.perform(.series(key, .today))
        #expect(notifier.posted.isEmpty)
    }

    @Test func aSmallBumpOnAQuietSiteStaysQuiet() async throws {
        // 15 usually by 15:30; 30 is twice that, but only 15 more, under the minimum of 20.
        let (_, model, notifier, key) = try await spiking(15)
        await model.perform(.baseline(key))
        await model.perform(.series(key, .today))
        #expect(notifier.posted.isEmpty)
        #expect(model.spikes[key] == nil)
    }

    @Test func aJumpInConversionsAlertsAndNamesTheGoal() async throws {
        let (_, model, notifier, key) = try await spiking(10)
        await model.perform(.baseline(key))
        let now = model.now()
        model.goalHistory[key] = [
            Tally(at: now.addingTimeInterval(-3600), day: "2026-11-25", counts: ["Newsletter signup": 10, "Thanks page": 3]),
            Tally(at: now, day: "2026-11-25", counts: ["Newsletter signup": 40, "Thanks page": 5]),
        ]
        await model.checkSpikes(key)
        try #require(notifier.posted.count == 1)
        #expect(notifier.posted[0].title == "DailyPhotoTips conversions are up")
        #expect(notifier.posted[0].body.hasPrefix("32 conversions in the last hour"))
        #expect(notifier.posted[0].body.hasSuffix("Most from Newsletter signup."))

        // Turned off, they don't.
        model.alertSettings.conversions = false
        model.lastAlerts = [:]
        await model.checkSpikes(key)
        #expect(notifier.posted.count == 1)
    }

    @Test func refusedPermissionLeavesAlertsOff() async throws {
        let harness = Harness()
        let model = harness.model()
        let notifier = RecordingNotifier()
        notifier.allow = false
        model.notifier = notifier
        await model.setAlertsEnabled(true)
        #expect(notifier.asked == 1)
        #expect(!model.alertSettings.enabled)
        #expect(model.notificationsRefused)
    }

    @Test func alertJobsArePlannedOnlyWhileAlertsAreOn() async throws {
        let (_, model, _, key) = try await spiking()
        let poller = Poller(model: model)
        model.poller = poller
        poller.reconcile()
        #expect(poller.due[.baseline(key)] != nil)
        #expect(poller.due[.sources(key)] != nil)

        model.setAlerts(key, on: false)
        #expect(poller.due[.baseline(key)] == nil)

        model.alertSettings.enabled = false
        #expect(!poller.due.keys.contains { if case .baseline = $0 { true } else { false } })
    }

    @Test func clickingAnAlertOpensThatSiteToday() async throws {
        let (_, model, _, key) = try await spiking()
        model.period = .thirtyDays
        model.openFromAlert(key)
        #expect(model.period == .today)
        #expect(model.openSite == key)
    }

    @Test func alertSettingsAreRemembered() async throws {
        let (harness, model, _, key) = try await spiking()
        model.alertSettings.multiplier = 1.25
        model.setAlerts(key, on: false)
        let relaunched = harness.model()
        #expect(relaunched.alertSettings.enabled)
        #expect(relaunched.alertSettings.multiplier == 1.25)
        #expect(!relaunched.alertsOn(key))
    }
}
