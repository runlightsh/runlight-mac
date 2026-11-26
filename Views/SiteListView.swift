import SwiftUI

/// The totals for every site, then a row for each, busiest first. Clicking a row opens its detail
/// underneath, one site at a time.
struct SiteListView: View {
    @Environment(AppModel.self) private var model
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let sites = model.rankedSites
        VStack(spacing: 0) {
            TotalsHeader()
            Hairline()
            if sites.isEmpty && !model.allSites.isEmpty {
                VStack(spacing: Theme.Space.xs) {
                    Text("Every site is switched off")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Turn some back on in Settings, Sites.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Space.xl)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(sites.enumerated()), id: \.element.key) { index, entry in
                            SiteRow(key: entry.key, site: entry.site, position: index)
                                .id(entry.key)
                        }
                    }
                    .padding(.vertical, Theme.Space.xs)
                    .padding(.horizontal, Theme.Space.xs + 2)
                    .animation(Theme.Motion.push, value: sites.map(\.key))
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { contentHeight = $0 }
                }
                .scrollIndicators(.automatic)
                .frame(height: min(contentHeight, maxHeight))
                .onChange(of: model.openSite) { _, key in
                    guard let key else { return }
                    // Once the detail has opened, bring all of it into view.
                    Task {
                        try? await Task.sleep(for: .milliseconds(320))
                        withAnimation(Theme.Motion.push) { proxy.scrollTo(key, anchor: nil) }
                    }
                }
            }
        }
    }

    /// Taller with a site open, so its detail fits, but never past the screen.
    private var maxHeight: CGFloat {
        let screen = (NSScreen.main?.visibleFrame.height ?? 800) - 190
        return min(model.openSite == nil ? 420 : 640, screen)
    }
}

/// Visitors across every site, the change on the same terms as the rows, and conversions.
private struct TotalsHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let totals = model.totals
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Caption(text: model.period == .today ? "Total site visits" : "Total site visits, \(model.period.title)")
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Text(totals.visitors.map { $0.formatted(.number) } ?? "…")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(totals.visitors ?? 0)))
                    if let change = totals.change {
                        ChangeBadge(change: change)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                Text(model.period.comparison)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .opacity(totals.change == nil ? 0 : 1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(totals.visitors ?? 0) total site visits \(model.period == .today ? "today" : "in the last \(model.period.title)"), \(NumberText.spokenChange(totals.change, period: model.period))")
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Caption(text: "Conversions")
                Text(totals.conversions.map { $0.formatted(.number) } ?? "…")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(totals.conversions ?? 0)))
                    .padding(.top, 5)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(totals.conversions ?? 0) goal conversions")
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.m)
        .padding(.bottom, Theme.Space.m)
        .opacity(model.offline ? 0.5 : 1)
        .animation(Theme.Motion.number, value: totals)
    }
}

private struct Caption: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

/// An arrow and a percentage on a soft tint: green for up, red for down.
struct ChangeBadge: View {
    let change: Double
    var compact = false

    var body: some View {
        let flat = abs(change) < 0.005
        let tint = flat ? Color.secondary : change > 0 ? Theme.up : Theme.down
        HStack(spacing: 2) {
            if !flat {
                Image(systemName: change > 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: compact ? 8 : 9, weight: .bold))
            }
            Text(flat ? "Same" : NumberText.percent(change))
                .font(.system(size: compact ? 10.5 : 11.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, compact ? 0 : 6)
        .padding(.vertical, compact ? 0 : 2)
        .background {
            if !compact { Capsule().fill(tint.opacity(0.12)) }
        }
        .accessibilityHidden(true)
    }
}

private struct SiteRow: View {
    static let height: CGFloat = 46
    let key: SiteKey
    let site: Site
    /// Where the row sits in the list. A row that moves when the order changes clears its hover
    /// look, since the pointer it was under never left it.
    let position: Int

    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var hovering = false
    @Namespace private var chart

