import Foundation
import Sparkle

/// What Settings shows of the updater: whether it checks on its own, and a way to check now.
@MainActor
@Observable
final class Updates {
    private let updater: SPUUpdater?

    init(updater: SPUUpdater?) {
        self.updater = updater
        checksAutomatically = updater?.automaticallyChecksForUpdates ?? false
    }

    var checksAutomatically: Bool {
        didSet { updater?.automaticallyChecksForUpdates = checksAutomatically }
    }

    var lastChecked: Date? { updater?.lastUpdateCheckDate }

    func checkNow() {
        updater?.checkForUpdates()
    }
}
