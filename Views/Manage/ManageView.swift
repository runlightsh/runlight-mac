import SwiftUI

enum ManagePane: String, CaseIterable, Identifiable {
    case goals, links, settings
    var id: Self { self }

    var title: String {
        switch self {
        case .goals: "Goals"
        case .links: "Links"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .goals: "flag"
        case .links: "link"
        case .settings: "slider.horizontal.3"
        }
    }
}

/// The right side of a site's Manage window: the pane chosen in the sidebar. Without a manage
/// token it still shows everything, read-only, with one line saying why and a way to allow editing.
struct ManageDetail: View {
    let manager: SiteManager
    @Bindable var selection: ManageSelection

    @State private var addingToken = false

    var body: some View {
        VStack(spacing: 0) {
            if !manager.canEdit {
                ReadOnlyBanner(key: manager.key, siteName: manager.site?.name ?? manager.key.site, connectionName: manager.connectionName) { addingToken = true }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Group {
                switch selection.pane {
                case .goals: GoalsPane(manager: manager, needsToken: { addingToken = true })
                case .links: LinksPane(manager: manager, needsToken: { addingToken = true })
                case .settings: SiteSettingsPane(manager: manager, needsToken: { addingToken = true })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .animation(Theme.Motion.push, value: manager.canEdit)
        .frame(minWidth: 480, minHeight: 440)
        .sheet(isPresented: $addingToken) {
            ManageTokenSheet(key: manager.key, siteName: manager.site?.name ?? manager.key.site) { addingToken = false }
        }
    }
}

/// The window's sidebar: the site, its three panes with counts, and whether it can be edited.
struct ManageSidebar: View {
    let manager: SiteManager
    @Bindable var selection: ManageSelection

    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: Binding(get: { selection.pane }, set: { if let pane = $0 { selection.pane = pane } })) {
            Section {
                ForEach(ManagePane.allCases) { pane in
                    Label(pane.title, systemImage: pane.symbol)
                        .badge(count(pane))
                        .tag(pane)
                }
            } header: {
                header
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { footer }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.s) {
            if let site = manager.site {
                SiteIcon(key: manager.key, site: site, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(site.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(site.hostnames.first ?? site.id)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .textCase(nil)
        .padding(.bottom, Theme.Space.s)
    }

    private func count(_ pane: ManagePane) -> Int {
        guard manager.loaded else { return 0 }
        switch pane {
        case .goals: return manager.goals.count
        case .links: return manager.links.count
        case .settings: return 0
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(manager.canEdit ? Theme.lamp : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
            Text(manager.canEdit ? "Can edit" : "Read-only")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .contextMenu {
            if manager.canEdit {
                Button("Remove Manage Token") { model.removeManageToken(manager.key) }
            }
        }
        .help(manager.canEdit ? "This site's manage token is in the Keychain." : "Allow editing to change goals, links, and settings.")
    }
}

// MARK: Read-only

private struct ReadOnlyBanner: View {
    let key: SiteKey
    let siteName: String
    let connectionName: String
    let pasteToken: () -> Void

    @Environment(AppModel.self) private var model
    @State private var waiting: Task<Void, Never>?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: waiting == nil ? "lock.fill" : "safari")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .contentTransition(.symbolEffect(.replace))
                Text(waiting == nil
                     ? "Read-only. Allow editing \(siteName) by signing in to \(connectionName) in your browser."
                     : "Allow Runlight on the page in your browser, then come back here.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Theme.Space.s)
                if waiting == nil {
                    Button("Paste a Token…", action: pasteToken)
                        .buttonStyle(LinkButtonStyle())
                    Button("Allow Editing…", action: allow)
                        .buttonStyle(LampButtonStyle(compact: true))
                } else {
                    Spinner()
                    Button("Cancel") { waiting?.cancel() }
                        .buttonStyle(QuietButtonStyle(compact: true))
                }
            }
            if let problem {
                Text(problem)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.down)
                    .padding(.leading, 19)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s + 2)
        .background(.primary.opacity(0.04))
        .overlay(alignment: .bottom) { Hairline() }
        .animation(Theme.Motion.hover, value: waiting == nil)
        .animation(Theme.Motion.hover, value: problem)
    }

    private func allow() {
        problem = nil
        waiting = Task {
            do throws(ConnectError) {
                try await model.allowEditing(key) { url in NSWorkspace.shared.open(url) }
                // Back from the browser: Runlight comes forward again.
                DockPresence.bringForward()
            } catch {
                if !Task.isCancelled { problem = error.message }
            }
            waiting = nil
        }
    }
}

/// Pastes a manage token for one site, checked against the install before it's kept.
struct ManageTokenSheet: View {
    let key: SiteKey
    let siteName: String
    let done: () -> Void

    @Environment(AppModel.self) private var model
    @State private var token = ""
    @State private var error: String?
    @State private var working = false
    @FocusState private var focused: Bool

    var body: some View {
        SheetFrame(title: "Add a Manage Token", detail: "In the dashboard, open Settings, then MCP & API, and make a manage token for \(siteName). It can change only this site's goals, links, and settings.") {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                RunlightField(label: "Manage token", placeholder: "rl_…", text: $token, secure: true, error: error, focused: $focused, onSubmit: save)
                HStack {
                    Spacer()
                    Button("Cancel", action: done)
                        .buttonStyle(QuietButtonStyle(compact: true))
                        .keyboardShortcut(.cancelAction)
                        .disabled(working)
                    Button(action: save) {
                        HStack(spacing: 6) {
                            if working { Spinner() }
                            Text(working ? "Checking…" : "Add Token")
                        }
                    }
                    .buttonStyle(LampButtonStyle(compact: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || token.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear { focused = true }
    }

    private func save() {
        working = true
        error = nil
        Task {
            do throws(ConnectError) {
                try await model.addManageToken(key, token: token)
                done()
            } catch {
                self.error = error.message
            }
            working = false
        }
    }
}

// MARK: Shared pieces

/// A pane's title, what it shows, and its add button.
private struct PaneHeader: View {
    let title: String
    let detail: String
    let add: String
    let canAdd: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 17, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: action) {
                Label(add, systemImage: "plus")
            }
            .buttonStyle(LampButtonStyle(compact: true))
            .disabled(!canAdd)
            .help(canAdd ? add : "Add a manage token to make changes")
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.top, Theme.Space.l)
        .padding(.bottom, Theme.Space.m)
    }
}

/// Loading, a failure, or an empty list, in the middle of a pane.
private struct PaneState: View {
    let symbol: String
    let title: String
    let detail: String
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            if let retry {
                Button("Try Again", action: retry)
                    .buttonStyle(QuietButtonStyle(compact: true))
                    .padding(.top, Theme.Space.xs)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A form's error that belongs to no one field.
private struct FormError: View {
    let message: String?

    var body: some View {
        if let message {
            Label(message, systemImage: "exclamationmark.circle.fill")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.down)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
        }
    }
}

// MARK: Goals

private struct GoalsPane: View {
    let manager: SiteManager
    let needsToken: () -> Void

    @State private var editing: GoalEdit?
    @State private var deleting: Goal?
    @State private var problem: String?

    struct GoalEdit: Identifiable {
        let goal: Goal?
        var id: String { goal?.id ?? "new" }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Goals", detail: "Conversions in the last 30 days", add: "Add Goal", canAdd: manager.canEdit) {
                editing = GoalEdit(goal: nil)
            }
            if let problem {
                FormError(message: problem).padding(.horizontal, Theme.Space.xl).padding(.bottom, Theme.Space.s)
            }
            if !manager.loaded {
                if let error = manager.loadError {
                    PaneState(symbol: "exclamationmark.triangle", title: "Couldn't load the goals", detail: error) { Task { await manager.load() } }
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if manager.goals.isEmpty {
                PaneState(symbol: "flag", title: "No goals yet", detail: "A goal counts a page visit, like /thanks, or an event your site sends, like Signup.")
            } else {
                List {
                    ForEach(manager.goals) { result in
                        GoalRow(result: result)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { edit(result.goal) }
                            .contextMenu {
                                Button("Edit…") { edit(result.goal) }
                                    .disabled(!manager.canEdit || result.goal.kind == .click)
                                Button("Delete…", role: .destructive) { deleting = result.goal }
                                    .disabled(!manager.canEdit)
                            }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
                .scrollContentBackground(.hidden)
            }
        }
        .sheet(item: $editing) { edit in
            GoalForm(manager: manager, goal: edit.goal, needsToken: needsToken) { editing = nil }
        }
        .confirmationDialog(
            "Delete the goal \u{201C}\(deleting?.name ?? "")\u{201D}?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { goal in
            Button("Delete Goal", role: .destructive) {
                Task {
                    do throws(SiteManager.Failure) {
                        try await manager.deleteGoal(goal)
                        problem = nil
                    } catch {
                        problem = error.message
                        if error.needsManageToken { needsToken() }
                    }
                }
            }
        } message: { _ in
            Text("It leaves Runlight's goal reports, here and in the dashboard, and stops counting conversions.")
        }
    }

    private func edit(_ goal: Goal) {
        guard manager.canEdit, goal.kind != .click else { return }
        editing = GoalEdit(goal: goal)
    }
}

private struct GoalRow: View {
    let result: GoalResult

    var body: some View {
        let goal = result.goal
        HStack(spacing: Theme.Space.m) {
            Image(systemName: Self.symbol(goal.kind))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.series)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.series.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(goal.name).font(.system(size: 13, weight: .medium))
                HStack(spacing: 6) {
                    Text(Self.kindName(goal.kind)).foregroundStyle(.secondary)
                    Text(goal.match).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    if let amount = goal.fixedValue, amount > 0 {
                        Text("\(amount.formatted(.currency(code: goal.currency ?? "USD"))) each").foregroundStyle(.tertiary)
                    }
                }
                .font(.system(size: 11))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(result.numbers.conversions.formatted(.number))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(NumberText.share(result.numbers.rate) + " rate")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .help(goal.kind == .click ? "Click goals are edited in the dashboard, where you can pick the element on your site." : "")
        .accessibilityElement(children: .combine)
    }

    static func symbol(_ kind: GoalKind) -> String {
        switch kind {
        case .page: "doc.text"
        case .event: "bolt"
        case .click: "cursorarrow.click"
        case .other: "flag"
        }
    }

    static func kindName(_ kind: GoalKind) -> String {
        switch kind {
        case .page: "Page"
        case .event: "Event"
        case .click: "Click"
        case .other(let raw): raw.capitalized
        }
    }
}

/// Adds or edits a page or event goal. Click goals need the dashboard's element picker.
private struct GoalForm: View {
    let manager: SiteManager
    let goal: Goal?
    let needsToken: () -> Void
    let done: () -> Void

    @State private var input: GoalInput
    @State private var amount: String
    @State private var hasAmount: Bool
    @State private var errors: [RunlightError.Field: String] = [:]
    @State private var problem: String?
    @State private var working = false
    @FocusState private var nameFocused: Bool
    @FocusState private var matchFocused: Bool
    @FocusState private var amountFocused: Bool

    init(manager: SiteManager, goal: Goal?, needsToken: @escaping () -> Void, done: @escaping () -> Void) {
        self.manager = manager
        self.goal = goal
        self.needsToken = needsToken
        self.done = done
        let input = goal.map(GoalInput.init(editing:)) ?? GoalInput(name: "", kind: .page, match: "")
        _input = State(initialValue: input)
        _hasAmount = State(initialValue: input.fixedValue != nil)
        _amount = State(initialValue: input.fixedValue.map { $0.formatted(.number.grouping(.never)) } ?? "")
    }

    var body: some View {
        SheetFrame(title: goal == nil ? "Add a Goal" : "Edit Goal", detail: "Counts a visit to a page, or an event your site sends, as a conversion.") {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                RunlightField(label: "Name", placeholder: "Newsletter signup", text: $input.name, error: errors[.name], focused: $nameFocused, onSubmit: save)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Counts").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Picker("Counts", selection: $input.kind) {
                        Text("A page visit").tag(GoalKind.page)
                        Text("An event").tag(GoalKind.event)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                RunlightField(
                    label: input.kind == .page ? "Page" : "Event name",
                    placeholder: input.kind == .page ? "/thanks*" : "Signup",
                    text: $input.match, error: errors[.match], focused: $matchFocused, onSubmit: save
                )
                if input.kind == .page && errors[.match] == nil {
                    Text("A * matches anything, so /blog/* counts every post.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, -6)
                }
                if case .fromEvent(let property) = input.value {
                    Text("Each conversion is worth the event's \u{201C}\(property)\u{201D} property, in \(input.currency).")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                } else {
                    Toggle("Each conversion is worth a fixed amount", isOn: $hasAmount.animation(Theme.Motion.hover))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                    if hasAmount {
                        HStack(alignment: .top, spacing: Theme.Space.s) {
                            RunlightField(label: "Amount", placeholder: "49", text: $amount, error: errors[.value], focused: $amountFocused, onSubmit: save)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Currency").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                TextField("USD", text: $input.currency)
                                    .textFieldStyle(.plain)
                                    .padding(.horizontal, 12)
                                    .frame(width: 80, height: 36)
                                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.06)))
                            }
                        }
                        .transition(.opacity)
                    }
                }
                FormError(message: problem)
                HStack {
                    Spacer()
                    Button("Cancel", action: done)
                        .buttonStyle(QuietButtonStyle(compact: true))
                        .keyboardShortcut(.cancelAction)
                        .disabled(working)
                    Button(action: save) {
                        HStack(spacing: 6) {
                            if working { Spinner() }
                            Text(working ? "Saving…" : goal == nil ? "Add Goal" : "Save")
                        }
                    }
                    .buttonStyle(LampButtonStyle(compact: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(working)
                }
            }
        }
        .frame(width: 440)
        .animation(Theme.Motion.hover, value: errors)
        .onAppear { nameFocused = goal == nil }
    }

    private func save() {
        var sending = input
        if case .fromEvent = input.value {
            // Kept as it is.
        } else if hasAmount {
            guard let value = Double(amount.replacingOccurrences(of: ",", with: ".")), value >= 0 else {
                errors = [.value: "Enter an amount, like 49 or 9.99."]
                return
            }
            sending.value = .fixed(value)
        } else {
            sending.value = .none
        }
        sending.currency = sending.currency.trimmingCharacters(in: .whitespaces).uppercased()
        if sending.currency.isEmpty { sending.currency = "USD" }
        working = true
        errors = [:]
        problem = nil
        Task {
            do throws(SiteManager.Failure) {
                try await manager.saveGoal(sending, editing: goal?.id)
                done()
            } catch {
                if let field = error.field { errors[field] = error.message } else { problem = error.message }
                if error.needsManageToken { done(); needsToken() }
            }
            working = false
        }
    }
}

// MARK: Links

private struct LinksPane: View {
    let manager: SiteManager
    let needsToken: () -> Void

    @State private var editing: LinkEdit?
    @State private var deleting: ShortLink?
    @State private var selected: String?
    @State private var copied: String?
    @State private var problem: String?

    struct LinkEdit: Identifiable {
        let link: ShortLink?
        var id: String { link?.id ?? "new" }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Links", detail: "Short links and their clicks in the last 30 days", add: "Add Link", canAdd: manager.canEdit) {
                editing = LinkEdit(link: nil)
            }
            if let problem {
                FormError(message: problem).padding(.horizontal, Theme.Space.xl).padding(.bottom, Theme.Space.s)
            }
            if !manager.loaded {
                if let error = manager.loadError {
                    PaneState(symbol: "exclamationmark.triangle", title: "Couldn't load the links", detail: error) { Task { await manager.load() } }
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if manager.links.isEmpty {
                PaneState(symbol: "link", title: "No short links yet", detail: "A short link like \(manager.linkPrefix)/launch sends people on to any address, and counts their clicks.")
            } else {
                List(selection: $selected) {
                    ForEach(manager.links) { link in
                        LinkRow(link: link, short: manager.shortURL(link), clicks: manager.linkClicks[link.id], expanded: selected == link.id, copied: copied == link.id) {
                            copy(link)
                        }
                        .tag(link.id)
                        .contextMenu {
                            Button("Copy Short Link") { copy(link) }
                            Button("Edit…") { editing = LinkEdit(link: link) }.disabled(!manager.canEdit)
                            Button("Delete…", role: .destructive) { deleting = link }.disabled(!manager.canEdit)
                        }
                        .onTapGesture(count: 2) { if manager.canEdit { editing = LinkEdit(link: link) } }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
                .scrollContentBackground(.hidden)
                .onChange(of: selected) { _, id in
                    if let id, let link = manager.links.first(where: { $0.id == id }), manager.linkClicks[id] == nil {
                        Task { await manager.loadClicks(link) }
                    }
                }
            }
        }
        .animation(Theme.Motion.push, value: selected)
        .sheet(item: $editing) { edit in
            LinkForm(manager: manager, link: edit.link, needsToken: needsToken) { editing = nil }
        }
        .confirmationDialog(
            "Delete \(deleting.map { manager.shortURL($0) } ?? "")?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { link in
            Button("Delete Link", role: .destructive) {
                Task {
                    do throws(SiteManager.Failure) {
                        try await manager.deleteLink(link)
                        problem = nil
                    } catch {
                        problem = error.message
                        if error.needsManageToken { needsToken() }
                    }
                }
            }
        } message: { link in
            Text("The short link stops working at once, so anyone who follows it gets nothing. It sends people to \(link.url).")
        }
    }

    private func copy(_ link: ShortLink) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(manager.shortURL(link), forType: .string)
        withAnimation(Theme.Motion.hover) { copied = link.id }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(Theme.Motion.hover) { if copied == link.id { copied = nil } }
        }
    }
}

private struct LinkRow: View {
    let link: ShortLink
    let short: String
    let clicks: [LinkClicksPoint]?
    let expanded: Bool
    let copied: Bool
    let copy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "link")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.lamp)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.lamp.opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(short.replacingOccurrences(of: "https://", with: "")).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(link.name.isEmpty ? link.url : "\(link.name) \u{2192} \(link.url)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button(action: copy) {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 11, weight: .medium))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(QuietButtonStyle(compact: true))
                Text((link.clicks ?? 0).formatted(.number))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .frame(minWidth: 44, alignment: .trailing)
                    .help("Clicks in the last 30 days")
            }
            if expanded {
                Group {
                    if let clicks, clicks.count > 1 {
                        Sparkline(values: clicks.map { Double($0.clicks) }, tint: Theme.lamp)
                            .frame(height: 44)
                            .padding(.leading, 38)
                    } else {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Adds a short link, or changes one. The slug and name may be left empty for the server to pick.
private struct LinkForm: View {
    let manager: SiteManager
    let link: ShortLink?
    let needsToken: () -> Void
    let done: () -> Void

    @State private var url: String
    @State private var slug: String
    @State private var name: String
    @State private var domain: String
    @State private var errors: [RunlightError.Field: String] = [:]
    @State private var problem: String?
    @State private var working = false
    @FocusState private var urlFocused: Bool
    @FocusState private var slugFocused: Bool
    @FocusState private var nameFocused: Bool

    init(manager: SiteManager, link: ShortLink?, needsToken: @escaping () -> Void, done: @escaping () -> Void) {
        self.manager = manager
        self.link = link
        self.needsToken = needsToken
        self.done = done
        _url = State(initialValue: link?.url ?? "")
        _slug = State(initialValue: link?.slug ?? "")
        _name = State(initialValue: link?.name ?? "")
        _domain = State(initialValue: link?.domain ?? "")
    }

    var body: some View {
        SheetFrame(title: link == nil ? "Add a Short Link" : "Edit Short Link", detail: "A short address that sends people on to another one, and counts each click.") {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                RunlightField(label: "Destination", placeholder: "https://example.com/launch", text: $url, error: errors[.url], focused: $urlFocused, onSubmit: save)
                if !manager.linkDomains.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Domain").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        Picker("Domain", selection: $domain) {
                            Text(manager.linkPrefix.replacingOccurrences(of: "https://", with: "")).tag("")
                            ForEach(manager.linkDomains, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        if let error = errors[.domain] {
                            Text(error).font(.system(size: 11)).foregroundStyle(Theme.down)
                        }
                    }
                }
                RunlightField(label: "Short link", placeholder: "Leave empty for a random one", text: $slug, error: errors[.slug], focused: $slugFocused, onSubmit: save)
                Text(preview)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.top, -6)
                RunlightField(label: "Name", placeholder: "Optional, for your own list", text: $name, error: errors[.name], focused: $nameFocused, onSubmit: save)
                FormError(message: problem)
                HStack {
                    Spacer()
                    Button("Cancel", action: done)
                        .buttonStyle(QuietButtonStyle(compact: true))
                        .keyboardShortcut(.cancelAction)
                        .disabled(working)
                    Button(action: save) {
                        HStack(spacing: 6) {
                            if working { Spinner() }
                            Text(working ? "Saving…" : link == nil ? "Add Link" : "Save")
                        }
                    }
                    .buttonStyle(LampButtonStyle(compact: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(working)
                }
            }
        }
        .frame(width: 460)
        .animation(Theme.Motion.hover, value: errors)
        .onAppear { urlFocused = link == nil }
    }

    private var preview: String {
        let base = domain.isEmpty ? manager.linkPrefix : "https://\(domain)"
        return "\(base)/\(slug.isEmpty ? "…" : slug)".replacingOccurrences(of: "https://", with: "")
    }

    private func save() {
        var input = LinkInput(url: url.trimmingCharacters(in: .whitespaces), slug: slug.trimmingCharacters(in: .whitespaces), name: name.trimmingCharacters(in: .whitespaces), domain: domain)
        if let link {
            // A change sends only what changed.
            if input.url == link.url { input.url = nil }
            if input.slug == link.slug { input.slug = nil }
            if input.name == link.name { input.name = nil }
            if input.domain == link.domain { input.domain = nil }
        } else if input.name?.isEmpty == true {
            input.name = nil
        }
        working = true
        errors = [:]
        problem = nil
        Task {
            do throws(SiteManager.Failure) {
                try await manager.saveLink(input, editing: link?.id)
                done()
            } catch {
                if let field = error.field { errors[field] = error.message } else { problem = error.message }
                if error.needsManageToken { done(); needsToken() }
            }
            working = false
        }
    }
}

// MARK: Settings

private struct SiteSettingsPane: View {
    let manager: SiteManager
    let needsToken: () -> Void

    @State private var name = ""
    @State private var timezone = ""
    @State private var retention: Int?
    @State private var errors: [RunlightError.Field: String] = [:]
    @State private var problem: String?
    @State private var working = false
    @State private var saved = false
    @FocusState private var nameFocused: Bool

    static let retentionChoices = [6, 12, 24, 36, 60]

    var body: some View {
        let site = manager.site
        VStack(alignment: .leading, spacing: 0) {
            PaneHeaderPlain(title: "Settings", detail: "How \(site?.name ?? "this site") is named, its days are counted, and how long its visits are kept")
            Form {
                Section {
                    TextField(text: $name, prompt: Text("Site name")) {
                        Text("Name")
                        if let error = errors[.name] {
                            Text(error).foregroundStyle(Theme.down)
                        }
                    }
                    .focused($nameFocused)
                    .onSubmit(save)
                    LabeledContent {
                        TimezoneMenu(selection: $timezone)
                    } label: {
                        Text("Timezone")
                        Text(errors[.timezone] ?? "Where a day starts and ends for this site's numbers.")
                            .foregroundStyle(errors[.timezone] == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.down))
                    }
                    Picker(selection: $retention) {
                        Text("Forever").tag(Int?.none)
                        ForEach(Self.retentionChoices, id: \.self) { months in
                            Text(months % 12 == 0 ? "\(months / 12) \(months == 12 ? "year" : "years")" : "\(months) months").tag(Int?.some(months))
                        }
                    } label: {
                        Text("Keep visits for")
                        Text(errors[.retention] ?? "Older visits are deleted for good.")
                            .foregroundStyle(errors[.retention] == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.down))
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(!manager.canEdit)
            HStack {
                FormError(message: problem)
                Spacer()
                if saved {
                    Label("Saved", systemImage: "checkmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.up)
                        .transition(.opacity)
                }
                Button("Revert") { reset() }
                    .buttonStyle(QuietButtonStyle(compact: true))
                    .disabled(!changed || working)
                Button(action: save) {
                    HStack(spacing: 6) {
                        if working { Spinner() }
                        Text(working ? "Saving…" : "Save")
                    }
                }
                .buttonStyle(LampButtonStyle(compact: true))
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!changed || working || !manager.canEdit)
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.bottom, Theme.Space.l)
        }
        .animation(Theme.Motion.hover, value: saved)
        .onAppear(perform: reset)
        .onChange(of: manager.site) { _, _ in if !changed { reset() } }
    }

    private var changed: Bool {
        guard let site = manager.site else { return false }
        return name.trimmingCharacters(in: .whitespaces) != site.name || timezone != site.timezone || retention != site.retentionMonths
    }

    private func reset() {
        guard let site = manager.site else { return }
        name = site.name
        timezone = site.timezone
        retention = site.retentionMonths
        errors = [:]
        problem = nil
    }

    private func save() {
        guard let site = manager.site, changed else { return }
        var patch = SitePatch()
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed != site.name { patch.name = trimmed }
        if timezone != site.timezone { patch.timezone = timezone }
        if retention != site.retentionMonths { patch.retentionMonths = .some(retention) }
        working = true
        errors = [:]
        problem = nil
        Task {
            do throws(SiteManager.Failure) {
                try await manager.saveSettings(patch)
                saved = true
                try? await Task.sleep(for: .seconds(2))
                saved = false
            } catch {
                if let field = error.field { errors[field] = error.message } else { problem = error.message }
                if error.needsManageToken { needsToken() }
            }
            working = false
        }
    }
}

private struct PaneHeaderPlain: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 17, weight: .semibold))
            Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.top, Theme.Space.l)
    }
}

/// Every timezone, grouped by region in submenus, since one list of four hundred is no use.
private struct TimezoneMenu: View {
    @Binding var selection: String

    private static let regions: [(String, [String])] = {
        let grouped = Dictionary(grouping: TimeZone.knownTimeZoneIdentifiers.filter { $0.contains("/") }) { String($0.split(separator: "/")[0]) }
        return grouped.keys.sorted().map { ($0, grouped[$0]!.sorted()) }
    }()

    var body: some View {
        Menu {
            Button("UTC") { selection = "UTC" }
            Divider()
            ForEach(Self.regions, id: \.0) { region, zones in
                Menu(region) {
                    ForEach(zones, id: \.self) { zone in
                        Button(Self.city(zone)) { selection = zone }
                    }
                }
            }
        } label: {
            Text(selection.replacingOccurrences(of: "_", with: " "))
        }
        .fixedSize()
    }

    static func city(_ zone: String) -> String {
        zone.split(separator: "/").dropFirst().joined(separator: ", ").replacingOccurrences(of: "_", with: " ")
    }
}
