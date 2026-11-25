import Foundation
import Testing
@testable import Runlight

/// Every captured response decodes, and the numbers come through as the dashboard would show them.
struct FixtureDecodingTests {
    @Test func installAndTokens() throws {
        let install = try Fixture.decode(InstallInfo.self, "api")
        #expect(install.name == "runlight")
        #expect(install.api == 1)

        let read = try Fixture.decode(TokenInfo.self, "token-read")
        #expect(read.scope == .read)
        #expect(read.coversAllSites)
        #expect(!read.canEdit)

        let manage = try Fixture.decode(TokenInfo.self, "token-manage")
        #expect(manage.scope == .manage)
        #expect(manage.site == "dailyphototips.com")
        #expect(manage.canEdit)
    }

    @Test func sites() throws {
        let sites = try Fixture.decode(SitesResponse.self, "sites").sites
        #expect(sites.count == 4)
        let dpt = try #require(sites.first { $0.id == "dailyphototips.com" })
        #expect(dpt.name == "DailyPhotoTips")
        #expect(dpt.timeZone.identifier == "America/Toronto")
        #expect(dpt.lastSeen != nil)
        let empty = try #require(sites.first { $0.id == "newsite.dev" })
        #expect(empty.lastSeen == nil)
        #expect(empty.retentionMonths == nil)
    }

    @Test(arguments: ["stats-today", "stats-7d", "stats-30d", "stats-today-empty", "stats-today-london"])
    func stats(name: String) throws {
        let response = try Fixture.decode(StatsResponse.self, name)
        #expect(response.previous != nil)
        #expect(response.stats.visits >= 0)
        #expect((0...1).contains(response.stats.bounceRate))
    }

    @Test func statsNumbers() throws {
        let today = try Fixture.decode(StatsResponse.self, "stats-today")
        #expect(today.range.from == "2026-11-25")
        #expect(today.range.timezone == "America/Toronto")
        #expect(today.stats.visitors > today.previous!.visitors)
        let empty = try Fixture.decode(StatsResponse.self, "stats-today-empty")
        #expect(empty.stats == .zero)
    }

    @Test(arguments: ["series-today", "series-today-london", "series-today-empty"])
    func todaySeriesLinesUpWithYesterday(name: String) throws {
        let series = try Fixture.decode(SeriesResponse.self, name)
        #expect(series.points.count == 24)
        #expect(series.previous?.count == 24)
        // Hours are an hour apart, and yesterday's are exactly a day earlier.
        #expect(series.points[1].start.timeIntervalSince(series.points[0].start) == 3600)
        #expect(series.points[0].start.timeIntervalSince(series.previous![0].start) == 86400)
    }

    @Test func baselineSeries() throws {
        let series = try Fixture.decode(SeriesResponse.self, "series-7d-baseline")
        #expect(series.points.count == 7 * 24)
        #expect(series.previous == nil)
    }

    @Test func goals() throws {
        let today = try Fixture.decode(GoalsResponse.self, "goals-today")
        #expect(today.goals.count == 3)
        let signup = try #require(today.goals.first { $0.goal.name == "Newsletter signup" })
        #expect(signup.goal.kind == .event)
        #expect(signup.goal.fixedValue == 2)
        #expect(signup.numbers.conversions > 0)
        #expect(signup.previous != nil)
        let click = try #require(today.goals.first { $0.goal.kind == .click })
        #expect(click.goal.match == "#buy")

        let definitions = try Fixture.decode(GoalDefinitionsResponse.self, "goals-definitions")
        #expect(definitions.goals.map(\.name).sorted() == ["Buy button", "Newsletter signup", "Thanks page"])
        #expect(definitions.goals.first { $0.kind == .page }?.match == "/thanks*")

        let empty = try Fixture.decode(GoalsResponse.self, "goals-empty")
        #expect(empty.goals.isEmpty)
        _ = try Fixture.decode(GoalsResponse.self, "goals-30d")
    }

    @Test func realtime() throws {
        let live = try Fixture.decode(Realtime.self, "realtime")
        #expect(live.visitors > 0)
        #expect(live.sources.first?.value == "photzy.com")
        #expect(live.minutes?.count == 30)
        #expect(live.recent?.isEmpty == false)
        let quiet = try Fixture.decode(Realtime.self, "realtime-empty")
        #expect(quiet.visitors == 0)
        #expect(quiet.pages.isEmpty)
    }

