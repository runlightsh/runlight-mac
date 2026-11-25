import Observation
import ServiceManagement

/// Opening Runlight at login, through the system's own login items. The system is the source of
/// truth, so the toggle reads its status rather than a saved preference: switching it off in
/// System Settings shows here too.
@MainActor
@Observable
final class LaunchAtLogin {
    enum State: Equatable {
        case off
        case on
        /// Registered, but the person has to allow it in System Settings, Login Items.
        case needsApproval
    }

    private(set) var state: State = .off
    private(set) var lastError: String?

    init() { refresh() }

    var isOn: Bool { state != .off }

    func refresh() {
        state = switch SMAppService.mainApp.status {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        default: .off
        }
    }

    func set(_ on: Bool) {
        lastError = nil
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
