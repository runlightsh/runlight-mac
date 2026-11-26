import SwiftUI

// MARK: Funnels

/// Funnels: the steps a visit is followed through, and how many made it to each in the last 30 days.
struct FunnelsPane: View {
    let manager: SiteManager
    let needsToken: () -> Void

    @State private var editing: Editing?
    @State private var deleting: Funnel?
    @State private var problem: String?

    struct Editing: Identifiable {
        let funnel: Funnel?
        var id: String { funnel?.id ?? "new" }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Funnels", detail: "How many visits make it through each step, in the last 30 days", add: "Add Funnel", canAdd: manager.canEdit) {
                editing = Editing(funnel: nil)
            }
            if let problem { FormError(message: problem).padding(.horizontal, Theme.Space.xl).padding(.bottom, Theme.Space.s) }
            if manager.funnels.isEmpty {
                PaneState(symbol: "line.3.horizontal.decrease", title: "No funnels yet", detail: "A funnel follows visits through pages or events in order, like /pricing, then /signup, then a Signup event, and shows where people drop off.")
            } else {
                List {
                    ForEach(manager.funnels) { funnel in
                        FunnelRow(funnel: funnel)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { if manager.canEdit { editing = Editing(funnel: funnel) } }
                            .contextMenu {
                                Button("Edit…") { editing = Editing(funnel: funnel) }.disabled(!manager.canEdit)
                                Button("Delete…", role: .destructive) { deleting = funnel }.disabled(!manager.canEdit)
                            }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
                .scrollContentBackground(.hidden)
            }
        }
        .sheet(item: $editing) { item in
            FunnelForm(manager: manager, funnel: item.funnel, needsToken: needsToken) { editing = nil }
        }
        .confirmationDialog("Delete the funnel \u{201C}\(deleting?.name ?? "")\u{201D}?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { funnel in
            Button("Delete Funnel", role: .destructive) {
                Task {
                    do throws(SiteManager.Failure) { try await manager.deleteFunnel(funnel); problem = nil } catch { problem = error.message; if error.needsManageToken { needsToken() } }
                }
            }
        } message: { _ in
            Text("It leaves the funnel reports, here and in the dashboard. Your visits are kept.")
        }
    }
}

private struct FunnelRow: View {
    let funnel: Funnel

