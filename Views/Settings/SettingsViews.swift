import SwiftUI

/// Every pane is the same size, so switching tabs never resizes the window. Longer panes scroll.
enum SettingsLayout {
    static let paneSize = CGSize(width: 520, height: 440)
}

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
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
                @Bindable var model = model
                Toggle(isOn: $model.showsMenuBarTotal) {
                    Text("Show total site visits in the menu bar")
                    Text("Beside the icon, for the period chosen in the popover.")
                }
            }
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



extension Bundle {
    /// "0.1.0 (1)"
    var versionDescription: String {
        let version = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(version) (\(build))"
    }
}
