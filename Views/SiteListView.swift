import SwiftUI

/// Every site across every connection. Milestone 4 adds the numbers; for now, each site's name
/// and address, so connecting has something real to show.
struct SiteListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sites = model.allSites
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(sites, id: \.site.id) { entry in
                    SiteRow(site: entry.site)
                }
            }
            .padding(.vertical, Theme.Space.xs)
            .padding(.horizontal, Theme.Space.xs + 2)
        }
        .scrollIndicators(.automatic)
        .frame(height: min(CGFloat(sites.count) * SiteRow.height + Theme.Space.s, 470))
    }
}

private struct SiteRow: View {
    static let height: CGFloat = 40
    let site: Site
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Theme.Space.m - 2) {
            SiteMonogram(name: site.name, id: site.id)
            VStack(alignment: .leading, spacing: 1) {
                Text(site.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(site.hostnames.first ?? site.id)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.s + 2)
        .frame(height: Self.height)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(.primary.opacity(hovering ? 0.06 : 0))
        }
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
        .accessibilityElement(children: .combine)
    }
}

/// A site's stand-in icon until its own loads: the first letter on a soft tile, in a colour picked
/// from the site's id so it stays the same everywhere.
struct SiteMonogram: View {
    let name: String
    let id: String
    var size: CGFloat = 22

    private static let tints: [Color] = [
        Theme.series, Theme.lamp, Color(light: 0xD95926, dark: 0xEB6834), Color(light: 0x7C3AED, dark: 0xA78BFA),
        Color(light: 0xC98500, dark: 0xEDA100), Color(light: 0xD55181, dark: 0xE87BA4), Color(light: 0x0E7490, dark: 0x22D3EE),
    ]

    var body: some View {
        let tint = Self.tints[Self.stableIndex(id, count: Self.tints.count)]
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(tint.opacity(0.16))
            .overlay {
                Text(String(name.first(where: \.isLetter) ?? name.first ?? "?").uppercased())
                    .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    /// A small hash that doesn't change between launches, unlike `hashValue`.
    static func stableIndex(_ text: String, count: Int) -> Int {
        Int(text.unicodeScalars.reduce(UInt32(5381)) { ($0 << 5) &+ $0 &+ $1.value } % UInt32(count))
    }
}