    @Test func breakdowns() throws {
        let pages = try Fixture.decode(BreakdownResponse.self, "breakdown-page")
        #expect(pages.dimension == "page")
        #expect(pages.rows.count == 5)
        let sources = try Fixture.decode(BreakdownResponse.self, "breakdown-source")
        #expect(sources.rows.first?.value == "photzy.com")
        let many = try Fixture.decode(BreakdownResponse.self, "breakdown-source-50")
        #expect(many.rows.count > 5)
    }

    @Test func links() throws {
        let response = try Fixture.decode(LinksResponse.self, "links")
        let link = try #require(response.links.first)
        #expect(link.slug == "yt")
        #expect(link.clicks == 178)
        #expect(response.shortURL(for: link)?.absoluteString == "https://hub.example/go/yt")

        let detail = try Fixture.decode(LinkDetail.self, "link")
        #expect(detail.clicks == 178)
        #expect(detail.series.reduce(0) { $0 + $1.clicks } == 178)
        #expect(detail.sources?.first?.value == "Google")
    }

    @Test func writes() throws {
        let created = try Fixture.decode(GoalResponse.self, "goal-create").goal
        #expect(created.name == "Download preset")
        #expect(created.fixedValue == nil)
        let updated = try Fixture.decode(GoalResponse.self, "goal-update").goal
        #expect(updated.id == created.id)
        #expect(updated.fixedValue == 5)
        #expect(try Fixture.decode(OKResponse.self, "goal-delete").ok)

        let link = try Fixture.decode(LinkResponse.self, "link-create").link
        #expect(link.slug == "dof")
        let renamed = try Fixture.decode(LinkResponse.self, "link-update").link
        #expect(renamed.slug == "depth")
        #expect(renamed.name == "Depth of field calculator")
        #expect(try Fixture.decode(OKResponse.self, "link-delete").ok)

        let site = try Fixture.decode(SiteResponse.self, "site-update").site
        #expect(site.name == "Daily Photo Tips")
        #expect(site.timezone == "America/New_York")
    }
}

/// Each error the API can send lands in the right bucket for the app to show.
struct ErrorMappingTests {
    func error(_ fixture: String) async -> RunlightError? {
        let server = StubServer()
        server.on("GET", "/api/sites", fixture: fixture)
        do {
            _ = try await server.client().sites()
            return nil
        } catch {
            return error
        }
    }

    @Test func wrongTokenIsRejected() async throws {
        let error = try #require(await error("error-unauthorized"))
        #expect(error.isTokenRejected)
        #expect(error.code == "unauthorized")
        #expect(error.message == "Token rejected.")
    }

    @Test func readTokenCannotEdit() async throws {
        let error = try #require(await error("error-token-read-only"))
        #expect(error.status == 403)
        #expect(error.isReadOnly)
        #expect(!error.isTokenForbidden)
    }

    @Test func otherSitesLookUnknown() async throws {
        // A manage token for one site sees others as missing, not forbidden.
        for name in ["error-unknown-site", "error-token-manage-only"] {
            let error = try #require(await error(name))
            #expect(error.isUnknownSite, "\(name)")
        }
    }

    @Test(arguments: [
        ("error-goal-name", RunlightError.Field.name),
        ("error-goal-page", .match),
        ("error-link-taken", .slug),
        ("error-link-url", .url),
        ("error-retention", .retention),
        ("error-timezone", .timezone),
    ])
    func fieldErrorsNameTheirField(fixture: String, field: RunlightError.Field) async throws {
        let error = try #require(await error(fixture))
        #expect(error.field == field)
        #expect(!error.message.isEmpty)
    }

