import Foundation

/// What the app needs from an analytics service. Runlight is the only one today; the views and
/// the poller talk to this, so another provider (Plausible, Umami) can be added without them
/// changing. Editing is Runlight's alone for now, so it stays on `RunlightClient`.
protocol AnalyticsProvider: Sendable {
    func sites() async throws(RunlightError) -> [Site]
    func icon(site: String) async throws(RunlightError) -> Data?
    func stats(site: String, period: Period) async throws(RunlightError) -> StatsResponse
    func series(site: String, period: Period, interval: String, compare: String) async throws(RunlightError) -> SeriesResponse
    func goals(site: String, period: Period) async throws(RunlightError) -> GoalsResponse
    func realtime(site: String) async throws(RunlightError) -> Realtime
    func breakdown(site: String, period: Period, dimension: Dimension, limit: Int) async throws(RunlightError) -> BreakdownResponse
}

extension RunlightClient: AnalyticsProvider {}
