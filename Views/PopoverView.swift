import SwiftUI

/// What the popover can ask the app to do.
struct PopoverActions {
    var openSettings: (SettingsTab) -> Void = { _ in }
    var quit: () -> Void = {}
}

/// Everything that lives under the menu bar item.
struct PopoverView: View {
    let actions: PopoverActions

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            EmptyConnectionsView(addConnection: { actions.openSettings(.connections) })
            Hairline()
            footer
        }
        .panelChrome()
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
            Text("Not connected")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
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
}

/// First launch: nothing connected yet. The lamp glows softly, waiting.
struct EmptyConnectionsView: View {
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
            Button("Add Connection…", action: addConnection)
                .buttonStyle(LampButtonStyle())
                .padding(.top, Theme.Space.xs)
        }
        .padding(.horizontal, Theme.Space.xxl)
        .padding(.vertical, Theme.Space.xxl)
        .frame(maxWidth: .infinity)
    }
}

#Preview("Popover") {
    PopoverView(actions: PopoverActions())
        .frame(width: Theme.popoverWidth)
        .padding(40)
}
