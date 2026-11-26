import Foundation

/// What the Alerts settings hold. Kept as one value in UserDefaults.
struct AlertSettings: Codable, Equatable, Sendable {
    /// Spike alerts at all. Off until turned on, when macOS asks for permission.
    var enabled = false
    /// How far above usual counts as a spike: 1.25 is 25% more, 2 is twice as many.
    var multiplier: Double = 2
    /// Alerts when goal conversions jump, on the same terms.
    var conversions = true
    var quietHours = false
    /// Minutes after midnight, in the Mac's own time.
    var quietStart = 22 * 60
    var quietEnd = 8 * 60
    /// Sites with alerts switched off, as storage keys.
    var mutedSites: Set<String> = []

    /// The levels offered in Settings.
    static let levels: [Double] = [1.25, 1.5, 2, 3]

    /// Whether `date` falls in quiet hours, which may run past midnight.
    func isQuiet(at date: Date, calendar: Calendar = .current) -> Bool {
        guard quietHours, quietStart != quietEnd else { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return quietStart < quietEnd
            ? minute >= quietStart && minute < quietEnd
            : minute >= quietStart || minute < quietEnd
    }

    static func levelName(_ multiplier: Double) -> String {
        multiplier < 2 ? "\(Int(((multiplier - 1) * 100).rounded()))% more" : "\(multiplier.formatted(.number))× as many"
    }
}

/// A spike that was found, for the notification and the row.
struct Spike: Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case visitors, conversions }

    let kind: Kind
    /// Visitors or conversions in the last hour.
    let count: Int
    /// What the same stretch usually brings.
    let usual: Double
    /// The source that sent the most of it, or the goal that converted most.
    var top: String?
    let at: Date

    var ratio: Double { usual > 0 ? Double(count) / usual : .infinity }

    /// "6× usual", or "45% above usual" under twice.
    var ratioText: String {
        if !ratio.isFinite { return "far above usual" }
        if ratio >= 2 { return "\(Int(ratio.rounded()))× usual" }
        return "\(Int(((ratio - 1) * 100).rounded()))% above usual"
    }
}

/// Finds spikes. Pure functions over API responses, so every rule can be tested on its own.
enum SpikeDetector {
    /// The fewest extra visitors, or conversions, that count: a quiet site going from 1 to 3 visitors
    /// is 3× usual and means nothing.
    static let minExtraVisitors = 20.0
    static let minExtraConversions = 5.0
    /// At most one alert of each kind per site in this long.
    static let cooldown: TimeInterval = 2 * 3600

    /// The average visitors for each hour of the day, from the days before today in a 30 day hourly
    /// series. Nil until there are a week of days to average.
    static func usualByHour(_ series: SeriesResponse, timeZone: TimeZone, now: Date) -> [Double]? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        var sums = [Double](repeating: 0, count: 24)
        var counts = [Double](repeating: 0, count: 24)
        var days = Set<Date>()
        for point in series.points where point.start < today {
            let hour = calendar.component(.hour, from: point.start)
            sums[hour] += Double(point.visitors)
            counts[hour] += 1
            days.insert(calendar.startOfDay(for: point.start))
        }
        guard days.count >= 7 else { return nil }
        return zip(sums, counts).map { $1 > 0 ? $0 / $1 : 0 }
    }

    /// Visitors in the last full hour and the hour under way, and what those hours usually bring,
    /// with the hour under way counted only for the part that has passed.
    static func lastHour(_ today: SeriesResponse, usual: [Double], timeZone: TimeZone, now: Date) -> (count: Int, usual: Double)? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let points = today.points.filter { $0.start <= now }
        guard let current = points.last else { return nil }
        let passed = min(1, max(0, now.timeIntervalSince(current.start) / 3600))
        var count = current.visitors
        var expected = usual[calendar.component(.hour, from: current.start)] * passed
        if points.count >= 2 {
            let previous = points[points.count - 2]
            count += previous.visitors
            expected += usual[calendar.component(.hour, from: previous.start)]
        }
        return (count, expected)
    }

    /// Whether `count` against `usual` is a spike at this level.
    static func isSpike(count: Double, usual: Double, multiplier: Double, minExtra: Double) -> Bool {
        count - usual >= minExtra && count >= usual * multiplier
    }

    /// The visitor spike for a site right now, if there is one.
    static func visitorSpike(today: SeriesResponse, month: SeriesResponse, timeZone: TimeZone, now: Date, multiplier: Double) -> Spike? {
        guard let usual = usualByHour(month, timeZone: timeZone, now: now),
              let window = lastHour(today, usual: usual, timeZone: timeZone, now: now),
              isSpike(count: Double(window.count), usual: window.usual, multiplier: multiplier, minExtra: minExtraVisitors)
        else { return nil }
        return Spike(kind: .visitors, count: window.count, usual: window.usual, top: nil, at: now)
    }

    /// The conversion spike for a site: conversions in the last hour, from two counts of today's
    /// conversions an hour apart, against the 30 day conversion rate times the visitors this hour usually brings.
    static func conversionSpike(lastHour conversions: Int, usualVisitors: Double, monthRate: Double, now: Date, multiplier: Double) -> Spike? {
        let usual = usualVisitors * monthRate
        guard isSpike(count: Double(conversions), usual: usual, multiplier: multiplier, minExtra: minExtraConversions) else { return nil }
        return Spike(kind: .conversions, count: conversions, usual: usual, top: nil, at: now)
    }

    /// What grew most between two counts taken during the same day: the source that sent the most
    /// visitors since, or the goal that converted most. When the earlier count is from the day
    /// before, today's counts are all since midnight and stand as they are.
    static func topGrowth(now: [String: Int], before: [String: Int]?) -> String? {
        let growth = now.map { ($0.key, $0.value - (before?[$0.key] ?? 0)) }.filter { $0.1 > 0 }
        return growth.max { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 > $1.0 }?.0
    }
}

/// A count of something per name, taken at a moment: today's sources, or today's conversions per goal.
struct Tally: Equatable, Sendable {
    let at: Date
    /// The site's own date, so a count from yesterday is never subtracted from today's.
    let day: String
    let counts: [String: Int]

    var total: Int { counts.values.reduce(0, +) }

    /// The count closest to an hour before `now`, but at least 50 minutes old, from the same day.
    static func hourAgo(_ history: [Tally], now: Date) -> Tally? {
        history.filter { now.timeIntervalSince($0.at) >= 50 * 60 }.max { $0.at < $1.at }
    }
}
