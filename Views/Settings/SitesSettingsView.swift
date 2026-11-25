import SwiftUI

/// Settings, Sites: every site from every connection, grouped by install. Hiding, reordering, and
/// pinning one to the menu bar join in milestone 8.
struct SitesSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.allSites.isEmpty {
                VStack(spacing: Theme.Space.s) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.tertiary)
                        .padding(.bottom, Theme.Space.xs)
                    Text("No sites yet")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Your sites appear here once a Runlight install is connected.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                    if model.isEmpty {
                        Button("Add Connection…") { model.addingConnection = true }
                            .buttonStyle(LampButtonStyle(compact: true))
                            .padding(.top, Theme.Space.s)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, Theme.Space.xxl)
            } else {
                Form {
                    ForEach(model.connections) { state in
                        Section {
                            ForEach(state.sites) { site in
                                SiteSettingsRow(site: site)
                            }
                        } header: {
                            HStack {
                                Text(state.connection.name)
                                Spacer()
                                Text("\(state.sites.count) \(state.sites.count == 1 ? "site" : "sites")")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .frame(width: SettingsLayout.paneSize.width, height: SettingsLayout.paneSize.height)
    }
}

private struct SiteSettingsRow: View {
    let site: Site

    var body: some View {
        HStack(spacing: Theme.Space.m - 2) {
            SiteMonogram(name: site.name, id: site.id, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(site.name)
                    .font(.system(size: 13))
                Text(site.hostnames.first ?? site.id)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(Self.cityName(site.timezone))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .help(site.timezone)
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
    }

    /// "America/Toronto" reads as "Toronto".
    static func cityName(_ timezone: String) -> String {
        (timezone.split(separator: "/").last.map(String.init) ?? timezone).replacingOccurrences(of: "_", with: " ")
    }
}
