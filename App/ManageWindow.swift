import AppKit
import SwiftUI

/// One Manage window per site, made when first asked for.
@MainActor
final class ManageWindows {
    private var windows: [SiteKey: ManageWindowController] = [:]
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    func show(_ key: SiteKey, pane: ManagePane = .goals) {
        let controller = windows[key] ?? {
            let made = ManageWindowController(manager: SiteManager(key: key, model: model), model: model)
            windows[key] = made
            return made
        }()
        controller.show(pane)
    }

    /// A connection was removed: its sites' windows go too.
    func close(connection id: UUID) {
        for key in windows.keys where key.connection == id {
            windows.removeValue(forKey: key)?.close()
        }
    }
}

/// A site's goals, links, and settings in a window of its own, rather than forms squeezed into the popover.
@MainActor
final class ManageWindowController: NSWindowController, NSWindowDelegate {
    private let manager: SiteManager
    private let selection: ManageSelection

    init(manager: SiteManager, model: AppModel) {
        self.manager = manager
        selection = ManageSelection()
        // AppKit's own split view, so the sidebar is the system's (floating glass on macOS 26).
        let split = NSSplitViewController()
        let sidebar = NSHostingController(rootView: ManageSidebar(manager: manager, selection: selection).environment(model))
        sidebar.sizingOptions = []
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 190
        sidebarItem.maximumThickness = 260
        sidebarItem.canCollapse = false
        let detail = NSHostingController(rootView: ManageDetail(manager: manager, selection: selection).environment(model))
        detail.sizingOptions = []
        let detailItem = NSSplitViewItem(viewController: detail)
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(detailItem)

        let window = NSWindow(contentViewController: split)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 860, height: 580))
        window.minSize = NSSize(width: 700, height: 460)
        window.title = "Manage \(manager.site?.name ?? manager.key.site)"
        window.subtitle = manager.connectionName
        window.titleVisibility = .visible
        window.toolbar = NSToolbar(identifier: "Manage")
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("Manage-\(manager.key.storageKey)")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ pane: ManagePane) {
        selection.pane = pane
        DockPresence.windowOpened()
        if window?.isVisible != true, UserDefaults.standard.string(forKey: "NSWindow Frame Manage-\(manager.key.storageKey)") == nil {
            window?.center()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        DockPresence.bringForward()
        Task { await manager.load() }
    }

    func windowWillClose(_ notification: Notification) {
        DockPresence.windowClosed()
    }
}

/// Which pane a Manage window shows, so the app can open it on Links, say.
@MainActor
@Observable
final class ManageSelection {
    var pane: ManagePane = .goals
}
