import SwiftUI

/// What the popover can ask the app to do.
struct PopoverActions {
    var openSettings: (SettingsTab) -> Void = { _ in }
    /// A site or a page of a dashboard: the dashboard window or the browser, as Settings says.
    var openDashboard: (URL?) -> Void = { _ in }
    /// A site's Manage window: its goals, links, and settings.
    var manageSite: @MainActor @Sendable (SiteKey) -> Void = { _ in }
    var addConnection: () -> Void = {}
    var quit: () -> Void = {}
}

/// Everything that lives under the menu bar item: a welcome until there is a connection, then the sites.
struct PopoverView: View {
    let actions: PopoverActions

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            content
                .transition(.opacity)
            Hairline()
            footer
        }
        .animation(Theme.Motion.push, value: model.isEmpty)
        .panelChrome()
        // Links to a dashboard ("Open in Runlight", the arrow beside a site) go through the app.
        .environment(\.manageSite, actions.manageSite)
        .environment(\.openURL, OpenURLAction { url in
            actions.openDashboard(url)
            return .handled
        })
    }

    @ViewBuilder private var content: some View {
        if model.isEmpty {
            WelcomeView(addConnection: actions.addConnection)
        } else {
            VStack(spacing: 0) {
                ForEach(model.connections.filter { !$0.status.isOK && $0.status != .checking }) { state in
                    ConnectionBanner(state: state) { actions.openSettings(.connections) }
                }
                SiteListView()
            }
        }
    }

    private var header: some View {
        @Bindable var model = model
        return HStack(spacing: Theme.Space.s) {
            RunlightMark(size: 16)
            Text("Runlight")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if !model.isEmpty {
                PeriodPicker(selection: $model.period)
                    .transition(.opacity)
            }
        }
        .padding(.leading, Theme.Space.l)
        .padding(.trailing, Theme.Space.m)
        .frame(height: 40)
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.xxs) {
            UpdatedLabel()
            Spacer()
            if !model.isEmpty {
                Button { model.refreshNow() } label: {
                    RefreshIcon(spinning: model.isRefreshing)
                }
                .help("Refresh")
                .accessibilityLabel(model.isRefreshing ? "Refreshing" : "Refresh")
                .keyboardShortcut("r", modifiers: .command)
            }
            if !model.isEmpty {
                Button { actions.openDashboard(nil) } label: {
                    Image(systemName: "macwindow")
                }
                .help("Open Dashboard")
                .accessibilityLabel("Open Dashboard")
                .keyboardShortcut("d", modifiers: .command)
            }
            AppearanceButton()
            Button { actions.openSettings(.general) } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings")
            .accessibilityLabel("Settings")
            .keyboardShortcut(",", modifiers: .command)
            Button(action: actions.quit) {
                Image(systemName: "power")
            }
            .help("Quit Runlight")
            .accessibilityLabel("Quit Runlight")
            .keyboardShortcut("q", modifiers: .command)
        }
        .buttonStyle(ToolbarButtonStyle())
        .padding(.leading, Theme.Space.l)
        .padding(.trailing, Theme.Space.s)
        .frame(height: 38)
    }
}

/// Cycles Auto, Light, and Dark without opening Settings; the symbol shows the one in use.
private struct AppearanceButton: View {
    @AppStorage(AppAppearance.defaultsKey) private var appearance = AppAppearance.system

    var body: some View {
        Button {
            appearance = appearance.next
            AppAppearance.apply(appearance)
        } label: {
            Image(systemName: appearance.symbol)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 16)
        }
        .help("Appearance: \(appearance.title)")
        .accessibilityLabel("Appearance")
        .accessibilityValue(appearance.title)
    }
}

/// The refresh arrow. While fetching it turns at a steady pace, and when the fetching ends it
/// finishes the turn it is on, so it comes to rest upright rather than snapping back. The angle comes
/// from the clock, not from chained animations, so a hidden popover never spins it in a loop.
private struct RefreshIcon: View {
    let spinning: Bool

    @State private var start: Date?
    @State private var stopAt: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let turn: TimeInterval = 0.8

