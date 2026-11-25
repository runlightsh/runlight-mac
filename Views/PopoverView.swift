import SwiftUI

/// What the popover can ask the app to do.
struct PopoverActions {
    var openSettings: (SettingsTab) -> Void = { _ in }
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
