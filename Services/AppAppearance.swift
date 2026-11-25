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
