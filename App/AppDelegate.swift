import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: PopoverController?
    private let model = AppModel()
    private lazy var settings = SettingsWindowController(model: model)

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
            addConnection: { [weak self] in
                self?.model.addingConnection = true
                self?.openSettings(.connections)
            },
            quit: { NSApp.terminate(nil) }
        )
        let model = model
        popover = PopoverController { PopoverView(actions: actions).environment(model) }
        popover?.onShow = { model.popoverOpened() }
        model.startPolling()

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
        // For screenshots and UI checks: `-OpenPopover YES`, `-OpenSettings general` (with `-AddConnection YES` for the sheet), and
        // `-appearance dark` (read by AppAppearance, so it is not debug only).
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "OpenPopover"), let button = item.button {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.popover?.show(from: button) }
        }
        if defaults.bool(forKey: "AddConnection") { model.addingConnection = true }
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
            popover?.hide()
            showContextMenu()
        } else {
            popover?.toggle(from: sender)
        }
    }

    /// Right-click on the menu bar item: the few things you might want without opening the popover.
    private func showContextMenu() {
        guard let item = statusItem else { return }
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Runlight", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc func openSettingsFromMenu() { openSettings(nil) }

    /// Keeps the number beside the icon in step with the model: today's visitors across every site,
    /// in the menu bar's own font with figures that don't shift as they change. Nothing shows until
    /// the first numbers arrive.
    private func followMenuBarNumber() {
        withObservationTracking {
            updateMenuBarNumber(model.visitorsToday)
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.followMenuBarNumber() }
        }
    }

    private func updateMenuBarNumber(_ visitors: Int?) {
        guard let button = statusItem?.button else { return }
        let text = visitors.map { " " + NumberText.compact($0) } ?? ""
        guard button.title != text else { return }
        button.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium),
            .baselineOffset: 0.5,
        ])
        button.setAccessibilityLabel(visitors.map { "Runlight, \($0) visitors today" } ?? "Runlight")
    }

    func openSettings(_ tab: SettingsTab?) {
        popover?.hide()
        settings.show(tab)
    }
}