    var body: some View {
        let first = Double(funnel.steps.first?.visits ?? 0)
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Text(funnel.name).font(.system(size: 13, weight: .medium))
                Spacer()
                if first > 0, let last = funnel.steps.last?.visits {
                    Text(NumberText.share(Double(last) / first) + " convert")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.up)
                }
            }
            // Each step as a bar, as long as its share of the first.
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(funnel.steps.enumerated()), id: \.offset) { index, step in
                    HStack(spacing: Theme.Space.s) {
                        Text("\(index + 1)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        Text(step.kind == "event" ? "Event \(step.match)" : step.match)
                            .font(.system(size: 11, design: step.kind == "event" ? .default : .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: 180, alignment: .leading)
                        GeometryReader { geometry in
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Theme.series.opacity(0.75))
                                .frame(width: max(3, geometry.size.width * (first > 0 ? CGFloat(Double(step.visits ?? 0) / first) : 0)))
                        }
                        .frame(height: 8)
                        Text((step.visits ?? 0).formatted(.number))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .frame(minWidth: 40, alignment: .trailing)
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }
}

/// Adds or changes a funnel: a name and two or more steps, each a page or an event.
private struct FunnelForm: View {
    let manager: SiteManager
    let funnel: Funnel?
    let needsToken: () -> Void
    let done: () -> Void

    @State private var name: String
    @State private var steps: [FunnelStep]
    @State private var errors: [RunlightError.Field: String] = [:]
    @State private var problem: String?
    @State private var working = false
    @FocusState private var nameFocused: Bool

    init(manager: SiteManager, funnel: Funnel?, needsToken: @escaping () -> Void, done: @escaping () -> Void) {
        self.manager = manager
        self.funnel = funnel
        self.needsToken = needsToken
        self.done = done
        _name = State(initialValue: funnel?.name ?? "")
        _steps = State(initialValue: funnel?.steps.map { FunnelStep(kind: $0.kind, match: $0.match) } ?? [FunnelStep(kind: "page", match: ""), FunnelStep(kind: "page", match: "")])
    }

    var body: some View {
        SheetFrame(title: funnel == nil ? "Add a Funnel" : "Edit Funnel", detail: "Visits are followed through these steps in order. A page can end in * to match many, like /blog/*.") {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                RunlightField(label: "Name", placeholder: "Signup", text: $name, error: errors[.name], focused: $nameFocused, onSubmit: save)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Steps").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(steps.indices, id: \.self) { index in
                        HStack(spacing: 6) {
                            Text("\(index + 1)").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.secondary).frame(width: 14)
                            Picker("Kind", selection: $steps[index].kind) {
                                Text("Page").tag("page")
                                Text("Event").tag("event")
                            }
                            .labelsHidden()
                            .frame(width: 84)
                            TextField(steps[index].kind == "page" ? "/pricing" : "Signup", text: $steps[index].match)
                                .textFieldStyle(.roundedBorder)
                            Button {
                                steps.remove(at: index)
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .disabled(steps.count <= 2)
                            .help("Remove this step")
                        }
                    }
                    Button {
                        steps.append(FunnelStep(kind: "page", match: ""))
                    } label: {
                        Label("Add Step", systemImage: "plus")
                    }
                    .buttonStyle(LinkButtonStyle())
                    .disabled(steps.count >= 8)
                    if let error = errors[.match] {
                        Text(error).font(.system(size: 11)).foregroundStyle(Theme.down)
                    }
                }
                FormError(message: problem)
                FormButtons(saving: working, title: funnel == nil ? "Add Funnel" : "Save", cancel: done, save: save)
            }
        }
        .frame(width: 520)
        .onAppear { nameFocused = funnel == nil }
    }

    private func save() {
        let input = FunnelInput(name: name.trimmingCharacters(in: .whitespaces), steps: steps.map { FunnelStep(kind: $0.kind, match: $0.match.trimmingCharacters(in: .whitespaces)) })
        working = true
        errors = [:]
        problem = nil
        Task {
            do throws(SiteManager.Failure) {
                try await manager.saveFunnel(input, editing: funnel?.id)
                done()
            } catch {
                if let field = error.field { errors[field] = error.message } else { problem = error.message }
                if error.needsManageToken { done(); needsToken() }
            }
            working = false
        }
    }
}

// MARK: Custom domains

/// Domains short links can use besides the install's own, and whether each points here yet.
struct DomainsPane: View {
    let manager: SiteManager
    let needsToken: () -> Void

    @State private var adding = false
    @State private var removing: String?
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Custom Domains", detail: "Domains your short links can use, like go.example.com", add: "Add Domain", canAdd: manager.canEdit) {
                adding = true
            }
            if let problem { FormError(message: problem).padding(.horizontal, Theme.Space.xl).padding(.bottom, Theme.Space.s) }
            if manager.linkDomains.isEmpty {
                PaneState(symbol: "globe", title: "No custom domains", detail: "Short links live at \(manager.linkPrefix.replacingOccurrences(of: "https://", with: "")) until you add a domain of your own and point it here.")
            } else {
                List {
                    ForEach(manager.linkDomains, id: \.self) { domain in
                        DomainRow(domain: domain, check: manager.domainChecks[domain]) {
                            Task { await manager.checkDomain(domain) }
                        }
                        .task { if manager.canEdit && manager.domainChecks[domain] == nil { await manager.checkDomain(domain) } }
                        .contextMenu {
                            Button("Check Again") { Task { await manager.checkDomain(domain) } }
                            Button("Remove…", role: .destructive) { removing = domain }.disabled(!manager.canEdit)
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
                .scrollContentBackground(.hidden)
            }
        }
        .sheet(isPresented: $adding) {
            DomainForm(manager: manager, needsToken: needsToken) { adding = false }
        }
        .confirmationDialog("Remove \(removing ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { domain in
            Button("Remove Domain", role: .destructive) {
                Task {
                    do throws(SiteManager.Failure) { try await manager.removeDomain(domain); problem = nil } catch { problem = error.message; if error.needsManageToken { needsToken() } }
                }
            }
        } message: { _ in
            Text("Short links on this domain stop working until it's added again.")
        }
    }
}

private struct DomainRow: View {
    let domain: String
    let check: LinkDomainCheck?
    let recheck: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "globe")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.series)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.series.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(domain).font(.system(size: 13, weight: .medium))
                if let check {
                    if check.working {
                        Text("Points here").font(.system(size: 11)).foregroundStyle(Theme.up)
                    } else {
                        Text(check.reason + (check.target.map { " Point it at \($0.host)." } ?? ""))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.down)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Checking…").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Circle()
                .fill(check == nil ? Color.secondary.opacity(0.4) : check!.working ? Theme.lamp : Theme.down)
                .frame(width: 7, height: 7)
            Button("Check", action: recheck)
                .buttonStyle(QuietButtonStyle(compact: true))
        }
        .padding(.vertical, 4)
    }
}

