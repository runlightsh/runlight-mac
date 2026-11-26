import SwiftUI

/// Settings, Sites: every site from every connection, grouped by install, each with a switch to
/// show it or not. Reordering and pinning one to the menu bar join in milestone 8.
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
                    Section {
                        @Bindable var model = model
                        Picker("Order in the popover", selection: $model.usesCustomOrder) {
                            Text("Most visitors").tag(false)
                            Text("As listed here").tag(true)
                        }
                        .pickerStyle(.segmented)
                    } footer: {
                        Text("Drag a site by its handle to reorder.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(model.connections) { state in
                        Section {
                            ForEach(model.orderedSites(state)) { site in
                                SiteSettingsRow(key: SiteKey(connection: state.id, site: site.id), site: site)
                            }
                        } header: {
                            HStack {
                                Text(state.connection.name)
                                Spacer()
                                Text(count(state))
                                    .foregroundStyle(.tertiary)
                                    .contentTransition(.numericText())
                                    .animation(Theme.Motion.number, value: count(state))
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .frame(width: SettingsLayout.paneSize.width, height: SettingsLayout.paneSize.height)
    }

    /// "14 sites", or "12 of 14 shown" once some are switched off.
    private func count(_ state: ConnectionState) -> String {
        let shown = state.sites.filter { model.isShown(SiteKey(connection: state.id, site: $0.id)) }.count
        if shown == state.sites.count { return "\(shown) \(shown == 1 ? "site" : "sites")" }
        return "\(shown) of \(state.sites.count) shown"
    }
}

private struct SiteSettingsRow: View {
    let key: SiteKey
    let site: Site

    @Environment(AppModel.self) private var model
    @State private var targeted = false
    @State private var handleHovered = false

    var body: some View {
        let shown = model.isShown(key)
        HStack(spacing: Theme.Space.m - 2) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(handleHovered ? .secondary : .tertiary)
                .frame(width: 14, height: 24)
                .contentShape(Rectangle())
                .onHover { inside in
                    handleHovered = inside
                    if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
                }
                .draggable(key.storageKey) {
                    // What follows the pointer: the site's icon and name on a small card.
                    HStack(spacing: Theme.Space.s) {
                        SiteIcon(key: key, site: site, size: 18)
                        Text(site.name).font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.regularMaterial))
                    .environment(model)
                }
                .help("Drag to reorder")
                .accessibilityHidden(true)
            SiteIcon(key: key, site: site, size: 24)
                .saturation(shown ? 1 : 0)
                .opacity(shown ? 1 : 0.5)
            VStack(alignment: .leading, spacing: 1) {
                Text(site.name)
                    .font(.system(size: 13))
                Text(site.hostnames.first ?? site.id)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .opacity(shown ? 1 : 0.55)
            Spacer()
            Text(Self.cityName(site.timezone))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .help(site.timezone)
            Toggle("Show \(site.name)", isOn: Binding(get: { shown }, set: { model.setShown(key, $0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .help(shown ? "Shown in the menu bar popover" : "Hidden from the menu bar popover")
        }
        .padding(.vertical, 1)
        .animation(Theme.Motion.hover, value: shown)
        .overlay(alignment: .top) {
            // Where the dragged site will land.
            Capsule()
                .fill(Theme.lamp)
                .frame(height: 2)
                .offset(y: -5)
                .opacity(targeted ? 1 : 0)
                .animation(Theme.Motion.hover, value: targeted)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let moving = items.first.flatMap(SiteKey.init(storageKey:)), moving.connection == key.connection else { return false }
            withAnimation(Theme.Motion.push) { model.moveSite(moving, to: key) }
            return true
        } isTargeted: { targeted = $0 }
        .accessibilityAction(named: "Move up") { move(by: -1) }
        .accessibilityAction(named: "Move down") { move(by: 1) }
    }

    /// For VoiceOver and keyboard users, who can't drag: one place up or down.
    private func move(by offset: Int) {
        guard let state = model.connections.first(where: { $0.id == key.connection }) else { return }
        let sites = model.orderedSites(state)
        guard let index = sites.firstIndex(where: { $0.id == key.site }), sites.indices.contains(index + offset) else { return }
        withAnimation(Theme.Motion.push) { model.moveSite(key, to: SiteKey(connection: key.connection, site: sites[index + offset].id)) }
    }

    /// "America/Toronto" reads as "Toronto".
    static func cityName(_ timezone: String) -> String {
        (timezone.split(separator: "/").last.map(String.init) ?? timezone).replacingOccurrences(of: "_", with: " ")
    }
}
