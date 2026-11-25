import SwiftUI

/// What the popover can ask the app to do.
struct PopoverActions {
    var openSettings: (SettingsTab) -> Void = { _ in }
    var quit: () -> Void = {}
}

/// Everything that lives under the menu bar item: the connect form until there is a connection,
/// a brief "Connected" moment, then the sites.
struct PopoverView: View {
    let actions: PopoverActions

    @Environment(AppModel.self) private var model
    @State private var justConnected: ConnectionState?

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
        .animation(Theme.Motion.push, value: justConnected?.id)
        .panelChrome()
    }

    @ViewBuilder private var content: some View {
        if let justConnected {
            ConnectedMoment(state: justConnected)
                .task {
                    try? await Task.sleep(for: .seconds(1.3))
                    self.justConnected = nil
                }
        } else if model.isEmpty {
            OnboardingView { state in justConnected = state }
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
        HStack(spacing: Theme.Space.s) {
            RunlightMark(size: 16)
            Text("Runlight")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, Theme.Space.l)
        .frame(height: 40)
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.xxs) {
            Text(footerText)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .contentTransition(.opacity)
            Spacer()
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

    private var footerText: String {
        if model.isEmpty { return "Not connected" }
        let names = model.connections.map(\.connection.name).joined(separator: ", ")
        let count = model.allSites.count
        return "\(count) \(count == 1 ? "site" : "sites") on \(names)"
    }
}

/// First launch: the lamp glows softly beside a short welcome and the connect form.
private struct OnboardingView: View {
    let onConnected: (ConnectionState) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.m) {
                RunlightMark(size: 34, glowing: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect your Runlight")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Today's numbers for every site, one click away.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            ConnectForm(style: .popover, onConnected: onConnected)
        }
        .padding(Theme.Space.l)
        .padding(.vertical, Theme.Space.xs)
    }
}

/// A beat of confirmation: the lamp brightens, a check draws in, and the count of sites found.
private struct ConnectedMoment: View {
    let state: ConnectionState
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            ZStack {
                Circle()
                    .fill(Theme.lamp.opacity(0.14))
                    .frame(width: 56, height: 56)
                    .scaleEffect(drawn ? 1 : 0.6)
                Circle()
                    .fill(Theme.lamp.opacity(0.08))
                    .frame(width: 80, height: 80)
                    .scaleEffect(drawn ? 1 : 0.4)
                    .opacity(drawn ? 1 : 0)
                Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.lamp)
                    .scaleEffect(drawn ? 1 : 0.3)
                    .opacity(drawn ? 1 : 0)
            }
            .frame(height: 80)
            VStack(spacing: 3) {
                Text("Connected")
                    .font(.system(size: 15, weight: .semibold))
                Text("\(state.sites.count) \(state.sites.count == 1 ? "site" : "sites") on \(state.connection.name)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .opacity(drawn ? 1 : 0)
            .offset(y: drawn ? 0 : 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.xxl)
        .onAppear {
            withAnimation(reduceMotion ? .none : .spring(response: 0.45, dampingFraction: 0.62)) { drawn = true }
        }
        .accessibilityElement(children: .combine)
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
            if state.status == .tokenRejected {
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
