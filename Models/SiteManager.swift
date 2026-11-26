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
