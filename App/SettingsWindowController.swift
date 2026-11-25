import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case connections, sites, alerts, general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connections: "Connections"
        case .sites: "Sites"
        case .alerts: "Alerts"
        case .general: "General"
        }
    }

    var symbol: String {
        switch self {
        case .connections: "point.3.connected.trianglepath.dotted"
        case .sites: "square.stack.3d.up"
        case .alerts: "bell.badge"
        case .general: "gearshape"
        }
    }
}

/// The Settings window: a standard toolbar of tabs that resizes smoothly to each pane.
///
/// While it is open the app shows in the Dock and the app switcher, so Command-Tab can find it
/// again; when it closes, Runlight goes back to living only in the menu bar.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let tabs = NSTabViewController()

    init() {
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.crossfade, .allowUserInteraction]
        tabs.canPropagateSelectedChildViewControllerTitle = true
        for tab in SettingsTab.allCases {
            let controller = NSHostingController(rootView: Self.view(for: tab))
            controller.sizingOptions = .preferredContentSize
            controller.title = tab.title
            let item = NSTabViewItem(viewController: controller)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            item.identifier = tab.rawValue
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("Settings")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ tab: SettingsTab? = nil) {
        if let tab, let index = tabs.tabViewItems.firstIndex(where: { $0.identifier as? String == tab.rawValue }) {
            tabs.selectedTabViewItemIndex = index
        }
        NSApp.setActivationPolicy(.regular)
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a menu bar app once nothing else is open.
        DispatchQueue.main.async {
            if !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    private static func view(for tab: SettingsTab) -> AnyView {
        switch tab {
        case .connections: AnyView(ConnectionsSettingsView())
        case .sites: AnyView(SitesSettingsView())
        case .alerts: AnyView(AlertsSettingsView())
        case .general: AnyView(GeneralSettingsView())
        }
    }
}