    var body: some View {
        TimelineView(.animation(paused: start == nil)) { context in
            Image(systemName: "arrow.clockwise")
                .rotationEffect(.degrees(angle(at: context.date)))
        }
        .opacity(reduceMotion && spinning ? 0.5 : 1)
        .onChange(of: spinning, initial: true) { _, now in
            if now {
                guard !reduceMotion else { return }
                if start == nil { start = .now }
                stopAt = nil
            } else if let start {
                let turns = max(1, (Date.now.timeIntervalSince(start) / Self.turn).rounded(.up))
                let end = start.addingTimeInterval(turns * Self.turn)
                stopAt = end
                Task {
                    try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow)))
                    if stopAt == end {
                        self.start = nil
                        stopAt = nil
                    }
                }
            }
        }
    }

    private func angle(at date: Date) -> Double {
        guard let start else { return 0 }
        if let stopAt, date >= stopAt { return 0 }
        return date.timeIntervalSince(start) / Self.turn * 360
    }
}

/// "Updated just now", "Updated 4 min ago", or "Offline, updated 2:14 PM", kept current while open.
private struct UpdatedLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            Text(text(at: context.date))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .contentTransition(.opacity)
                .animation(Theme.Motion.hover, value: text(at: context.date))
        }
    }

    private func text(at now: Date) -> String {
        if model.isEmpty { return "Not connected" }
        guard let updated = model.updatedAt else { return model.isRefreshing ? "Loading…" : "Waiting for numbers" }
        let age = now.timeIntervalSince(updated)
        let when: String
        if age < 60 {
            when = "just now"
        } else if age < 3600 {
            when = "\(Int(age / 60)) min ago"
        } else {
            when = updated.formatted(date: Calendar.current.isDateInToday(updated) ? .omitted : .abbreviated, time: .shortened)
        }
        return model.offline ? "Offline, updated \(when)" : "Updated \(when)"
    }
}

/// First launch: the lamp glows softly, waiting, above one button that opens Settings to connect.
private struct WelcomeView: View {
    let addConnection: () -> Void

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            RunlightMark(size: 44, glowing: true)
                .padding(.bottom, Theme.Space.xs)
            VStack(spacing: Theme.Space.xs) {
                Text("Connect your Runlight")
                    .font(.system(size: 15, weight: .semibold))
                Text("Add an install's address and a read-only token to see today's numbers for every site, right here.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Add Runlight Connection…", action: addConnection)
                .buttonStyle(LampButtonStyle())
                .padding(.top, Theme.Space.xs)
        }
        .padding(.horizontal, Theme.Space.xxl)
        .padding(.vertical, Theme.Space.xxl)
        .frame(maxWidth: .infinity)
    }
}

/// A problem with one connection, above the site list, with the way to fix it.
private struct ConnectionBanner: View {
    let state: ConnectionState
    let fix: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(state.connection.name)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if state.status.needsToken {
                Button("Replace Token…", action: fix)
                    .buttonStyle(LampButtonStyle(compact: true))
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s + 2)
        .background(tint.opacity(0.08))
        .overlay(alignment: .bottom) { Hairline() }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch state.status {
        case .tokenRejected: "Token rejected"
        case .tokenMissing: "Token missing"
        case .offline: "Offline"
        case .problem(let message): message
        case .ok, .checking: ""
        }
    }

    private var icon: String {
        state.status == .offline ? "wifi.slash" : "exclamationmark.triangle.fill"
    }

    private var tint: Color {
        state.status == .offline ? .secondary : Theme.down
    }
}

#Preview("Popover") {
    PopoverView(actions: PopoverActions())
        .environment(AppModel(store: ConnectionStore(directory: URL(filePath: NSTemporaryDirectory())), vault: MemoryVault()))
        .frame(width: Theme.popoverWidth)
        .padding(40)
}

private struct ManageSiteKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable (SiteKey) -> Void = { _ in }
}

extension EnvironmentValues {
    /// Opens a site's Manage window, from the popover or Settings.
    var manageSite: @MainActor @Sendable (SiteKey) -> Void {
        get { self[ManageSiteKey.self] }
        set { self[ManageSiteKey.self] = newValue }
    }
}