private struct DomainForm: View {
    let manager: SiteManager
    let needsToken: () -> Void
    let done: () -> Void

    @State private var domain = ""
    @State private var error: String?
    @State private var working = false
    @FocusState private var focused: Bool

    var body: some View {
        SheetFrame(title: "Add a Custom Domain", detail: "Point the domain at this Runlight first (a CNAME record, or the same address it uses), then add it here.") {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                RunlightField(label: "Domain", placeholder: "go.example.com", text: $domain, error: error, focused: $focused, onSubmit: save)
                FormButtons(saving: working, title: "Add Domain", cancel: done, save: save)
            }
        }
        .frame(width: 440)
        .onAppear { focused = true }
    }

    private func save() {
        working = true
        error = nil
        Task {
            do throws(SiteManager.Failure) {
                try await manager.addDomain(domain.trimmingCharacters(in: .whitespaces))
                done()
            } catch {
                self.error = error.message
                if error.needsManageToken { done(); needsToken() }
            }
            working = false
        }
    }
}

// MARK: Email reports

/// Who gets the site's numbers by email, weekly or monthly.
struct ReportsPane: View {
    let manager: SiteManager
    let needsToken: () -> Void

    @State private var adding = false
    @State private var deleting: EmailReport?
    @State private var problem: String?
    @State private var sent: String?

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Email Reports", detail: "This site's numbers by email, each week or month", add: "Add Recipient", canAdd: manager.canEdit) {
                adding = true
            }
            if let problem { FormError(message: problem).padding(.horizontal, Theme.Space.xl).padding(.bottom, Theme.Space.s) }
            if !manager.canEdit {
                PaneState(symbol: "lock", title: "Allow editing to see email reports", detail: "Who gets this site's reports is a setting, which only a manage token can read.")
            } else if manager.reports.isEmpty {
                PaneState(symbol: "envelope", title: "No email reports", detail: "Send the week's or the month's numbers to anyone, such as a client. Reports need an email service, set up in the dashboard's settings.")
            } else {
                List {
                    ForEach(manager.reports) { report in
                        HStack(spacing: Theme.Space.m) {
                            Image(systemName: "envelope")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.series)
                                .frame(width: 26, height: 26)
                                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.series.opacity(0.12)))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(report.email).font(.system(size: 13, weight: .medium))
                                Text("\(report.frequency.capitalized), in \(Locale.current.localizedString(forLanguageCode: report.lang) ?? report.lang)" + (report.lastSentAt.map { ". Last sent \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ". Not sent yet"))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if sent == report.id {
                                Label("Sent", systemImage: "checkmark").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.up).transition(.opacity)
                            }
                            Button("Send Now") { send(report) }
                                .buttonStyle(QuietButtonStyle(compact: true))
                                .disabled(!manager.canEdit)
                        }
                        .padding(.vertical, 4)
                        .contextMenu {
                            Button("Send Now") { send(report) }.disabled(!manager.canEdit)
                            Button("Delete…", role: .destructive) { deleting = report }.disabled(!manager.canEdit)
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
                .scrollContentBackground(.hidden)
            }
        }
        .animation(Theme.Motion.hover, value: sent)
        .sheet(isPresented: $adding) {
            ReportForm(manager: manager, needsToken: needsToken) { adding = false }
        }
        .confirmationDialog("Stop sending reports to \(deleting?.email ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { report in
            Button("Stop Sending", role: .destructive) {
                Task {
                    do throws(SiteManager.Failure) { try await manager.deleteReport(report); problem = nil } catch { problem = error.message; if error.needsManageToken { needsToken() } }
                }
            }
        } message: { report in
            Text("The \(report.frequency) report stops at once. Past emails stay where they are.")
        }
    }

    private func send(_ report: EmailReport) {
        Task {
            do throws(SiteManager.Failure) {
                try await manager.sendReport(report)
                problem = nil
                sent = report.id
                try? await Task.sleep(for: .seconds(2))
                if sent == report.id { sent = nil }
            } catch {
                problem = error.message
                if error.needsManageToken { needsToken() }
            }
        }
    }
}

