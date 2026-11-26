import SwiftUI

/// Settings, Alerts: spike alerts on or off, how big a jump counts, conversion alerts, quiet hours,
/// and which sites alert.
struct AlertsSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var asking = false

    var body: some View {
        @Bindable var model = model
        let enabled = model.alertSettings.enabled
        Form {
            Section {
                Toggle(isOn: Binding(get: { enabled }, set: { on in
                    asking = true
                    Task {
                        await model.setAlertsEnabled(on)
                        asking = false
                    }
                })) {
                    Text("Spike alerts")
                    Text("A notification when a site gets far more visitors than usual for the time of day, naming the source that sent them.")
                }
                .disabled(asking)
                if model.notificationsRefused && !enabled {
                    HStack {
                        Label("Notifications are off for Runlight.", systemImage: "bell.slash")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Notification Settings…") { openURL(SystemNotifier.settingsURL) }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            Section {
                Picker(selection: $model.alertSettings.multiplier) {
                    ForEach(AlertSettings.levels, id: \.self) { level in
                        Text(Self.levelTitle(level)).tag(level)
                    }
                } label: {
                    Text("Alert when a site gets")
                    Text("And at least \(Int(SpikeDetector.minExtraVisitors)) more visitors than usual, so quiet sites stay quiet.")
                }
                Toggle(isOn: $model.alertSettings.conversions) {
                    Text("Conversion spikes")
                    Text("When goal conversions jump on the same terms, by at least \(Int(SpikeDetector.minExtraConversions)).")
                }
            } footer: {
                Text("\"Usual\" is the average for that hour of the day over the last 30 days. Each site alerts at most once every 2 hours.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(!enabled)

            Section {
                Toggle(isOn: $model.alertSettings.quietHours) {
                    Text("Quiet hours")
                    Text("No alerts between these times. Spikes during them are skipped, not saved for later.")
                }
                if model.alertSettings.quietHours {
                    HStack {
                        DatePicker("From", selection: minutes(\.quietStart), displayedComponents: .hourAndMinute)
                        DatePicker("to", selection: minutes(\.quietEnd), displayedComponents: .hourAndMinute)
                    }
                    .datePickerStyle(.field)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .disabled(!enabled)

            Section("Sites") {
                ForEach(model.rankedSitesInSettingsOrder, id: \.key) { entry in
                    HStack(spacing: Theme.Space.s + 2) {
                        SiteIcon(key: entry.key, site: entry.site, size: 20)
                        Text(entry.site.name)
                        Spacer()
                        Toggle("Alerts for \(entry.site.name)", isOn: Binding(
                            get: { !model.alertSettings.mutedSites.contains(entry.key.storageKey) },
                            set: { model.setAlerts(entry.key, on: $0) }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                    }
                }
            }
            .disabled(!enabled)

            Section {
                HStack {
                    Text("Check how an alert looks and sounds.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Send a Test Alert") { model.sendTestAlert() }
                }
            }
            .disabled(!enabled)
        }
        .formStyle(.grouped)
        .animation(Theme.Motion.push, value: model.alertSettings)
        .animation(Theme.Motion.push, value: model.notificationsRefused)
        .frame(width: SettingsLayout.paneSize.width, height: SettingsLayout.paneSize.height)
    }

    static func levelTitle(_ level: Double) -> String {
        switch level {
        case 1.25: "25% more than usual"
        case 1.5: "50% more than usual"
        default: "\(level.formatted(.number))× the usual"
        }
    }

    /// A time of day for the date picker, kept in settings as minutes after midnight.
    private func minutes(_ path: WritableKeyPath<AlertSettings, Int>) -> Binding<Date> {
        Binding {
            Calendar.current.startOfDay(for: .now).addingTimeInterval(Double(model.alertSettings[keyPath: path]) * 60)
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            model.alertSettings[keyPath: path] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
    }
}

extension AppModel {
    /// Shown sites in the order Settings lists them, for the per-site alert switches.
    var rankedSitesInSettingsOrder: [(key: SiteKey, site: Site)] {
        shownSites.map { (SiteKey(connection: $0.connection.id, site: $0.site.id), $0.site) }
    }
}
