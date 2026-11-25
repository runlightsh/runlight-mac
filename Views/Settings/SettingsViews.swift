import SwiftUI

/// Every pane is the same size, so switching tabs never resizes the window. Longer panes scroll.
enum SettingsLayout {
    static let paneSize = CGSize(width: 520, height: 440)
}

struct GeneralSettingsView: View {
    @State private var launchAtLogin = LaunchAtLogin()
    @AppStorage(AppAppearance.defaultsKey) private var appearance = AppAppearance.system

    var body: some View {
        Form {
            Section {
                LabeledContent("Appearance") {
                    AppearancePicker(selection: $appearance)
                        .padding(.vertical, Theme.Space.xs)
                }
            }
            .onChange(of: appearance) { _, new in AppAppearance.apply(new) }
            Section {
                Toggle(isOn: Binding(get: { launchAtLogin.isOn }, set: { launchAtLogin.set($0) })) {
                    Text("Open Runlight at login")
                    Text("Runlight starts quietly in the menu bar when you log in.")
                }
                if launchAtLogin.state == .needsApproval {
                    HStack {
                        Label("Allow Runlight in Login Items to finish turning this on.", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items…") { launchAtLogin.openLoginItems() }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if let error = launchAtLogin.lastError {
                    Label(error, systemImage: "xmark.octagon")
                        .foregroundStyle(Theme.down)
                }
            }
            Section {
                LabeledContent("Version", value: Bundle.main.versionDescription)
            }
        }
        .formStyle(.grouped)
        .animation(Theme.Motion.push, value: launchAtLogin.state)
        .frame(width: SettingsLayout.paneSize.width, height: SettingsLayout.paneSize.height, alignment: .top)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refresh()
        }
    }
}

struct ConnectionsSettingsView: View {
    var body: some View {
        PlaceholderPane(symbol: "point.3.connected.trianglepath.dotted", title: "No connections yet", detail: "Connect a Runlight install with its address and a read-only token.")
    }
}

struct SitesSettingsView: View {
    var body: some View {
        PlaceholderPane(symbol: "square.stack.3d.up", title: "No sites yet", detail: "Your sites appear here once a connection is added, ready to hide, reorder, or pin to the menu bar.")
    }
}

struct AlertsSettingsView: View {
    var body: some View {
        PlaceholderPane(symbol: "bell.badge", title: "Spike alerts", detail: "Get a notification when a site's traffic jumps, naming the source that sent it.")
    }
}

/// A calm empty pane: a large glyph and a line of explanation.
private struct PlaceholderPane: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, Theme.Space.xs)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(.bottom, Theme.Space.xxl)
        .frame(width: SettingsLayout.paneSize.width, height: SettingsLayout.paneSize.height)
    }
}

extension Bundle {
    /// "0.1.0 (1)"
    var versionDescription: String {
        let version = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(version) (\(build))"
    }
}
