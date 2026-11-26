import AppKit

/// Light, dark, or whatever the system is using. Applies to the popover and every window; the menu
/// bar icon always follows the menu bar itself.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let defaultsKey = "appearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The next one along, for the popover's button that cycles through them.
    var next: AppAppearance {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    /// A symbol for each: half a circle filled for following the system.
    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// The saved choice. A launch argument (`-appearance dark`) overrides it without saving.
    static var current: AppAppearance {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(AppAppearance.init(rawValue:)) ?? .system
    }

    @MainActor
    static func apply(_ appearance: AppAppearance = current) {
        NSApp.appearance = appearance.nsAppearance
    }
}