private struct ReportForm: View {
    let manager: SiteManager
    let needsToken: () -> Void
    let done: () -> Void

    @State private var email = ""
    @State private var frequency = "weekly"
    @State private var lang = "en"
    @State private var error: String?
    @State private var working = false
    @FocusState private var focused: Bool

    var body: some View {
        SheetFrame(title: "Add a Report", detail: "The first one goes out at the start of the next week or month, in the site's timezone.") {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                RunlightField(label: "Email", placeholder: "client@example.com", text: $email, error: error, focused: $focused, onSubmit: save)
                HStack(spacing: Theme.Space.m) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("How often").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        Picker("How often", selection: $frequency) {
                            Text("Weekly").tag("weekly")
                            Text("Monthly").tag("monthly")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Language").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        Picker("Language", selection: $lang) {
                            ForEach(manager.reportLanguages, id: \.self) { code in
                                Text(Locale.current.localizedString(forLanguageCode: code) ?? code).tag(code)
                            }
                        }
                        .labelsHidden()
                    }
                }
                FormButtons(saving: working, title: "Add Report", cancel: done, save: save)
            }
        }
        .frame(width: 440)
        .onAppear {
            focused = true
            let mine = Locale.current.language.languageCode?.identifier ?? "en"
            lang = manager.reportLanguages.contains(mine) ? mine : manager.reportLanguages.first ?? "en"
        }
    }

    private func save() {
        working = true
        error = nil
        Task {
            do throws(SiteManager.Failure) {
                try await manager.addReport(ReportInput(email: email.trimmingCharacters(in: .whitespaces), frequency: frequency, lang: lang))
                done()
            } catch {
                self.error = error.message
                if error.needsManageToken { done(); needsToken() }
            }
            working = false
        }
    }
}

// MARK: Sharing

/// Public, read-only links to the site's dashboard, for a client or a team without accounts.
struct SharingPane: View {
    let manager: SiteManager
    let needsToken: () -> Void

    @State private var editing: Editing?
    @State private var deleting: ShareLink?
    @State private var copied: String?
    @State private var problem: String?