    var body: some View {
        let expanded = model.openSite == key
        VStack(spacing: 0) {
            header(expanded: expanded)
            if expanded {
                SiteDetailView(key: key, site: site, chartSpace: chart)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: -6)),
                        removal: .opacity.animation(.easeOut(duration: 0.12))
                    ))
            }
        }
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.row + 2, style: .continuous)
                .fill(.primary.opacity(expanded ? 0.045 : hovering ? 0.06 : 0))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.row + 2, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                        .opacity(expanded ? 1 : 0)
                }
        }
        .padding(.vertical, expanded ? Theme.Space.xs : 0)
        .onChange(of: position) { hovering = false }
    }

    private func header(expanded: Bool) -> some View {
        let summary = model.summary(key)
        let failure = model.failures[key]
        let quiet = model.period == .today && summary.visitors == 0
        let live = model.details[key]?.liveVisitors(at: model.now())
        // The only site shown stays open; its row isn't a button.
        let fixed = model.onlySite == key
        return HStack(spacing: Theme.Space.m - 2) {
            SiteIcon(key: key, site: site)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(site.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    openButton
                        .opacity(hovering || expanded ? 1 : 0)
                        .allowsHitTesting(hovering || expanded)
                }
                if let failure {
                    Text(Self.problem(failure))
                        .font(.system(size: 11))
                        .foregroundStyle(failure.isConnectivity ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.down))
                        .lineLimit(1)
                } else if let spike = model.spikes[key] {
                    HStack(spacing: 3) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 8, weight: .bold))
                            .symbolEffect(.pulse, options: .repeat(3))
                        Text("Spiking, \(spike.ratioText)")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Theme.up)
                    .help("\(spike.count) visitors in the last hour; usually about \(Int(spike.usual.rounded()))")
                    .transition(.opacity)
                } else if let live, live > 0 {
                    HStack(spacing: 4) {
                        LiveDot(live: true, size: 5)
                        Text("\(live.formatted(.number)) now")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.up)
                            .contentTransition(.numericText(value: Double(live)))
                    }
                    .transition(.opacity)
                } else if quiet {
                    Text("No visits yet today")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: Theme.Space.s)
            if !expanded && !quiet && !summary.sparkline.isEmpty {
                Sparkline(values: summary.sparkline, compare: summary.sparklineCompare, slots: summary.sparklineSlots)
                    .matchedGeometryEffect(id: key, in: chart)
                    .frame(width: 58, height: 22)
                    .transition(.opacity)
            }
            VStack(alignment: .trailing, spacing: 1) {
                Text(summary.visitors.map(NumberText.compact) ?? "…")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(quiet ? .tertiary : .primary)
                    .contentTransition(.numericText(value: Double(summary.visitors ?? 0)))
                if let change = summary.change, !quiet {
                    ChangeBadge(change: change, compact: true)
                }
            }
            .frame(minWidth: 52, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Space.s + 2)
        .frame(height: Self.height)
        .opacity(failure != nil || model.offline ? 0.55 : 1)
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
        .onTapGesture { withAnimation(Theme.Motion.push) { model.toggleExpanded(key) } }
        .help(expanded ? "" : "Show \(site.name)'s details")
        .animation(Theme.Motion.number, value: summary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(summary, failure: failure, quiet: quiet, live: live))
        .accessibilityValue(fixed ? "" : expanded ? "Expanded" : "Collapsed")
        .accessibilityAddTraits(fixed ? [] : .isButton)
        .accessibilityAction { withAnimation(Theme.Motion.push) { model.toggleExpanded(key) } }
        .accessibilityAction(named: "Open in Runlight") { open() }
    }

    /// A small arrow beside the name that opens the site in the web dashboard.
    private var openButton: some View {
        Button(action: open) {
            Hovering { inside in
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(inside ? AnyShapeStyle(Theme.lamp) : AnyShapeStyle(.tertiary))
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(.primary.opacity(inside ? 0.08 : 0)))
            }
        }
        .buttonStyle(.plain)
        .help("Open in Runlight")
    }

    private func open() {
        if let url = model.dashboardURL(key) { openURL(url) }
    }

    private func accessibilityText(_ summary: SiteSummary, failure: RunlightError?, quiet: Bool, live: Int?) -> String {
        if let failure { return "\(site.name), \(Self.problem(failure))" }
        if quiet { return "\(site.name), no visits yet today" }
        if let spike = model.spikes[key] { return "\(site.name), spiking, \(spike.count) visitors in the last hour, \(spike.ratioText)" }
        let visitors = summary.visitors.map { "\($0) visitors" } ?? "loading"
        let now = live.map { "\($0) on the site now" } ?? ""
        return [site.name, visitors, NumberText.spokenChange(summary.change, period: model.period), now].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    static func problem(_ error: RunlightError) -> String {
        if error.isTokenForbidden || error.status == 403 { return "This token can't read this site" }
        if error.isSiteUnreachable { return "Unreachable through the hub" }
        if error.isConnectivity { return "Offline" }
        if error.isUnknownSite { return "No longer on this install" }
        return error.message
    }
}

/// A site's stand-in icon: the first letter on a soft tile, in a colour picked from the site's id
/// so it stays the same everywhere.
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
