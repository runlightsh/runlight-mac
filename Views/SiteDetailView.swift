import SwiftUI

/// What opens under a site's row: the sparkline grown into a chart, the five headline numbers, who's
/// on now, the top pages, sources, and goals, and the way into the full dashboard.
struct SiteDetailView: View {
    let key: SiteKey
    let site: Site
    /// Shared with the row, so its sparkline grows into the chart rather than being swapped for it.
    let chartSpace: Namespace.ID

    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        let snapshot = model.snapshot(key)
        let summary = model.summary(key)
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SeriesChart(
                values: summary.sparkline,
                compare: summary.sparklineCompare,
                starts: snapshot?.series?.points.map(\.start) ?? [],
                period: model.period,
                timeZone: TimeZone(identifier: site.timezone) ?? .current
            )
            .matchedGeometryEffect(id: key, in: chartSpace)
            .frame(height: 118)

            StatGrid(stats: snapshot?.stats?.stats)

            TopLists(key: key)

            Button {
                if let url = model.dashboardURL(key) { openURL(url) }
            } label: {
                Label("Open in Runlight", systemImage: "arrow.up.right")
                    .labelStyle(TrailingIconLabelStyle())
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SoftButtonStyle())
            .help(model.dashboardURL(key)?.absoluteString ?? "")
        }
        .padding(.horizontal, Theme.Space.s + 2)
        .padding(.top, Theme.Space.xxs)
        .padding(.bottom, Theme.Space.s + 2)
    }
}

// MARK: Chart

/// The period so far over the comparison, with a readout of the point under the pointer and the
/// hours or days along the bottom in the site's own timezone.
struct SeriesChart: View {
    let values: [Double]
    let compare: [Double]
    /// When each slot of the period starts, for the labels.
    let starts: [Date]
    let period: Period
    let timeZone: TimeZone

    @State private var hover: Int?
    @State private var width: CGFloat = 0

