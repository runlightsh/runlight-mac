import Foundation

// The shapes Runlight's HTTP API answers with (https://runlight.sh/docs/api/). Every model ignores
// fields it doesn't know, and every enum keeps a value it doesn't know rather than failing, so a
// newer Runlight never breaks an older app. Times arrive as epoch milliseconds and decode to Date.

// MARK: Install and token

/// `GET /api`: who answered.
struct InstallInfo: Codable, Equatable, Sendable {
    let name: String
    let version: String
    let api: Int
    var library: String?
    var language: String?
}

enum TokenScope: Equatable, Sendable, Codable {
    case read, manage, embed
    case other(String)

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = switch raw {
        case "read": .read
        case "manage": .manage
        case "embed": .embed
        default: .other(raw)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var rawValue: String {
        switch self {
        case .read: "read"
        case .manage: "manage"
        case .embed: "embed"
        case .other(let raw): raw
        }
    }
}

/// `GET /api/token`: what the token may do. An empty site means every site.
struct TokenInfo: Codable, Equatable, Sendable {
    let scope: TokenScope
    let site: String

    var coversAllSites: Bool { site.isEmpty }
    var canEdit: Bool { scope == .manage }
}

// MARK: Sites

struct Site: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var hostnames: [String]
    var timezone: String
    /// When the site last had a visit; nil before its first.
    var lastSeen: Date?
    /// How many months of visits are kept; nil keeps everything.
    var retentionMonths: Int?

    var timeZone: TimeZone { TimeZone(identifier: timezone) ?? .current }
}

struct SitesResponse: Codable, Sendable {
    let sites: [Site]
}

/// The months a site may keep, or nil for forever.
enum Retention {
    static let choices: [Int?] = [6, 12, 24, 36, 60, nil]
}

// MARK: Reports

enum Period: String, CaseIterable, Codable, Sendable {
    case today
    case sevenDays = "7d"
    case thirtyDays = "30d"
}

/// The days a report covers, in the site's timezone.
struct ReportRange: Codable, Equatable, Sendable {
    let from: String
    let to: String
    var interval: String?
    var timezone: String?
}

struct CompareRange: Codable, Equatable, Sendable {
    let from: String
    let to: String
}

/// The headline numbers. Bounce rate is a fraction from 0 to 1; visit duration is milliseconds.
struct Stats: Codable, Equatable, Sendable {
    let visitors: Int
    let visits: Int
    let pageviews: Int
    let viewsPerVisit: Double
    let bounceRate: Double
    let visitDuration: Double

    static let zero = Stats(visitors: 0, visits: 0, pageviews: 0, viewsPerVisit: 0, bounceRate: 0, visitDuration: 0)
}

struct StatsResponse: Codable, Equatable, Sendable {
    let site: String
    let range: ReportRange
    var compare: CompareRange?
    let stats: Stats
    var previous: Stats?
}

struct SeriesPoint: Codable, Equatable, Sendable {
    let start: Date
    let visitors: Int
    let visits: Int
    let pageviews: Int
    var viewsPerVisit: Double?
    var bounceRate: Double?
    var visitDuration: Double?
}

/// Points for each hour or day of the range. With a comparison, `previous` lines up with `points`
/// by position: the same hour of the day before, for today.
struct SeriesResponse: Codable, Equatable, Sendable {
    let site: String
    let range: ReportRange
    var compare: CompareRange?
    let points: [SeriesPoint]
    var previous: [SeriesPoint]?
}

struct BreakdownRow: Codable, Equatable, Sendable {
    let value: String
    let visitors: Int
    var visits: Int?
    var pageviews: Int?
    var bounceRate: Double?
    var visitDuration: Double?
}

struct BreakdownResponse: Codable, Equatable, Sendable {
    let site: String
    let range: ReportRange
    let dimension: String
    let rows: [BreakdownRow]
}

enum Dimension: String, Sendable {
    case page, source, channel, referrer, country, device, browser
}

// MARK: Realtime

struct ValueCount: Codable, Equatable, Sendable {
    let value: String
    let visitors: Int
}

