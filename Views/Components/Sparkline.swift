import SwiftUI

/// A small line of the period so far, over a faint line of the comparison period for context.
/// Today's line stops at now rather than stretching across the day, so where it ends says what
/// time it is, and a dot marks the latest point.
struct Sparkline: View {
    let values: [Double]
    var compare: [Double] = []
    /// How many points the whole period has; the line covers only the ones that have happened.
    var slots: Int = 0
    var tint: Color = Theme.series

    var body: some View {
        Canvas { context, size in
            let count = max(slots, values.count, compare.count)
            guard count > 1 else { return }
            let peak = max(values.max() ?? 0, compare.max() ?? 0, 1)
            let inset: CGFloat = 2
            func point(_ index: Int, _ value: Double) -> CGPoint {
                CGPoint(
                    x: inset + CGFloat(index) / CGFloat(count - 1) * (size.width - inset * 2),
                    y: size.height - inset - CGFloat(value / peak) * (size.height - inset * 2)
                )
            }

            if compare.count > 1 {
                let path = Self.smooth(compare.enumerated().map { point($0.offset, $0.element) })
                context.stroke(path, with: .color(.primary.opacity(0.16)), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
            }

            guard values.count > 0 else { return }
            let points = values.enumerated().map { point($0.offset, $0.element) }
            if points.count > 1 {
                let line = Self.smooth(points)
                var area = line
                area.addLine(to: CGPoint(x: points.last!.x, y: size.height))
                area.addLine(to: CGPoint(x: points.first!.x, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .linearGradient(
                    Gradient(colors: [tint.opacity(0.22), tint.opacity(0)]),
                    startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)
                ))
                context.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
            let last = points.last!
            context.fill(Path(ellipseIn: CGRect(x: last.x - 2.25, y: last.y - 2.25, width: 4.5, height: 4.5)), with: .color(tint))
        }
        .accessibilityHidden(true)
    }

    /// A smooth curve through every point that never overshoots them (monotone cubic interpolation,
    /// as Fritsch and Carlson describe it), so a peak on the line is the real peak and the curve
    /// never dips below zero or above the highest value between two points.
    static func smooth(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            points.dropFirst().forEach { path.addLine(to: $0) }
            return path
        }
        let n = points.count
        var slopes = (0..<n - 1).map { i -> CGFloat in
            let dx = points[i + 1].x - points[i].x
            return dx == 0 ? 0 : (points[i + 1].y - points[i].y) / dx
        }
        var tangents = [CGFloat](repeating: 0, count: n)
        tangents[0] = slopes[0]
        tangents[n - 1] = slopes[n - 2]
        for i in 1..<n - 1 {
            tangents[i] = slopes[i - 1] * slopes[i] <= 0 ? 0 : (slopes[i - 1] + slopes[i]) / 2
        }
        for i in 0..<n - 1 {
            if slopes[i] == 0 {
                tangents[i] = 0
                tangents[i + 1] = 0
                continue
            }
            let a = tangents[i] / slopes[i]
            let b = tangents[i + 1] / slopes[i]
            let length = a * a + b * b
            if length > 9 {
                let scale = 3 / length.squareRoot()
                tangents[i] = scale * a * slopes[i]
                tangents[i + 1] = scale * b * slopes[i]
            }
        }
        slopes.removeAll()
        for i in 0..<n - 1 {
            let third = (points[i + 1].x - points[i].x) / 3
            path.addCurve(
                to: points[i + 1],
                control1: CGPoint(x: points[i].x + third, y: points[i].y + tangents[i] * third),
                control2: CGPoint(x: points[i + 1].x - third, y: points[i + 1].y - tangents[i + 1] * third)
            )
        }
        return path
    }
}

/// A site's own icon from Runlight, or its letter tile when it has none.
struct SiteIcon: View {
    let key: SiteKey
    let site: Site
    var size: CGFloat = 20

    @Environment(AppModel.self) private var model

    var body: some View {
        if let entry = model.icons[key], !entry.data.isEmpty, let image = IconImages.image(entry, key: key) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
                .accessibilityHidden(true)
                .transition(.opacity)
        } else {
            SiteMonogram(name: site.name, id: site.id, size: size)
        }
    }
}

/// Decoded icons, kept so each is decoded once rather than on every redraw.
@MainActor
enum IconImages {
    private static var cache: [String: NSImage] = [:]

    static func image(_ entry: IconEntry, key: SiteKey) -> NSImage? {
        let name = "\(key.connection)/\(key.site)/\(entry.checkedAt.timeIntervalSince1970)"
        if let image = cache[name] { return image }
        guard let image = NSImage(data: entry.data), image.isValid, image.size.width > 0 else { return nil }
        cache[name] = image
        return image
    }
}

/// Today, 7 days, or 30 days: a track with a raised pill that slides to the choice.
struct PeriodPicker: View {
    @Binding var selection: Period
    @Namespace private var pill
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(Period.allCases.enumerated()), id: \.element) { index, period in
                Button {
                    withAnimation(Theme.Motion.push) { selection = period }
                } label: {
                    Hovering { hovering in
                        Text(period.shortTitle)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(selection == period ? AnyShapeStyle(.primary) : AnyShapeStyle(hovering ? .primary : .secondary))
                            .padding(.horizontal, 9)
                            .frame(height: 22)
                            .background {
                                if selection == period {
                                    Capsule(style: .continuous)
                                        .fill(colorScheme == .dark ? Color.white.opacity(0.14) : Color.white)
                                        .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.12), radius: 1.5, y: 0.5)
                                        .matchedGeometryEffect(id: "pill", in: pill)
                                }
                            }
                    }
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .accessibilityLabel(period.title)
                .accessibilityAddTraits(selection == period ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(Capsule(style: .continuous).fill(.primary.opacity(0.07)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Period")
    }
}

extension Period {
    var shortTitle: String {
        switch self {
        case .today: "Today"
        case .sevenDays: "7D"
        case .thirtyDays: "30D"
        }
    }

    var title: String {
        switch self {
        case .today: "Today"
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        }
    }

    /// What the change is measured against.
    var comparison: String {
        switch self {
        case .today: "vs. this time yesterday"
        case .sevenDays: "vs. the 7 days before"
        case .thirtyDays: "vs. the 30 days before"
        }
    }
}
