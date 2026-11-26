import Foundation

// MARK: Funnels, email reports, sharing, and link domains
//
// Each reads with the read token and changes with a site's manage token, like goals and links.

struct FunnelStep: Codable, Equatable, Sendable {
    /// "page" or "event".
    var kind: String
    var match: String
    /// Visits that reached this step in the period, when read with numbers.
    var visits: Int?

    private enum CodingKeys: String, CodingKey { case kind, match, visits }

    init(kind: String, match: String, visits: Int? = nil) {
        self.kind = kind
        self.match = match
        self.visits = visits
    }

    /// Only the step itself goes to the server.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(match, forKey: .match)
    }
}

struct Funnel: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var steps: [FunnelStep]
    /// Counted over only the newest this many visits, in a busy range.
    var sampled: Int?
}

struct FunnelInput: Encodable, Equatable, Sendable {
    var name: String
    var steps: [FunnelStep]
}

struct EmailReport: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let site: String
    let email: String
    /// "weekly" or "monthly".
    let frequency: String
    let lang: String
    var lastSentAt: Date?
    var createdAt: Date?
}

struct ReportInput: Encodable, Equatable, Sendable {
    var email: String
    var frequency: String
    var lang: String
}

struct ShareLink: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let site: String
    var name: String
    var createdAt: Date?
    /// The share's address on the install, such as /share/abc.
    let path: String
}

/// Whether a link domain points at this install yet, and where it should.
struct LinkDomainCheck: Codable, Equatable, Sendable {
    struct Target: Codable, Equatable, Sendable {
        let host: String
        let addresses: [String]
    }

    let domain: String
    let working: Bool
    let reason: String
    var code: String?
    var target: Target?
}

/// What any change answers when the app only needs to know it worked.
struct Accepted: Decodable, Sendable {
    init(from decoder: Decoder) throws {}
}

private struct FunnelsResponse: Decodable { let funnels: [Funnel] }
private struct FunnelResponse: Decodable { let funnel: Funnel }
private struct ReportsResponse: Decodable { let reports: [EmailReport]; let languages: [String]? }
private struct ReportResponse: Decodable { let report: EmailReport }
private struct SharesResponse: Decodable { let shares: [ShareLink] }
private struct ShareResponse: Decodable { let share: ShareLink }
private struct DomainsResponse: Decodable { let domains: [String] }
private struct NameBody: Encodable { let name: String }
private struct DomainBody: Encodable { let domain: String }
private struct Empty: Encodable {}

extension RunlightClient {
    func funnels(site: String, period: Period) async throws(RunlightError) -> [Funnel] {
        let response: FunnelsResponse = try await get("/api/funnels", ["site": site, "period": period.rawValue])
        return response.funnels
    }

    func saveFunnel(id: String?, site: String, _ input: FunnelInput) async throws(RunlightError) -> Funnel {
        let response: FunnelResponse = try await write(id == nil ? "POST" : "PATCH", "/api/funnels" + (id.map { "/" + Self.escape($0) } ?? ""), site: site, body: input)
        return response.funnel
    }

    func deleteFunnel(id: String, site: String) async throws(RunlightError) {
        let _: Accepted = try await write("DELETE", "/api/funnels/\(Self.escape(id))", site: site, body: Optional<Empty>.none)
    }

    /// The site's email reports, and the languages a report can be written in.
    func reports(site: String) async throws(RunlightError) -> (reports: [EmailReport], languages: [String]) {
        let response: ReportsResponse = try await get("/api/reports", ["site": site])
        return (response.reports, response.languages ?? ["en"])
    }

    func addReport(site: String, _ input: ReportInput) async throws(RunlightError) -> EmailReport {
        let response: ReportResponse = try await write("POST", "/api/reports", site: site, body: input)
        return response.report
    }

    func deleteReport(id: String, site: String) async throws(RunlightError) {
        let _: Accepted = try await write("DELETE", "/api/reports/\(Self.escape(id))", site: site, body: Optional<Empty>.none)
    }

    /// Sends a report now, for the period just finished.
    func sendReport(id: String, site: String) async throws(RunlightError) {
        let _: Accepted = try await write("POST", "/api/reports/\(Self.escape(id))/send", site: site, body: Empty())
    }

    func shares(site: String) async throws(RunlightError) -> [ShareLink] {
        let response: SharesResponse = try await get("/api/shares", ["site": site])
        return response.shares
    }

    func createShare(site: String, name: String) async throws(RunlightError) -> ShareLink {
        let response: ShareResponse = try await write("POST", "/api/shares", site: site, body: NameBody(name: name))
        return response.share
    }

    func renameShare(id: String, site: String, name: String) async throws(RunlightError) -> ShareLink {
        let response: ShareResponse = try await write("PATCH", "/api/shares/\(Self.escape(id))", site: site, body: NameBody(name: name))
        return response.share
    }

    func deleteShare(id: String, site: String) async throws(RunlightError) {
        let _: Accepted = try await write("DELETE", "/api/shares/\(Self.escape(id))", site: site, body: Optional<Empty>.none)
    }

    func linkDomains(site: String) async throws(RunlightError) -> [String] {
        let response: DomainsResponse = try await get("/api/link-domains", ["site": site])
        return response.domains
    }

    func addLinkDomain(site: String, domain: String) async throws(RunlightError) {
        let _: Accepted = try await write("POST", "/api/link-domains", site: site, body: DomainBody(domain: domain))
    }

    func checkLinkDomain(site: String, domain: String) async throws(RunlightError) -> LinkDomainCheck {
        try await get("/api/link-domains/\(Self.escape(domain))/check", ["site": site])
    }

    func removeLinkDomain(site: String, domain: String) async throws(RunlightError) {
        let _: Accepted = try await write("DELETE", "/api/link-domains/\(Self.escape(domain))", site: site, body: Optional<Empty>.none)
    }
}