struct RecentActivity: Codable, Equatable, Sendable {
    let ts: Date
    let kind: String
    let path: String
    var name: String?
    var country: String?
    var city: String?
    var source: String?
    var device: String?
}

/// The last five minutes, with pageviews for each of the last thirty.
struct Realtime: Codable, Equatable, Sendable {
    let visitors: Int
    let pages: [ValueCount]
    let sources: [ValueCount]
    var countries: [ValueCount]?
    var minutes: [Int]?
    var recent: [RecentActivity]?
}

// MARK: Goals

enum GoalKind: Equatable, Sendable, Codable, Hashable {
    case event, page, click
    case other(String)

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = switch raw {
        case "event": .event
        case "page": .page
        case "click": .click
        default: .other(raw)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var rawValue: String {
        switch self {
        case .event: "event"
        case .page: "page"
        case .click: "click"
        case .other(let raw): raw
        }
    }
}

/// A goal as it is set up.
struct Goal: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let site: String
    var name: String
    var kind: GoalKind
    var match: String
    var clickBy: String?
    /// "none", "fixed", or "prop".
    var valueMode: String?
    var value: Double?
    var valueProp: String?
    var currency: String?
    var createdAt: Date?

    /// A fixed amount each conversion is worth, when it has one.
    var fixedValue: Double? { valueMode == "fixed" ? value : nil }
}

struct GoalNumbers: Codable, Equatable, Sendable {
    let conversions: Int
    let visitors: Int
    var revenue: Double?
    let rate: Double
}

/// A goal with its numbers for the period. The API sends them flat, in one object, and the cache
/// keeps them the same way.
struct GoalResult: Codable, Equatable, Identifiable, Sendable {
    let goal: Goal
    let numbers: GoalNumbers
    var previous: GoalNumbers?

    var id: String { goal.id }

    private enum CodingKeys: String, CodingKey { case previous }

    init(goal: Goal, numbers: GoalNumbers, previous: GoalNumbers? = nil) {
        self.goal = goal
        self.numbers = numbers
        self.previous = previous
    }

    init(from decoder: Decoder) throws {
        goal = try Goal(from: decoder)
        numbers = try GoalNumbers(from: decoder)
        previous = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(GoalNumbers.self, forKey: .previous)
    }

    func encode(to encoder: Encoder) throws {
        try goal.encode(to: encoder)
        try numbers.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(previous, forKey: .previous)
    }
}

struct GoalsResponse: Codable, Equatable, Sendable {
    let site: String
    var range: ReportRange?
    /// Everyone who visited in the period, the rate's denominator.
    var visitors: Int?
    let goals: [GoalResult]
}

struct GoalDefinitionsResponse: Codable, Sendable {
    let site: String
    let goals: [Goal]
}

// MARK: Links

struct ShortLink: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let site: String
    /// A custom link domain, or empty for the install's own link path.
    var domain: String
    var slug: String
    var name: String
    var url: String
    var createdAt: Date?
    var updatedAt: Date?
    var clicks: Int?
    var visitors: Int?
}

struct LinksResponse: Codable, Sendable {
    /// Where links without a domain are served, like https://example.com/go.
    let prefix: String
    let domains: [String]
    let links: [ShortLink]

    func shortURL(for link: ShortLink) -> URL? {
        link.domain.isEmpty ? URL(string: "\(prefix)/\(link.slug)") : URL(string: "https://\(link.domain)/\(link.slug)")
    }
}

struct LinkClicksPoint: Codable, Equatable, Sendable {
    let start: Date
    let clicks: Int
    var visitors: Int?
}

struct LinkCount: Codable, Equatable, Sendable {
    let value: String
    let visitors: Int
    var events: Int?
}

/// One link's clicks over time and where they came from.
struct LinkDetail: Codable, Sendable {
    let link: ShortLink
    var range: ReportRange?
    let clicks: Int
    let series: [LinkClicksPoint]
    var sources: [LinkCount]?
    var referrers: [LinkCount]?
    var countries: [LinkCount]?
    var devices: [LinkCount]?
    var browsers: [LinkCount]?
}