    private static let axis: CGFloat = 14
    private static let inset: CGFloat = 3

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs + 2) {
            readout
                .frame(height: 14)
            Canvas { context, size in draw(&context, size) }
                .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location): hover = index(at: location.x)
                    case .ended: hover = nil
                    }
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(period == .today ? "Visitors by hour" : "Visitors by day")
        .accessibilityValue(spokenPeak)
    }

    private var count: Int { max(starts.count, values.count, compare.count) }

    /// The legend, or, under the pointer, that point's time and numbers.
    @ViewBuilder private var readout: some View {
        HStack(spacing: Theme.Space.s) {
            if let hover, hover < count {
                Text(label(hover, long: true))
                    .font(.system(size: 10.5, weight: .semibold))
                if hover < values.count {
                    Swatch(dashed: false)
                    Text(Int(values[hover]).formatted(.number))
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                if hover < compare.count {
                    Swatch(dashed: true)
                    Text("\(Int(compare[hover]).formatted(.number)) \(comparisonName.lowercased())")
                        .font(.system(size: 10.5, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } else {
                Swatch(dashed: false)
                Text(period == .today ? "Today" : "This period")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                if !compare.isEmpty {
                    Swatch(dashed: true)
                        .padding(.leading, Theme.Space.xs)
                    Text(comparisonName)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .animation(nil, value: hover)
    }

    private var comparisonName: String { period == .today ? "Yesterday" : "Before" }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
        guard count > 1 else { return }
        let plot = CGRect(x: 0, y: 0, width: size.width, height: max(1, size.height - Self.axis))
        let top = Self.niceCeiling(max(values.max() ?? 0, compare.max() ?? 0, 1))
        func point(_ index: Int, _ value: Double) -> CGPoint {
            CGPoint(
                x: Self.inset + CGFloat(index) / CGFloat(count - 1) * (plot.width - Self.inset * 2),
                y: plot.maxY - Self.inset - CGFloat(value / top) * (plot.height - Self.inset * 2)
            )
        }

        // Three quiet rules: the floor, half, and the top, labelled at the right.
        for step in [0.0, 0.5, 1.0] {
            let y = point(0, top * step).y
            var rule = Path()
            rule.move(to: CGPoint(x: 0, y: y))
            rule.addLine(to: CGPoint(x: plot.width, y: y))
            context.stroke(rule, with: .color(.primary.opacity(step == 0 ? 0.1 : 0.05)), style: StrokeStyle(lineWidth: 1, dash: step == 0 ? [] : [2, 3]))
            if step > 0 {
                context.draw(
                    Text(NumberText.compact(Int(top * step))).font(.system(size: 9, design: .rounded)).foregroundStyle(.tertiary),
                    at: CGPoint(x: plot.width, y: y - 2), anchor: .bottomTrailing
                )
            }
        }

        if compare.count > 1 {
            let line = Sparkline.smooth(compare.enumerated().map { point($0.offset, $0.element) })
            context.stroke(line, with: .color(.primary.opacity(0.22)), style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round, dash: [3, 3]))
        }

        let points = values.enumerated().map { point($0.offset, $0.element) }
        if points.count > 1 {
            let line = Sparkline.smooth(points)
            var area = line
            area.addLine(to: CGPoint(x: points.last!.x, y: plot.maxY))
            area.addLine(to: CGPoint(x: points.first!.x, y: plot.maxY))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(
                Gradient(colors: [Theme.series.opacity(0.24), Theme.series.opacity(0)]),
                startPoint: CGPoint(x: 0, y: plot.minY), endPoint: CGPoint(x: 0, y: plot.maxY)
            ))
            context.stroke(line, with: .color(Theme.series), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }

        if let hover, hover < count {
            let x = point(hover, 0).x
            var rule = Path()
            rule.move(to: CGPoint(x: x, y: plot.minY))
            rule.addLine(to: CGPoint(x: x, y: plot.maxY))
            context.stroke(rule, with: .color(.primary.opacity(0.18)), lineWidth: 1)
            if hover < compare.count { dot(&context, point(hover, compare[hover]), color: .primary.opacity(0.45), radius: 2.5) }
            if hover < values.count { dot(&context, point(hover, values[hover]), color: Theme.series, radius: 3.5) }
        } else if let last = points.last {
            // The latest point, with a soft halo: where the line ends is now.
            dot(&context, last, color: Theme.series.opacity(0.2), radius: 6)
            dot(&context, last, color: Theme.series, radius: 3)
        }

        for index in ticks where index < starts.count {
            let anchor: UnitPoint = index == 0 ? .leading : index == count - 1 ? .trailing : .center
            let x = index == 0 ? 0 : index == count - 1 ? size.width : point(index, 0).x
            context.draw(
                Text(label(index, long: false)).font(.system(size: 9)).foregroundStyle(.tertiary),
                at: CGPoint(x: x, y: size.height - Self.axis / 2 + 1), anchor: anchor
            )
        }
    }

    private func dot(_ context: inout GraphicsContext, _ center: CGPoint, color: Color, radius: CGFloat) {
        context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)), with: .color(color))
    }

    /// Which slots get a label: every six hours, every day of a week, or every week of a month.
    private var ticks: [Int] {
        switch period {
        case .today: stride(from: 0, to: count, by: 6).map { $0 }
        case .sevenDays: Array(0..<count)
        case .thirtyDays: stride(from: 0, to: count - 3, by: 7).map { $0 } + [count - 1]
        }
    }

    private func label(_ index: Int, long: Bool) -> String {
        guard index < starts.count else { return "" }
        var style: Date.FormatStyle = switch period {
        case .today: .dateTime.hour()
        case .sevenDays: long ? .dateTime.weekday(.abbreviated).month(.abbreviated).day() : .dateTime.weekday(.abbreviated)
        case .thirtyDays: long ? .dateTime.weekday(.abbreviated).month(.abbreviated).day() : .dateTime.month(.abbreviated).day()
        }
        style.timeZone = timeZone
        return starts[index].formatted(style)
    }

    private func index(at x: CGFloat) -> Int? {
        guard count > 1 else { return nil }
        let span = max(1, width - Self.inset * 2)
        let index = Int(((x - Self.inset) / span * CGFloat(count - 1)).rounded())
        return min(max(index, 0), count - 1)
    }

    private var spokenPeak: String {
        guard let peak = values.indices.max(by: { values[$0] < values[$1] }) else { return "No visitors yet" }
        return "Busiest \(period == .today ? "hour" : "day") \(label(peak, long: true)), \(Int(values[peak])) visitors"
    }

    /// The top of the chart: the peak rounded up to 1, 2, 2.5, or 5 of its power of ten, so the rules read cleanly.
    static func niceCeiling(_ value: Double) -> Double {
        guard value > 0 else { return 1 }
        let magnitude = pow(10, floor(log10(value)))
        for step in [1, 2, 2.5, 5, 10] where step * magnitude >= value {
            return step * magnitude
        }
        return 10 * magnitude
    }
}

/// A short line in the legend: solid for this period, dashed for the one it's compared with.
private struct Swatch: View {
    let dashed: Bool

    var body: some View {
        Canvas { context, size in
            var line = Path()
            line.move(to: CGPoint(x: 0, y: size.height / 2))
            line.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(line, with: .color(dashed ? .primary.opacity(0.35) : Theme.series), style: StrokeStyle(lineWidth: dashed ? 1.25 : 2, lineCap: .round, dash: dashed ? [2.5, 2.5] : []))
        }
        .frame(width: 12, height: 4)
        .accessibilityHidden(true)
    }
}

// MARK: Numbers

/// Visitors, visits, pageviews, bounce rate, and the average visit, side by side.
private struct StatGrid: View {
    let stats: Stats?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            cell("Visitors", stats.map { NumberText.compact($0.visitors) })
            cell("Visits", stats.map { NumberText.compact($0.visits) })
            cell("Pageviews", stats.map { NumberText.compact($0.pageviews) })
            cell("Bounce", stats.map { NumberText.share($0.bounceRate) })
            cell("Avg. visit", stats.map { NumberText.duration($0.visitDuration) })
        }
        .padding(.vertical, Theme.Space.s)
        .padding(.horizontal, Theme.Space.s + 2)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(.primary.opacity(0.04)))
        .animation(Theme.Motion.number, value: stats)
    }

    private func cell(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value ?? "…")
                .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value ?? "loading")")
    }
}

