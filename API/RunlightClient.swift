import Foundation

/// Talks to one Runlight install with one token. Every call is async and throws `RunlightError`.
///
/// `baseURL` is where the API is mounted, without `/api`: the root on a standalone server like
/// analytics.joncp.dev, or `/runlight` on an install inside an app. `probe(_:)` finds it.
struct RunlightClient: Sendable {
    let baseURL: URL
    let token: String
    var session: URLSession = .shared

    // MARK: Finding the API

    /// Finds where an install serves its API: tries `{url}/api`, then `{url}/runlight/api`, and keeps
    /// the first that answers like Runlight. Needs no token. Accepts what people paste: a bare host,
    /// a trailing slash, the dashboard's address, or the API's own.
    static func probe(_ input: String, session: URLSession = .shared) async throws(RunlightError) -> (baseURL: URL, info: InstallInfo) {
        guard let url = normalize(input) else { throw .unreachable("Enter the install's address, like https://example.com/runlight") }
        for candidate in candidates(for: url) {
            do {
                let info: InstallInfo = try await send(Request(method: "GET", path: "/api"), baseURL: candidate, token: nil, session: session)
                if info.name.lowercased() == "runlight" { return (candidate, info) }
            } catch {
                // A connection failure won't get better at another path; a 404 or a stranger's page might.
                if error.isConnectivity { throw error }
            }
        }
        throw .notRunlight
    }

    /// Tidies a pasted address: adds https://, drops a query, a fragment, a trailing slash, and a
    /// trailing `/api` or `/api/...`.
    static func normalize(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://\(text)" }
        guard var parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = parts.host, !host.isEmpty else { return nil }
        parts.scheme = scheme
        parts.host = host.lowercased()
        parts.query = nil
        parts.fragment = nil
        var path = parts.path
        if let api = path.range(of: "/api", options: .backwards), path[api.upperBound...].isEmpty || path[api.upperBound...].hasPrefix("/") {
            path = String(path[..<api.lowerBound])
        }
        while path.hasSuffix("/") { path.removeLast() }
        parts.path = path
        return parts.url
    }

    /// The places to look, most likely first.
    /// Where Runlight may answer for an address: the address itself, then mounted at /runlight, as an
    /// app or a CMS plugin mounts it, then /index.php/runlight, where WordPress with plain permalinks has it.
    static func candidates(for url: URL) -> [URL] {
        if url.path.hasSuffix("/runlight") { return [url] }
        return [url, url.appending(path: "runlight"), url.appending(path: "index.php/runlight")]
    }

    // MARK: Install and token

    func install() async throws(RunlightError) -> InstallInfo {
        try await get("/api")
    }

    func tokenInfo() async throws(RunlightError) -> TokenInfo {
        try await get("/api/token")
    }

    // MARK: Reading

    func sites() async throws(RunlightError) -> [Site] {
        let response: SitesResponse = try await get("/api/sites")
        return response.sites
    }

    /// The site's icon, or nil when it has none (a 404).
    func icon(site: String) async throws(RunlightError) -> Data? {
        do {
            return try await data(Request(method: "GET", path: "/api/icon", query: ["site": site]))
        } catch where error.status == 404 {
            return nil
        }
    }

    func stats(site: String, period: Period) async throws(RunlightError) -> StatsResponse {
        try await get("/api/stats", ["site": site, "period": period.rawValue])
    }

    /// Hourly or daily points. For today with `compare: "previous"`, yesterday's hours line up by position.
    func series(site: String, period: Period, interval: String, compare: String) async throws(RunlightError) -> SeriesResponse {
        try await get("/api/series", ["site": site, "period": period.rawValue, "interval": interval, "compare": compare])
    }

    func goals(site: String, period: Period) async throws(RunlightError) -> GoalsResponse {
        try await get("/api/goals", ["site": site, "period": period.rawValue])
    }

    func goalDefinitions(site: String) async throws(RunlightError) -> [Goal] {
        let response: GoalDefinitionsResponse = try await get("/api/goals", ["site": site, "definitions": "1"])
        return response.goals
    }

    func realtime(site: String) async throws(RunlightError) -> Realtime {
        try await get("/api/realtime", ["site": site])
    }

    func breakdown(site: String, period: Period, dimension: Dimension, limit: Int) async throws(RunlightError) -> BreakdownResponse {
        try await get("/api/breakdown", ["site": site, "period": period.rawValue, "dimension": dimension.rawValue, "limit": String(limit)])
    }

