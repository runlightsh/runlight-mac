import AppKit
import SwiftUI

/// Where the popover goes: centred under the menu bar item, a few points below the bar, and kept
/// fully on screen with a margin. Pure, so it is tested without a window.
enum PanelPlacement {
    static let gap: CGFloat = 5
    static let margin: CGFloat = 8

    /// - Parameters:
    ///   - size: the panel's size.
    ///   - anchor: the menu bar item's frame in screen coordinates.
    ///   - visible: the screen's visible frame (below the menu bar, beside the Dock).
    static func frame(size: CGSize, anchor: CGRect, visible: CGRect) -> CGRect {
        var x = anchor.midX - size.width / 2
        x = min(max(x, visible.minX + margin), visible.maxX - margin - size.width)
        let top = min(anchor.minY - gap, visible.maxY)
        let height = min(size.height, top - visible.minY - margin)
        return CGRect(x: x.rounded(), y: (top - height).rounded(), width: size.width, height: height.rounded())
    }

    /// Picks the screen the item is on. When the menu bar is too full to show the item, or another
    /// app hides it, macOS parks it in a screen's bottom corner, below the bar; then there is nothing to
    /// hang from, and the panel opens at the top right of the main screen instead.
    static func frame(size: CGSize, anchor: CGRect?, screens: [(frame: CGRect, visible: CGRect)], main: CGRect?) -> CGRect {
        if let anchor, anchor.width > 0,
           let screen = screens.first(where: { $0.frame.contains(CGPoint(x: anchor.midX, y: anchor.midY)) }),
           anchor.minY >= screen.visible.maxY - 2 {
            return frame(size: size, anchor: anchor, visible: screen.visible)
        }
        let visible = main ?? screens.first?.visible ?? CGRect(origin: .zero, size: size)
        let corner = CGRect(x: visible.maxX - margin - size.width / 2 - 1, y: visible.maxY + gap, width: 2, height: 0)
        return frame(size: size, anchor: corner, visible: visible)
    }
}

/// A borderless panel that floats under the menu bar like the system's own menu bar extras. It can
/// take key focus (for the connect form's text fields) without activating the app, so whatever
/// you were working in stays frontmost.
final class PopoverPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// An agent app has no visible Edit menu, so the standard editing shortcuts are routed here.
    /// Without this, pasting a token into the connect form would silently do nothing.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.charactersIgnoringModifiers else {
            return super.performKeyEquivalent(with: event)
        }
        let action: Selector? = switch key {
        case "x": #selector(NSText.cut(_:))
        case "c": #selector(NSText.copy(_:))
        case "v": #selector(NSText.paste(_:))
        case "a": #selector(NSText.selectAll(_:))
        case "z": Selector(("undo:"))
        default: nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Owns the panel: shows it under the menu bar item with a short fade and settle, sizes it to its
/// SwiftUI content (growing and shrinking from the top edge, as a menu does), and closes it on a
/// click elsewhere, Escape, or a change of Space.
@MainActor
final class PopoverController: NSObject {
    private let panel = PopoverPanel()
    private let hosting: NSHostingView<AnyView>
    private var outsideClickMonitor: Any?
    private var ownWindowClickMonitor: Any?
    private var keyMonitor: Any?
    private weak var anchorButton: NSStatusBarButton?
    private(set) var isShown = false

    var onShow: (() -> Void)?
    var onHide: (() -> Void)?
    /// Escape asks this first; when it handles the key (folding an open site away), the popover stays.
    var onEscape: (() -> Bool)?

    init<Content: View>(@ViewBuilder content: () -> Content) {
        let root = content()
        hosting = NSHostingView(rootView: AnyView(EmptyView()))
        super.init()
        hosting.rootView = AnyView(
            root
                .frame(width: Theme.popoverWidth)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { [weak self] size in
                    self?.contentSizeChanged(size)
                }
        )
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
    }

    /// When the popover last closed itself for a click elsewhere.
    private var closedForOutsideClickAt: Date?

    func toggle(from button: NSStatusBarButton) {
        if isShown { return hide() }
        // A click on the icon that a mouse down already closed it for: leave it closed.
        if let closed = closedForOutsideClickAt, Date().timeIntervalSince(closed) < 0.35 { return }
        show(from: button)
    }

    func show(from button: NSStatusBarButton) {
        guard !isShown else { return }
        isShown = true
        anchorButton = button
        let size = hosting.fittingSize
        panel.setFrame(frame(for: size), display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.Motion.panelIn
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        startMonitoring()
        onShow?()
    }

    func hide(animated: Bool = true) {
        guard isShown else { return }
        isShown = false
        stopMonitoring()
        anchorButton?.highlight(false)
        if !animated {
            panel.orderOut(nil)
            panel.alphaValue = 0
            onHide?()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.Motion.panelOut
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isShown else { return }
                self.panel.orderOut(nil)
            }
        }
        onHide?()
    }

    private func anchorFrame() -> CGRect? {
        anchorButton.flatMap { button in button.window.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) } }
    }

    private func frame(for size: CGSize) -> CGRect {
        let anchor = anchorFrame()
        return PanelPlacement.frame(size: size, anchor: anchor, screens: NSScreen.screens.map { ($0.frame, $0.visibleFrame) }, main: NSScreen.main?.visibleFrame)
    }

    private func contentSizeChanged(_ size: CGSize) {
        guard isShown, size.height > 0 else { return }
        let target = frame(for: CGSize(width: Theme.popoverWidth, height: size.height))
        guard target != panel.frame else { return }
        panel.setFrame(target, display: true)
        panel.invalidateShadow()
    }

    private func startMonitoring() {
        #if DEBUG
        // `-KeepPopoverOpen YES` stops clicks elsewhere closing it, for screenshots taken while
        // someone is using the Mac.
        if UserDefaults.standard.bool(forKey: "KeepPopoverOpen") { return }
        #endif
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The menu bar icon's own clicks may arrive here; its mouse up closes the popover.
                if let anchor = self.anchorFrame(), anchor.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation) { return }
                self.hide()
                self.closedForOutsideClickAt = Date()
            }
        }
        // Clicks in this app's own windows, like Settings, never reach the global monitor.
        ownWindowClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let window = event.window else { return }
                // The popover's own clicks, and the menu bar icon's, which toggles it on mouse up.
                if window === self.panel || window === self.anchorButton?.window { return }
                self.hide()
            }
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event } // Escape
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.onEscape?() != true { self.hide() }
            }
            return nil
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }

    private func stopMonitoring() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let ownWindowClickMonitor { NSEvent.removeMonitor(ownWindowClickMonitor) }
        ownWindowClickMonitor = nil
        outsideClickMonitor = nil
        keyMonitor = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self, name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }

    @objc private func spaceChanged() { hide() }
}