// MARK: Lists

private enum DetailTab: String, CaseIterable, Identifiable {
    case now, pages, sources, goals
    var id: Self { self }

    var title: String {
        switch self {
        case .now: "Now"
        case .pages: "Pages"
        case .sources: "Sources"
        case .goals: "Goals"
        }
    }
}

/// Who's on now and where, then the top pages, sources, and goals for the period, one at a time
/// under tabs so the detail stays one height.
private struct TopLists: View {
    let key: SiteKey

    @Environment(AppModel.self) private var model
    @AppStorage("detailTab") private var tab: DetailTab = .pages
    @Namespace private var underline

    private static let rows = 5
    private static let rowHeight: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.m) {
                ForEach(DetailTab.allCases) { item in
                    tabButton(item)
                }
                Spacer()
            }
            .padding(.horizontal, Theme.Space.xxs)
            Hairline()
            content
                .frame(height: CGFloat(Self.rows) * Self.rowHeight, alignment: .top)
                .padding(.top, Theme.Space.xxs)
                .id(tab)
                .transition(.opacity)
        }
        .animation(Theme.Motion.hover, value: tab)
    }

    private func tabButton(_ item: DetailTab) -> some View {
        Button { tab = item } label: {
            Hovering { hovering in
                HStack(spacing: 4) {
                    let live = item == .now ? model.details[key]?.liveVisitors(at: model.now()) : nil
                    if item == .now {
                        LiveDot(live: (live ?? 0) > 0, size: 5)
                    }
                    Text(item.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tab == item ? AnyShapeStyle(.primary) : AnyShapeStyle(hovering ? .primary : .secondary))
                    if let live, live > 0 {
                        Text(live.formatted(.number))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Theme.up)
                            .contentTransition(.numericText(value: Double(live)))
                            .animation(Theme.Motion.number, value: live)
                    }
                }
                .padding(.vertical, 3)
                .overlay(alignment: .bottom) {
                    if tab == item {
                        Capsule()
                            .fill(Theme.lamp)
                            .frame(height: 2)
                            .offset(y: 5)
                            .matchedGeometryEffect(id: "underline", in: underline)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab == item ? [.isSelected] : [])
        .animation(Theme.Motion.push, value: tab)
    }

    @ViewBuilder private var content: some View {
        let detail = model.details[key]
        let breakdowns = detail?.breakdowns[model.period]
        switch tab {
        case .now:
            VStack(spacing: 0) {
                LiveCount(detail: detail, now: model.now())
                    .frame(height: Self.rowHeight)
                BarList(
                    rows: detail?.realtime.map { $0.pages.prefix(Self.rows - 1).map { BarList.Row(label: $0.value, value: $0.visitors) } },
                    empty: "No one is on the site right now",
                    rowHeight: Self.rowHeight
                )
            }
        case .pages:
            BarList(rows: breakdowns.map { $0.pages.prefix(Self.rows).map { BarList.Row(label: $0.value, value: $0.visitors) } }, empty: "No pages viewed yet", rowHeight: Self.rowHeight)
        case .sources:
            BarList(rows: breakdowns.map { $0.sources.prefix(Self.rows).map { BarList.Row(label: $0.value.isEmpty ? "Direct" : $0.value, value: $0.visitors) } }, empty: "No visits yet", rowHeight: Self.rowHeight)
        case .goals:
            BarList(
                rows: model.snapshot(key)?.goals.map { response in
                    response.goals.sorted { $0.numbers.conversions > $1.numbers.conversions }.prefix(Self.rows).map {
                        BarList.Row(label: $0.goal.name, value: $0.numbers.conversions, note: NumberText.share($0.numbers.rate))
                    }
                },
                empty: "No goals set up for this site",
                rowHeight: Self.rowHeight
            )
        }
    }
}

/// Rows with a soft bar behind each, as long as its share of the largest.
private struct BarList: View {
    struct Row: Identifiable {
        let label: String
        let value: Int
        var note: String?
        var id: String { label }
    }

    /// Nil while loading.
    let rows: [Row]?
    let empty: String
    let rowHeight: CGFloat

    var body: some View {
        if let rows {
            if rows.isEmpty {
                Text(empty)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, Theme.Space.l)
            } else {
                let peak = max(rows.map(\.value).max() ?? 1, 1)
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        HStack(spacing: Theme.Space.s) {
                            Text(row.label)
                                .font(.system(size: 11.5))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(row.label)
                            Spacer(minLength: Theme.Space.s)
                            if let note = row.note {
                                Text(note)
                                    .font(.system(size: 10.5, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(.tertiary)
                            }
                            Text(NumberText.compact(row.value))
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .frame(minWidth: 28, alignment: .trailing)
                        }
                        .padding(.horizontal, 6)
                        .frame(height: rowHeight - 2)
                        .background(alignment: .leading) {
                            GeometryReader { geometry in
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Theme.series.opacity(0.11))
                                    .frame(width: max(4, geometry.size.width * CGFloat(row.value) / CGFloat(peak)))
                            }
                        }
                        .padding(.vertical, 1)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(row.label), \(row.value)\(row.note.map { ", \($0)" } ?? "")")
                    }
                }
            }
        } else {
            VStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.primary.opacity(0.05))
                        .frame(height: rowHeight - 2)
                        .frame(maxWidth: [1, 0.7, 0.45][index] * 320, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .accessibilityLabel("Loading")
        }
    }
}

