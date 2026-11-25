import Foundation

/// The last good answers for one site and period, and when each arrived.
struct SiteSnapshot: Codable, Equatable, Sendable {
    var stats: StatsResponse?
    var statsAt: Date?
    var series: SeriesResponse?
    var seriesAt: Date?
    var goals: GoalsResponse?
    var goalsAt: Date?

    var isEmpty: Bool { stats == nil && series == nil && goals == nil }
    var updatedAt: Date? { [statsAt, seriesAt, goalsAt].compactMap { $0 }.max() }
}

/// What a site row shows, worked out from a snapshot.
struct SiteSummary: Equatable, Sendable {
    var visitors: Int?
    /// The fraction it rose or fell, against the same time yesterday for today, or the previous
    /// period otherwise. Nil when there's nothing to compare with.
    var change: Double?
    /// The points to draw so far, and the comparison's, lined up by position.
    var sparkline: [Double]
    var sparklineCompare: [Double]
    /// How many points the whole period will have, so today's line stops at now rather than stretching.
    var sparklineSlots: Int
    var conversions: Int?

    static let empty = SiteSummary(visitors: nil, change: nil, sparkline: [], sparklineCompare: [], sparklineSlots: 0, conversions: nil)
}

enum Numbers {
    /// Visitors so far today against yesterday up to the same moment, from today's hourly series
    /// with yesterday lined up by position. Hours that have ended count whole on both sides; for the
    /// hour under way, yesterday's same hour counts only the part that has passed, so part of today
    /// is never set against all of yesterday.
    static func sameTime(_ series: SeriesResponse, now: Date) -> (today: Double, yesterday: Double)? {
        guard let previous = series.previous, !series.points.isEmpty else { return nil }
        var today = 0.0
        var yesterday = 0.0
        for (index, point) in series.points.enumerated() where point.start <= now {
            let end = index + 1 < series.points.count ? series.points[index + 1].start : point.start.addingTimeInterval(3600)
            let length = end.timeIntervalSince(point.start)
            let passed = length > 0 ? min(1, now.timeIntervalSince(point.start) / length) : 1
            today += Double(point.visitors)
            if index < previous.count { yesterday += Double(previous[index].visitors) * passed }
        }
        return (today, yesterday)
    }

    /// The rise or fall from `previous` to `current`, or nil when there was nothing before.
    static func change(_ current: Double, from previous: Double) -> Double? {
        guard previous > 0 else { return nil }
        return (current - previous) / previous
    }

    static func summary(_ snapshot: SiteSnapshot?, period: Period, now: Date) -> SiteSummary {
        guard let snapshot else { return .empty }
        var summary = SiteSummary.empty
        summary.visitors = snapshot.stats?.stats.visitors
        if let series = snapshot.series {
            let points = series.points.filter { $0.start <= now }
            summary.sparkline = points.map { Double($0.visitors) }
            summary.sparklineCompare = (series.previous ?? []).map { Double($0.visitors) }
            summary.sparklineSlots = series.points.count
        }
        if period == .today, let series = snapshot.series, let sums = sameTime(series, now: now) {
            summary.change = change(sums.today, from: sums.yesterday)
        } else if let stats = snapshot.stats, let previous = stats.previous {
            summary.change = change(Double(stats.stats.visitors), from: Double(previous.visitors))
        }
        summary.conversions = snapshot.goals.map { $0.goals.reduce(0) { $0 + $1.numbers.conversions } }
        return summary
    }

    /// Visitors and conversions across sites, and the change in visitors on the same terms as the rows.
    struct Totals: Equatable, Sendable {
        var visitors: Int?
        var change: Double?
        var conversions: Int?
    }

    static func totals(_ snapshots: [SiteSnapshot], period: Period, now: Date) -> Totals {
        let withStats = snapshots.compactMap(\.stats)
        guard !withStats.isEmpty else { return Totals() }
        var totals = Totals()
        totals.visitors = withStats.reduce(0) { $0 + $1.stats.visitors }
        if period == .today {
            let sums = snapshots.compactMap { $0.series.flatMap { sameTime($0, now: now) } }
            if !sums.isEmpty {
                totals.change = change(sums.reduce(0) { $0 + $1.today }, from: sums.reduce(0) { $0 + $1.yesterday })
            }
        } else {
            let previous = withStats.compactMap(\.previous)
            if !previous.isEmpty {
                totals.change = change(Double(totals.visitors ?? 0), from: Double(previous.reduce(0) { $0 + $1.visitors }))
            }
        }
        let goals = snapshots.compactMap(\.goals)
        if !goals.isEmpty {
            totals.conversions = goals.reduce(0) { sum, response in sum + response.goals.reduce(0) { $0 + $1.numbers.conversions } }
        }
        return totals
    }

    /// The series interval that suits each period's sparkline.
    static func interval(for period: Period) -> String {
        period == .today ? "hour" : "day"
    }
}

/// How numbers read in the popover.
enum NumberText {
    /// 1,273, then 12.4k from ten thousand, 124k, and 1.2M.
    static func compact(_ value: Int) -> String {
        switch value {
        case ..<10_000: return value.formatted(.number)
        case ..<1_000_000:
            let thousands = Double(value) / 1000
            return thousands < 100 ? "\(thousands.formatted(.number.precision(.fractionLength(0...1))))k" : "\(Int(thousands.rounded()))k"
        default:
            return "\((Double(value) / 1_000_000).formatted(.number.precision(.fractionLength(0...1))))M"
        }
    }

    /// "12%", or "<1%" for a change too small to round up, without a sign: the arrow carries it.
    static func percent(_ change: Double) -> String {
        let percent = abs(change) * 100
        if percent > 0 && percent < 1 { return "<1%" }
        if percent >= 1000 { return "\(Int(percent / 100))×" }
        return "\(Int(percent.rounded()))%"
    }

    /// The words VoiceOver reads for a change.
    static func spokenChange(_ change: Double?, period: Period) -> String {
        guard let change else { return "" }
        let against = period == .today ? "this time yesterday" : "the previous \(period == .sevenDays ? "7" : "30") days"
        if abs(change) < 0.005 { return "about the same as \(against)" }
        return "\(change > 0 ? "up" : "down") \(percent(change)) from \(against)"
    }
}
