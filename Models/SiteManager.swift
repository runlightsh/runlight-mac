import Foundation

/// What one Manage window shows and changes: a site's goals with their conversions, its short links
/// with their clicks, and its settings. Reads use the connection's read token; every change uses
/// the site's manage token.
@MainActor
@Observable
final class SiteManager {
    let key: SiteKey
    private weak var model: AppModel?

    /// Goals with their conversions over the last 30 days.
    private(set) var goals: [GoalResult] = []
    private(set) var links: [ShortLink] = []
    /// Where links without a domain of their own are served, like https://example.com/go.
    private(set) var linkPrefix = ""
    private(set) var linkDomains: [String] = []
    /// Each link's clicks by day, once looked at.
    private(set) var linkClicks: [String: [LinkClicksPoint]] = [:]
    /// Funnels with each step's visits over the last 30 days.
    private(set) var funnels: [Funnel] = []
    private(set) var reports: [EmailReport] = []
    /// The languages an email report can be written in.
    private(set) var reportLanguages: [String] = ["en"]
    private(set) var shares: [ShareLink] = []
    /// Whether each link domain points here yet, once checked.
    private(set) var domainChecks: [String: LinkDomainCheck] = [:]
    private(set) var loading = false
    private(set) var loaded = false
    private(set) var loadError: String?

    init(key: SiteKey, model: AppModel) {
        self.key = key
        self.model = model
    }

    var site: Site? {
        model?.connections.first { $0.id == key.connection }?.sites.first { $0.id == key.site }
    }

    var canEdit: Bool { model?.canEdit(key) ?? false }

    var connectionName: String {
        model?.connections.first { $0.id == key.connection }?.connection.name ?? ""
    }

    // MARK: Loading

    func load() async {
        guard let client = model?.client(for: key.connection) else {
            loadError = "This connection's token is missing. Replace it in Settings, Connections."
            return
        }
        loading = true
        defer { loading = false }
        do throws(RunlightError) {
            let goals = try await client.goals(site: key.site, period: .thirtyDays)
            let links = try await client.links(site: key.site, period: .thirtyDays)
            self.goals = goals.goals
            self.links = links.links
            linkPrefix = links.prefix
            linkDomains = links.domains
            // The rest are newer, or may be off on some installs: one that fails leaves its pane empty.
            funnels = (try? await client.funnels(site: key.site, period: .thirtyDays)) ?? funnels
            // Reports and share links are settings, which only a manage token reads.
            if let editor = model?.manageClient(for: key) {
                if let found = try? await editor.reports(site: key.site) {
                    reports = found.reports
                    reportLanguages = found.languages.isEmpty ? ["en"] : found.languages
                }
                shares = (try? await editor.shares(site: key.site)) ?? shares
            } else {
                reports = []
                shares = []
            }
            loadError = nil
            loaded = true
        } catch {
            loadError = error.message
        }
    }

    func loadClicks(_ link: ShortLink) async {
        guard let client = model?.client(for: key.connection),
              let detail = try? await client.link(id: link.id, site: key.site) else { return }
        linkClicks[link.id] = detail.series
    }