// MARK: Live

/// "52 on the site now" over the last 30 minutes of pageviews, from a fetch under a minute old.
private struct LiveCount: View {
    let detail: SiteDetail?
    let now: Date

    var body: some View {
        let live = detail?.liveVisitors(at: now)
        HStack(spacing: Theme.Space.s) {
            Text(live.map { "\($0.formatted(.number)) on the site now" } ?? "Checking who's on…")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle((live ?? 0) > 0 ? AnyShapeStyle(Theme.up) : AnyShapeStyle(.secondary))
                .contentTransition(.numericText(value: Double(live ?? 0)))
                .animation(Theme.Motion.number, value: live)
            Spacer(minLength: Theme.Space.s)
            if let minutes = detail?.realtime?.minutes, minutes.count > 1 {
                MinuteBars(minutes: minutes)
                    .frame(width: 90, height: 14)
                    .help("Pageviews each minute, the last 30 minutes")
            }
        }
        .padding(.horizontal, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(live.map { "\($0) visitors on the site now" } ?? "Loading live visitors")
    }
}

/// Pageviews each minute, oldest on the left; the minute under way is the brightest.
private struct MinuteBars: View {
    let minutes: [Int]

    var body: some View {
        Canvas { context, size in
            let peak = Double(max(minutes.max() ?? 1, 1))
            let gap: CGFloat = 1
            let width = (size.width - gap * CGFloat(minutes.count - 1)) / CGFloat(minutes.count)
            for (index, value) in minutes.enumerated() {
                let height = max(1, CGFloat(Double(value) / peak) * size.height)
                let bar = CGRect(x: CGFloat(index) * (width + gap), y: size.height - height, width: width, height: height)
                let last = index == minutes.count - 1
                context.fill(Path(roundedRect: bar, cornerRadius: min(1, width / 2)), with: .color(Theme.lamp.opacity(last ? 1 : 0.4)))
            }
        }
        .accessibilityHidden(true)
    }
}

/// A green dot that breathes while someone is on the site, and sits grey when no one is.
struct LiveDot: View {
    let live: Bool
    var size: CGFloat = 6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(live ? Theme.lamp : Color.secondary.opacity(0.5))
            .frame(width: size, height: size)
            .background {
                if live && !reduceMotion {
                    Circle()
                        .fill(Theme.lamp.opacity(0.5))
                        .scaleEffect(pulse ? 2.6 : 1)
                        .opacity(pulse ? 0 : 0.8)
                        .onAppear {
                            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
                        }
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: Buttons

/// A quiet full width button on a soft fill that firms up on hover.
struct SoftButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Hovering { hovering in
            configuration.label
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(.primary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.08 : 0.05))
                )
                .scaleEffect(configuration.isPressed ? 0.985 : 1)
                .animation(Theme.Motion.hover, value: configuration.isPressed)
        }
    }
}