    func links(site: String, period: Period = .thirtyDays) async throws(RunlightError) -> LinksResponse {
        try await get("/api/links", ["site": site, "period": period.rawValue])
    }

    func link(id: String, site: String, period: Period = .thirtyDays) async throws(RunlightError) -> LinkDetail {
        try await get("/api/links/\(Self.escape(id))", ["site": site, "period": period.rawValue])
    }

    // MARK: Editing (a manage token for the site)

    func createGoal(site: String, _ input: GoalInput) async throws(RunlightError) -> Goal {
        let response: GoalResponse = try await write("POST", "/api/goals", site: site, body: input)
        return response.goal
    }

    /// Replaces a goal's settings. Send every field, as the form has them.
    func updateGoal(id: String, site: String, _ input: GoalInput) async throws(RunlightError) -> Goal {
        let response: GoalResponse = try await write("PATCH", "/api/goals/\(Self.escape(id))", site: site, body: input)
        return response.goal
    }

    func deleteGoal(id: String, site: String) async throws(RunlightError) {
        let _: OKResponse = try await write("DELETE", "/api/goals/\(Self.escape(id))", site: site, body: Optional<GoalInput>.none)
    }

    func createLink(site: String, _ input: LinkInput) async throws(RunlightError) -> ShortLink {
        let response: LinkResponse = try await write("POST", "/api/links", site: site, body: input)
        return response.link
    }

    /// Changes only the fields set in `input`.
    func updateLink(id: String, site: String, _ input: LinkInput) async throws(RunlightError) -> ShortLink {
        let response: LinkResponse = try await write("PATCH", "/api/links/\(Self.escape(id))", site: site, body: input)
        return response.link
    }

    func deleteLink(id: String, site: String) async throws(RunlightError) {
        let _: OKResponse = try await write("DELETE", "/api/links/\(Self.escape(id))", site: site, body: Optional<LinkInput>.none)
    }

    func updateSite(id: String, _ patch: SitePatch) async throws(RunlightError) -> Site {
        let response: SiteResponse = try await write("PATCH", "/api/sites/\(Self.escape(id))", site: nil, body: patch)
        return response.site
    }

    // MARK: Plumbing

    struct Request: Sendable {
        var method: String
        var path: String
        var query: [String: String] = [:]
        var body: Data?
    }

    func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws(RunlightError) -> T {
        try await Self.send(Request(method: "GET", path: path, query: query), baseURL: baseURL, token: token, session: session)
    }

    func write<T: Decodable, Body: Encodable>(_ method: String, _ path: String, site: String?, body: Body?) async throws(RunlightError) -> T {
        var request = Request(method: method, path: path, query: site.map { ["site": $0] } ?? [:])
        if let body {
            do { request.body = try Self.encoder.encode(body) } catch { throw .decoding("Couldn't encode the request: \(error)") }
        }
        return try await Self.send(request, baseURL: baseURL, token: token, session: session)
    }

    private func data(_ request: Request) async throws(RunlightError) -> Data {
        try await Self.perform(request, baseURL: baseURL, token: token, session: session)
    }

    static func send<T: Decodable>(_ request: Request, baseURL: URL, token: String?, session: URLSession) async throws(RunlightError) -> T {
        let data = try await perform(request, baseURL: baseURL, token: token, session: session)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw .decoding(String(describing: error))
        }
    }

    /// Builds the URLRequest Runlight expects: a bearer token, JSON for every write (or it answers
    /// 415), and no caching, since the numbers change by the minute.
    static func urlRequest(_ request: Request, baseURL: URL, token: String?) -> URLRequest {
        var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        var base = parts.percentEncodedPath
        while base.hasSuffix("/") { base.removeLast() }
        parts.percentEncodedPath = base + request.path
        if !request.query.isEmpty {
            parts.queryItems = request.query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var urlRequest = URLRequest(url: parts.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        urlRequest.httpMethod = request.method
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if request.method != "GET" {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = request.body ?? Data("{}".utf8)
        }
        return urlRequest
    }

    private static func perform(_ request: Request, baseURL: URL, token: String?, session: URLSession) async throws(RunlightError) -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlRequest(request, baseURL: baseURL, token: token))
        } catch let error as URLError {
            throw .from(error)
        } catch {
            throw .unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw .notRunlight }
        guard (200..<300).contains(http.statusCode) else {
            if let problem = try? decoder.decode(APIProblem.self, from: data) {
                throw .api(status: http.statusCode, problem: problem)
            }
            throw .http(status: http.statusCode)
        }
        return data
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    static func escape(_ part: String) -> String {
        part.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? part
    }
}