    /// A share link's full address.
    func shareURL(_ share: ShareLink) -> String {
        guard let base = model?.connections.first(where: { $0.id == key.connection })?.connection.baseURL,
              var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return share.path }
        parts.percentEncodedPath = share.path
        return parts.url?.absoluteString ?? share.path
    }

    func checkDomain(_ domain: String) async {
        guard let client = model?.manageClient(for: key),
              let check = try? await client.checkLinkDomain(site: key.site, domain: domain) else { return }
        domainChecks[domain] = check
    }

    func shortURL(_ link: ShortLink) -> String {
        link.domain.isEmpty ? "\(linkPrefix)/\(link.slug)" : "https://\(link.domain)/\(link.slug)"
    }

    // MARK: Changing

    /// What went wrong with a change: a message for one field, or for the form as a whole.
    struct Failure: Error, Equatable {
        var field: RunlightError.Field?
        var message: String
        /// The token can't edit this site, so the window should offer to add one.
        var needsManageToken = false
    }

    func saveGoal(_ input: GoalInput, editing id: String?) async throws(Failure) {
        let client = try editor()
        do throws(RunlightError) {
            if let id {
                _ = try await client.updateGoal(id: id, site: key.site, input)
            } else {
                _ = try await client.createGoal(site: key.site, input)
            }
        } catch {
            throw failure(error)
        }
        await changed(goals: true)
    }

    func deleteGoal(_ goal: Goal) async throws(Failure) {
        let client = try editor()
        do throws(RunlightError) {
            try await client.deleteGoal(id: goal.id, site: key.site)
        } catch {
            throw failure(error)
        }
        goals.removeAll { $0.goal.id == goal.id }
        await changed(goals: true)
    }

    @discardableResult
    func saveLink(_ input: LinkInput, editing id: String?) async throws(Failure) -> ShortLink {
        let client = try editor()
        let link: ShortLink
        do throws(RunlightError) {
            link = id == nil ? try await client.createLink(site: key.site, input) : try await client.updateLink(id: id!, site: key.site, input)
        } catch {
            throw failure(error)
        }
        await changed(goals: false)
        return link
    }

    func deleteLink(_ link: ShortLink) async throws(Failure) {
        let client = try editor()
        do throws(RunlightError) {
            try await client.deleteLink(id: link.id, site: key.site)
        } catch {
            throw failure(error)
        }
        links.removeAll { $0.id == link.id }
        linkClicks[link.id] = nil
    }

    func saveFunnel(_ input: FunnelInput, editing id: String?) async throws(Failure) {
        let client = try editor()
        do throws(RunlightError) {
            _ = try await client.saveFunnel(id: id, site: key.site, input)
        } catch {
            throw failure(error)
        }
        await load()
    }

    func deleteFunnel(_ funnel: Funnel) async throws(Failure) {
        let client = try editor()
        do throws(RunlightError) {
            try await client.deleteFunnel(id: funnel.id, site: key.site)
        } catch {
            throw failure(error)
        }
        funnels.removeAll { $0.id == funnel.id }
    }

    func addReport(_ input: ReportInput) async throws(Failure) {
        let client = try editor()
        do throws(RunlightError) {
            reports.append(try await client.addReport(site: key.site, input))
        } catch {
            throw failure(error)
        }
    }

    func deleteReport(_ report: EmailReport) async throws(Failure) {
        let client = try editor()
        do throws(RunlightError) {
            try await client.deleteReport(id: report.id, site: key.site)
        } catch {
            throw failure(error)
        }
        reports.removeAll { $0.id == report.id }
    }

    func sendReport(_ report: EmailReport) async throws(Failure) {
        let client = try editor()
        do throws(RunlightError) {
            try await client.sendReport(id: report.id, site: key.site)
        } catch {
            throw failure(error)
        }
        await load()
    }

    @discardableResult
    func saveShare(name: String, editing id: String?) async throws(Failure) -> ShareLink {
        let client = try editor()
        let share: ShareLink
        do throws(RunlightError) {
            share = id == nil ? try await client.createShare(site: key.site, name: name) : try await client.renameShare(id: id!, site: key.site, name: name)
        } catch {
            throw failure(error)
        }
        if let index = shares.firstIndex(where: { $0.id == share.id }) { shares[index] = share } else { shares.append(share) }
        return share
    }

    func deleteShare(_ share: ShareLink) async throws(Failure) {
        let client = try editor()
        do throws(RunlightError) {
            try await client.deleteShare(id: share.id, site: key.site)
        } catch {
            throw failure(error)
        }
        shares.removeAll { $0.id == share.id }
    }

    func addDomain(_ domain: String) async throws(Failure) {
        let client = try editor()
        do throws(RunlightError) {
            try await client.addLinkDomain(site: key.site, domain: domain)
        } catch {
            throw failure(error)
        }
        await load()
        await checkDomain(domain.lowercased())
    }

    func removeDomain(_ domain: String) async throws(Failure) {
        let client = try editor()
        do throws(RunlightError) {
            try await client.removeLinkDomain(site: key.site, domain: domain)
        } catch {
            throw failure(error)
        }
        linkDomains.removeAll { $0 == domain }
        domainChecks[domain] = nil
    }

    func saveSettings(_ patch: SitePatch) async throws(Failure) {
        let client = try editor()
        do throws(RunlightError) {
            _ = try await client.updateSite(id: key.site, patch)
        } catch {
            throw failure(error)
        }
        // The new name and timezone reach the popover and every list through the site list.
        await model?.refreshSites(key.connection)
    }

    private func editor() throws(Failure) -> RunlightClient {
        guard let client = model?.manageClient(for: key) else {
            throw Failure(message: "Editing needs a manage token for this site.", needsManageToken: true)
        }
        return client
    }

    private func failure(_ error: RunlightError) -> Failure {
        if error.isReadOnly || error.isTokenForbidden || error.isUnknownSite || error.isTokenRejected {
            return Failure(message: "This site's manage token can't make changes any more. Add a new one.", needsManageToken: true)
        }
        return Failure(field: error.field, message: error.message)
    }

    /// After a change, the window's lists and the popover's numbers catch up.
    private func changed(goals: Bool) async {
        await load()
        if goals, let model {
            await model.perform(.goals(key, .today))
            if model.period != .today { await model.perform(.goals(key, model.period)) }
        }
    }
}