    struct Editing: Identifiable {
        let share: ShareLink?
        var id: String { share?.id ?? "new" }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Sharing", detail: "Read-only links to this site's dashboard, no sign-in needed", add: "Add Share Link", canAdd: manager.canEdit) {
                editing = Editing(share: nil)
            }
            if let problem { FormError(message: problem).padding(.horizontal, Theme.Space.xl).padding(.bottom, Theme.Space.s) }
            if !manager.canEdit {
                PaneState(symbol: "lock", title: "Allow editing to see share links", detail: "Share links are a setting, which only a manage token can read.")
            } else if manager.shares.isEmpty {
                PaneState(symbol: "person.2", title: "No share links", detail: "Anyone with a share link sees this site's numbers, and can't change anything. Delete the link to take it back.")
            } else {
                List {
                    ForEach(manager.shares) { share in
                        HStack(spacing: Theme.Space.m) {
                            Image(systemName: "person.2")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.lamp)
                                .frame(width: 26, height: 26)
                                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.lamp.opacity(0.12)))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(share.name.isEmpty ? "Share link" : share.name).font(.system(size: 13, weight: .medium))
                                Text(manager.shareURL(share)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Button {
                                copy(share)
                            } label: {
                                Label(copied == share.id ? "Copied" : "Copy", systemImage: copied == share.id ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 11, weight: .medium))
                                    .contentTransition(.symbolEffect(.replace))
                            }
                            .buttonStyle(QuietButtonStyle(compact: true))
                        }
                        .padding(.vertical, 4)
                        .contextMenu {
                            Button("Copy Link") { copy(share) }
                            Button("Open") { if let url = URL(string: manager.shareURL(share)) { NSWorkspace.shared.open(url) } }
                            Button("Rename…") { editing = Editing(share: share) }.disabled(!manager.canEdit)
                            Button("Delete…", role: .destructive) { deleting = share }.disabled(!manager.canEdit)
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
                .scrollContentBackground(.hidden)
            }
        }
        .sheet(item: $editing) { item in
            ShareForm(manager: manager, share: item.share, needsToken: needsToken) { editing = nil }
        }
        .confirmationDialog("Delete the share link \u{201C}\(deleting?.name ?? "")\u{201D}?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { share in
            Button("Delete Link", role: .destructive) {
                Task {
                    do throws(SiteManager.Failure) { try await manager.deleteShare(share); problem = nil } catch { problem = error.message; if error.needsManageToken { needsToken() } }
                }
            }
        } message: { _ in
            Text("Anyone who has it sees nothing from then on.")
        }
    }

    private func copy(_ share: ShareLink) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(manager.shareURL(share), forType: .string)
        withAnimation(Theme.Motion.hover) { copied = share.id }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(Theme.Motion.hover) { if copied == share.id { copied = nil } }
        }
    }
}

private struct ShareForm: View {
    let manager: SiteManager
    let share: ShareLink?
    let needsToken: () -> Void
    let done: () -> Void

    @State private var name: String
    @State private var error: String?
    @State private var working = false
    @FocusState private var focused: Bool

    init(manager: SiteManager, share: ShareLink?, needsToken: @escaping () -> Void, done: @escaping () -> Void) {
        self.manager = manager
        self.share = share
        self.needsToken = needsToken
        self.done = done
        _name = State(initialValue: share?.name ?? "")
    }

    var body: some View {
        SheetFrame(title: share == nil ? "Add a Share Link" : "Rename Share Link", detail: "The name is for you, so you know who has which link.") {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                RunlightField(label: "Name", placeholder: "For Acme", text: $name, error: error, focused: $focused, onSubmit: save)
                FormButtons(saving: working, title: share == nil ? "Add Link" : "Save", cancel: done, save: save)
            }
        }
        .frame(width: 420)
        .onAppear { focused = true }
    }

    private func save() {
        working = true
        error = nil
        Task {
            do throws(SiteManager.Failure) {
                let made = try await manager.saveShare(name: name.trimmingCharacters(in: .whitespaces), editing: share?.id)
                if share == nil {
                    // A new link goes straight to the clipboard, ready to send.
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(manager.shareURL(made), forType: .string)
                }
                done()
            } catch {
                self.error = error.message
                if error.needsManageToken { done(); needsToken() }
            }
            working = false
        }
    }
}

// MARK: Shared

/// Cancel and the form's main button, as every Manage sheet ends.
struct FormButtons: View {
    let saving: Bool
    let title: String
    let cancel: () -> Void
    let save: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button("Cancel", action: cancel)
                .buttonStyle(QuietButtonStyle(compact: true))
                .keyboardShortcut(.cancelAction)
                .disabled(saving)
            Button(action: save) {
                HStack(spacing: 6) {
                    if saving { Spinner() }
                    Text(saving ? "Saving…" : title)
                }
            }
            .buttonStyle(LampButtonStyle(compact: true))
            .keyboardShortcut(.defaultAction)
            .disabled(saving)
        }
    }
}
