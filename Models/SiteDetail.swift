import Foundation

/// What the open site shows beyond its row: who's on now, and its top pages and sources for each
/// period it has been opened on. Kept in memory only; live numbers are stale by the next launch.
struct SiteDetail: Equatable, Sendable {
    struct Breakdowns: Equatable, Sendable {
        var pages: [BreakdownRow]
        var sources: [BreakdownRow]
        var at: Date
    }

    var realtime: Realtime?
    var realtimeAt: Date?
    var breakdowns: [Period: Breakdowns] = [:]

    /// Live numbers from the last minute, recent enough to show as "now".
    func liveVisitors(at now: Date) -> Int? {
        guard let realtime, let at = realtimeAt, now.timeIntervalSince(at) < 60 else { return nil }
        return realtime.visitors
    }
}
