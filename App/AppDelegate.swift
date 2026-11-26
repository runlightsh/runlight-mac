import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: PopoverController?
    private let model = AppModel()
    private lazy var settings = SettingsWindowController(model: model)
    private lazy var dashboards = DashboardWindows(model: model)

    /// Unit tests load the app as their host; they get no menu bar item.
    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make(target: self)
        AppAppearance.apply()
        guard !isRunningTests else { return }

        let actions = PopoverActions(
            openSettings: { [weak self] tab in self?.openSettings(tab) },
            openDashboard: { [weak self] url in self?.openDashboard(url) },
            addConnection: { [weak self] in
                self?.model.addingConnection = true
                self?.openSettings(.connections)
            },
            quit: { NSApp.terminate(nil) }
        )
        let model = model
        popover = PopoverController { PopoverView(actions: actions).environment(model) }
        popover?.onShow = { model.popoverOpened() }
        popover?.onHide = { model.popoverClosed() }
        popover?.onEscape = { withAnimation(Theme.Motion.push) { model.collapse() } }
        model.startPolling()
        model.connectionRemoved = { [weak self] id in self?.dashboards.close(id) }
        UNUserNotificationCenter.current().delegate = self

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "Runlight"
        if let button = item.button {
            button.image = MenuBarIcon.image()
            button.imagePosition = .imageLeading
            button.setAccessibilityLabel("Runlight")
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
        followMenuBarNumber()

        #if DEBUG
        // For screenshots and UI checks: `-OpenPopover YES`, `-ExpandSite <site>`, `-OpenSettings general` (with `-AddConnection YES` for the sheet), and
        // `-appearance dark` (read by AppAppearance, so it is not debug only).
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "OpenPopover"), let button = item.button {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.popover?.show(from: button) }
        }
        if defaults.bool(forKey: "AddConnection") { model.addingConnection = true }
        // `-OpenDashboard YES` opens the first connection's dashboard window.
        if defaults.bool(forKey: "OpenDashboard") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.openDashboard(nil) }
        }
        // `-ExpandSite dailyphototips.com` opens that site's detail.
        if let site = defaults.string(forKey: "ExpandSite"), let entry = model.allSites.first(where: { $0.site.id == site }) {
            model.expandedSite = SiteKey(connection: entry.connection.id, site: site)
        }
        if let tab = defaults.string(forKey: "OpenSettings").flatMap(SettingsTab.init(rawValue:)) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.openSettings(tab) }
        }
        #endif
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening the app again from Finder or Spotlight shows the popover instead of nothing.
        if let button = statusItem?.button { popover?.show(from: button) }
        return false
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            popover?.hide(animated: false)
            showContextMenu()
        } else {
            popover?.toggle(from: sender)
        }
    }

    /// Right-click on the menu bar item: the few things you might want without opening the popover.
    private func showContextMenu() {
        guard let item = statusItem else { return }
        let menu = NSMenu()
        for state in model.connections {
            let title = model.connections.count == 1 ? "Open Dashboard" : "Open \(state.connection.name)"
            let entry = menu.addItem(withTitle: title, action: #selector(openDashboardFromMenu(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = state.connection.baseURL
        }
        if !model.connections.isEmpty { menu.addItem(.separator()) }
        menu.addItem(withTitle: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Runlight", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc func openSettingsFromMenu() { openSettings(nil) }

    @objc private func openDashboardFromMenu(_ sender: NSMenuItem) {
        guard let base = sender.representedObject as? URL, let connection = model.connection(for: base) else { return }
        popover?.hide(animated: false)
        dashboards.show(connection)
    }

    /// Opens a dashboard page in the window or the browser, as Settings says. With no address, the
    /// first connection's dashboard where it was left.
    func openDashboard(_ url: URL?) {
        popover?.hide(animated: false)
        guard let url else {
            if let first = model.connections.first?.connection {
                if model.opensSitesInWindow { dashboards.show(first) } else { NSWorkspace.shared.open(first.baseURL) }
            }
            return
        }
        if model.opensSitesInWindow, let connection = model.connection(for: url) {
            dashboards.show(connection, at: url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Keeps the number beside the icon in step with the model: today's visitors across every site,
    /// in the menu bar's own font with figures that don't shift as they change. Nothing shows until
    /// the first numbers arrive.
    private func followMenuBarNumber() {
        withObservationTracking {
            updateMenuBarNumber(model.menuBarNumber)
            updateMenuBarLamp(model.spikeLit)
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.followMenuBarNumber() }
        }
    }

    /// The total, or the pinned site's visitors, for the period the popover shows, so the two agree.
    private func updateMenuBarNumber(_ number: (value: Int, description: String)?) {
        guard let button = statusItem?.button else { return }
        let text = number.map { " " + NumberText.compact($0.value) } ?? ""
        button.toolTip = number?.description
        button.setAccessibilityLabel(number.map { "Runlight, \($0.description)" } ?? "Runlight")
        guard button.title != text else { return }
        button.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium),
            .baselineOffset: 0.5,
        ])
    }

    /// The lamp lights green after a spike alert, until the popover is opened.
    private func updateMenuBarLamp(_ lit: Bool) {
        guard let button = statusItem?.button, (button.image?.isTemplate == lit) else { return }
        button.image = MenuBarIcon.image(lit: lit, appearance: button.effectiveAppearance)
    }

    /// A spike alert was clicked: the popover opens on that site.
    func showAlertedSite(_ storageKey: String) {
        guard let key = SiteKey(storageKey: storageKey), let button = statusItem?.button else { return }
        model.openFromAlert(key)
        popover?.show(from: button)
    }

    func openSettings(_ tab: SettingsTab?) {
        popover?.hide(animated: false)
        settings.show(tab)
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Alerts show even while Runlight's popover or Settings is open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let site = response.notification.request.content.userInfo[SystemNotifier.siteKey] as? String else { return }
        await MainActor.run { self.showAlertedSite(site) }
    }
}