    @Test func linkTakenKeepsItsParams() async throws {
        guard case .api(_, let problem) = try #require(await error("error-link-taken")) else {
            Issue.record("Expected an API error")
            return
        }
        #expect(problem.params?["slug"] == "yt")
    }

    @Test func sendJSON() async throws {
        let error = try #require(await error("error-send-json"))
        #expect(error.status == 415)
        #expect(error.code == "send_json")
    }

    @Test func hubCouldNotReachTheSite() async throws {
        let server = StubServer()
        server.on("GET", "/api/stats") { _ in .init(status: 502, body: Data(#"{"error":"tulvane.com: Could not reach tulvane.com","code":"unreachable","params":{"host":"tulvane.com"}}"#.utf8)) }
        server.on("GET", "/api/series") { _ in .init(status: 504, body: Data("<html>Gateway Timeout</html>".utf8), contentType: "text/html") }
        await #expect(throws: RunlightError.self) { _ = try await server.client().stats(site: "tulvane.com", period: .today) }
        do {
            _ = try await server.client().stats(site: "tulvane.com", period: .today)
        } catch {
            #expect(error.isSiteUnreachable)
            #expect(error.code == "unreachable")
        }
        do {
            _ = try await server.client().series(site: "tulvane.com", period: .today, interval: "hour", compare: "previous")
        } catch {
            #expect(error == .http(status: 504))
            #expect(error.isSiteUnreachable)
        }
    }

    @Test func noNetworkIsOffline() async {
        let client = RunlightClient(baseURL: URL(string: "https://offline.example")!, token: "rl_x", session: OfflineProtocol.session)
        do {
            _ = try await client.sites()
            Issue.record("Expected to fail")
        } catch {
            #expect(error == .offline)
            #expect(error.isConnectivity)
        }
    }

    @Test func unreadableJSONIsADecodingError() async {
        let server = StubServer()
        server.on("GET", "/api/sites") { _ in .init(status: 200, body: Data(#"{"sites":"nope"}"#.utf8)) }
        do {
            _ = try await server.client().sites()
            Issue.record("Expected to fail")
        } catch {
            guard case .decoding = error else {
                Issue.record("Expected a decoding error, got \(error)")
                return
            }
        }
    }
}

/// The client sends what Runlight expects.
struct RequestShapeTests {
    @Test func readsSendTheTokenAndQuery() async throws {
        let server = StubServer()
        server.on("GET", "/api/stats", fixture: "stats-today")
        let stats = try await server.client(token: "rl_read").stats(site: "dailyphototips.com", period: .today)
        #expect(stats.stats.visitors == 1273)

        let request = try #require(server.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer rl_read")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == nil)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "site", value: "dailyphototips.com")))
        #expect(query.contains(URLQueryItem(name: "period", value: "today")))
    }

    @Test func embeddedInstallsKeepTheirPath() async throws {
        let server = StubServer()
        server.on("GET", "/runlight/api/sites", fixture: "sites")
        let sites = try await server.client(at: "runlight").sites()
        #expect(sites.count == 4)
        #expect(server.requests.first?.url?.path == "/runlight/api/sites")
    }

    @Test func seriesAsksForHoursAndYesterday() async throws {
        let server = StubServer()
        server.on("GET", "/api/series", fixture: "series-today")
        _ = try await server.client().series(site: "dailyphototips.com", period: .today, interval: "hour", compare: "previous")
        let url = try #require(server.requests.first?.url?.absoluteString)
        #expect(url.hasSuffix("/api/series?compare=previous&interval=hour&period=today&site=dailyphototips.com"))
    }

    @Test func createGoalSendsJSON() async throws {
        let server = StubServer()
        server.on("POST", "/api/goals", fixture: "goal-create")
        let goal = try await server.client(token: "rl_manage").createGoal(site: "dailyphototips.com", GoalInput(name: "Download preset", kind: .event, match: "Download"))
        #expect(goal.name == "Download preset")

        let request = try #require(server.requests.first)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.url?.query == "site=dailyphototips.com")
        let body = try #require(server.requestBodies.first)
        #expect(String(decoding: body, as: UTF8.self) == #"{"kind":"event","match":"Download","name":"Download preset","valueMode":"none"}"#)
    }

    @Test func updateGoalWithAFixedValue() async throws {
        let server = StubServer()
        server.on("PATCH", "/api/goals/abc", fixture: "goal-update")
        _ = try await server.client().updateGoal(id: "abc", site: "s", GoalInput(name: "Download a preset", kind: .event, match: "Download", fixedValue: 5))
        let body = try #require(server.requestBodies.first)
        #expect(String(decoding: body, as: UTF8.self) == #"{"kind":"event","match":"Download","name":"Download a preset","value":5,"valueMode":"fixed"}"#)
    }

    @Test func deletesSendJSONToo() async throws {
        let server = StubServer()
        server.on("DELETE", "/api/goals/abc", fixture: "goal-delete")
        server.on("DELETE", "/api/links/xyz", fixture: "link-delete")
        try await server.client().deleteGoal(id: "abc", site: "s")
        try await server.client().deleteLink(id: "xyz", site: "s")
        #expect(server.requests.count == 2)
        for request in server.requests {
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        }
    }

    @Test func linkInputLeavesOutBlankSlug() throws {
        let data = try RunlightClient.encoder.encode(LinkInput(url: "https://example.com", slug: "", name: "Example"))
        #expect(String(decoding: data, as: UTF8.self) == #"{"name":"Example","url":"https:\/\/example.com"}"#)
    }

    @Test func sitePatchSendsOnlyWhatChanged() throws {
        let rename = try RunlightClient.encoder.encode(SitePatch(name: "New name"))
        #expect(String(decoding: rename, as: UTF8.self) == #"{"name":"New name"}"#)
        let forever = try RunlightClient.encoder.encode(SitePatch(retentionMonths: .some(nil)))
        #expect(String(decoding: forever, as: UTF8.self) == #"{"retentionMonths":null}"#)
        let year = try RunlightClient.encoder.encode(SitePatch(retentionMonths: 12))
        #expect(String(decoding: year, as: UTF8.self) == #"{"retentionMonths":12}"#)
    }

    @Test func iconIsNilWhenThereIsNone() async throws {
        let server = StubServer()
        server.on("GET", "/api/icon", fixture: "icon-none")
        #expect(try await server.client().icon(site: "newsite.dev") == nil)
    }

    @Test func aTrailingSlashOnTheBaseIsHarmless() async throws {
        let server = StubServer()
        server.on("GET", "/api/sites", fixture: "sites")
        let client = RunlightClient(baseURL: server.baseURL.appending(path: "/"), token: "rl_x", session: server.session)
        #expect(try await client.sites().count == 4)
    }

    @Test func pathPartsAreEscaped() async throws {
        let server = StubServer()
        server.on("GET", "/api/links/a b", fixture: "link")
        _ = try await server.client().link(id: "a b", site: "s")
        #expect(server.requests.first?.url?.absoluteString.contains("/api/links/a%20b?") == true)
    }
}

/// Finding the API from whatever address someone pastes.
struct ProbeTests {
    @Test(arguments: [
        ("analytics.joncp.dev", "https://analytics.joncp.dev"),
        ("https://analytics.joncp.dev/", "https://analytics.joncp.dev"),
        ("  HTTPS://Analytics.Joncp.dev  ", "https://analytics.joncp.dev"),
        ("https://example.com/runlight/", "https://example.com/runlight"),
        ("https://example.com/runlight/api", "https://example.com/runlight"),
        ("https://example.com/runlight/api/sites?x=1", "https://example.com/runlight"),
        ("https://example.com/runlight/#/settings", "https://example.com/runlight"),
        ("http://localhost:4800/runlight", "http://localhost:4800/runlight"),
        ("https://example.com/apiary", "https://example.com/apiary"),
    ])
    func normalizes(input: String, expected: String) {
        #expect(RunlightClient.normalize(input)?.absoluteString == expected)
    }

    @Test(arguments: ["", "   ", "ftp://example.com", "https://"])
    func refusesNonsense(input: String) {
        #expect(RunlightClient.normalize(input) == nil)
    }

    @Test func findsTheAPIAtTheRoot() async throws {
        let server = StubServer()
        server.on("GET", "/api", fixture: "api")
        let (base, info) = try await RunlightClient.probe(server.baseURL.absoluteString, session: server.session)
        #expect(base == server.baseURL)
        #expect(info.version == "0.5.3")
        // No token goes to an address before it is known to be Runlight.
        #expect(server.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func fallsBackToTheRunlightPath() async throws {
        let server = StubServer()
        server.on("GET", "/runlight/api", fixture: "api")
        let (base, _) = try await RunlightClient.probe(server.baseURL.absoluteString, session: server.session)
        #expect(base.path == "/runlight")
        #expect(server.requests.map { $0.url!.path } == ["/api", "/runlight/api"])
    }

    @Test func refusesSomethingElse() async throws {
        let server = StubServer()
        server.on("GET", "/api") { _ in .init(status: 200, body: Data(#"{"name":"wordpress","version":"7","api":2}"#.utf8)) }
        server.on("GET", "/runlight/api") { _ in .init(status: 200, body: Data("<html></html>".utf8), contentType: "text/html") }
        await #expect(throws: RunlightError.notRunlight) {
            _ = try await RunlightClient.probe(server.baseURL.absoluteString, session: server.session)
        }
    }

    @Test func stopsWhenOffline() async {
        await #expect(throws: RunlightError.offline) {
            _ = try await RunlightClient.probe("https://example.com", session: OfflineProtocol.session)
        }
    }
}
