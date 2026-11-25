import AppKit
import SwiftUI

/// The app's design tokens. Colours come from the Runlight dashboard and website (zinc neutrals and the
/// lamp green), so the Mac app reads as the same product. Everything else defers to the system.
enum Theme {
    // MARK: Colour

    /// The lamp: Runlight's one accent. Live dots, rises, and the lit corner of the mark.
    static let lamp = Color(light: 0x16A34A, dark: 0x4ADE80)
    /// A rise in a number. Slightly deeper than the lamp in light mode so small text stays readable.
    static let up = Color(light: 0x15803D, dark: 0x4ADE80)
    /// A fall in a number.
    static let down = Color(light: 0xB91C1C, dark: 0xF87171)
    /// The first chart series, for sparklines.
    static let series = Color(light: 0x2A78D6, dark: 0x3987E5)
    /// The popover's surface, laid over the system blur: the dashboard's sheet colours, so dark mode
    /// is a deep near black rather than whatever grey the blur makes of the windows behind.
    static let panel = Color(light: 0xFFFFFF, dark: 0x111113)
    static let panelOpacity: Double = 0.95
    /// Hairlines between rows and around the panel.
    static let hairline = Color(light: 0x000000, dark: 0xFFFFFF).opacity(0.08)

    // MARK: Spacing (a 4 point grid)

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: Shape

    enum Radius {
        /// The popover's corners, matched to the system's own menu bar panels.
        static var panel: CGFloat {
            if #available(macOS 26, *) { 18 } else { 10 }
        }
        static let row: CGFloat = 8
        static let control: CGFloat = 6
    }

    // MARK: Layout

    static let popoverWidth: CGFloat = 360

    // MARK: Motion

    enum Motion {
        /// Hover and press feedback: quick enough to feel instant, slow enough to see.
        static let hover = Animation.easeOut(duration: 0.12)
        /// Pushing and popping views inside the popover.
        static let push = Animation.spring(response: 0.34, dampingFraction: 0.88)
        /// Numbers rolling to a new value.
        static let number = Animation.spring(response: 0.45, dampingFraction: 0.9)
        /// The panel appearing and going away.
        static let panelIn: TimeInterval = 0.16
        static let panelOut: TimeInterval = 0.10
    }
}

extension Color {
    /// A colour that follows the appearance it is drawn in, given as 0xRRGGBB for each.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight]).map { $0 == .darkAqua || $0 == .vibrantDark } ?? false
            return NSColor(rgb: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(rgb: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: alpha
        )
    }
}
