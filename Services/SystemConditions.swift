import AppKit
import Network

/// Watches what decides whether polling should run: the Mac going to sleep and waking, the network
/// coming and going, and Low Power Mode. Reports each change on the main actor.
@MainActor
final class SystemConditions {
    enum Change: Equatable {
        case sleep, wake
        case online(Bool)
        case lowPower(Bool)
    }

    var onChange: (Change) -> Void = { _ in }

    private let pathMonitor = NWPathMonitor()
    private var observers: [NSObjectProtocol] = []
    private var online: Bool?

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange(.sleep) }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange(.wake) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange(.lowPower(ProcessInfo.processInfo.isLowPowerModeEnabled)) }
        })
        onChange(.lowPower(ProcessInfo.processInfo.isLowPowerModeEnabled))

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(satisfied) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "sh.runlight.mac.network"))
    }

    private func networkChanged(_ satisfied: Bool) {
        // The monitor reports every path change; only a change in reachability matters here.
        guard online != satisfied else { return }
        online = satisfied
        onChange(.online(satisfied))
    }

    deinit {
        pathMonitor.cancel()
    }
}
