import AppKit
import Sparkle

/// The menu bar shown while the Settings window is open. It also carries the Edit menu, which is
/// what makes Command-C, Command-V and friends work in text fields.
@MainActor
enum MainMenu {
    static func make(target: AppDelegate) -> NSMenu {
        let main = NSMenu()

        let app = NSMenu(title: "Runlight")
        app.addItem(withTitle: "About Runlight", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(withTitle: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "").target = target.updater
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(AppDelegate.openSettingsFromMenu), keyEquivalent: ",").target = target
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Runlight", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit Runlight", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: app)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: edit)

        // For the dashboard window; the items find it through the responder chain.
        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Back", action: #selector(DashboardWindowController.goBack(_:)), keyEquivalent: "[")
        view.addItem(withTitle: "Forward", action: #selector(DashboardWindowController.goForward(_:)), keyEquivalent: "]")
        view.addItem(withTitle: "Reload Page", action: #selector(DashboardWindowController.reloadPage(_:)), keyEquivalent: "r")
        view.addItem(.separator())
        view.addItem(withTitle: "Actual Size", action: #selector(DashboardWindowController.actualSize(_:)), keyEquivalent: "0")
        view.addItem(withTitle: "Zoom In", action: #selector(DashboardWindowController.zoomIn(_:)), keyEquivalent: "+")
        view.addItem(withTitle: "Zoom Out", action: #selector(DashboardWindowController.zoomOut(_:)), keyEquivalent: "-")
        view.addItem(.separator())
        view.addItem(withTitle: "Open in Browser", action: #selector(DashboardWindowController.openInBrowser(_:)), keyEquivalent: "O")
        main.addItem(submenu: view)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(submenu: window)
        NSApp.windowsMenu = window

        return main
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
