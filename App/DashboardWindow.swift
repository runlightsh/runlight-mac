import AppKit
import SwiftUI
import WebKit

/// Where a link from inside the dashboard window should go.
enum DashboardRoute: Equatable {
    /// Stays in the window: the install's own pages, its sign-in, and the CMS login in front of it.
    case stay
    /// Somewhere else on the web, or another app's link: the default browser or app.
    case elsewhere
}

enum DashboardPolicy {
    /// Pages on the install's own origin stay in the window; everything else leaves it.
    static func route(_ url: URL, base: URL) -> DashboardRoute {
        guard let scheme = url.scheme?.lowercased() else { return .stay }
        switch scheme {
        case "about", "blob", "data": return .stay
        case "http", "https": return sameOrigin(url, base) ? .stay : .elsewhere
        default: return .elsewhere
        }
    }

    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased()
            && a.host()?.lowercased() == b.host()?.lowercased()
            && port(a) == port(b)
    }

    private static func port(_ url: URL) -> Int? {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : url.scheme?.lowercased() == "http" ? 80 : nil)
    }
}

/// One dashboard window per connection, made when first asked for.
@MainActor
final class DashboardWindows {
    private var windows: [UUID: DashboardWindowController] = [:]
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    /// Opens a connection's dashboard, at `url` if given, else where it was left.
    func show(_ connection: Connection, at url: URL? = nil) {
        let controller = windows[connection.id] ?? {
            let made = DashboardWindowController(connection: connection, defaults: model.defaults)
            windows[connection.id] = made
            return made
        }()
        controller.show(url)
    }

    /// A connection was removed: its window goes too.
    func close(_ id: UUID) {
        windows.removeValue(forKey: id)?.close()
    }
}

/// The install's own web dashboard in a window: its sign-in, every report, and every setting,
/// exactly as in a browser, with the app's toolbar around it.
@MainActor
final class DashboardWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, NSToolbarDelegate {
    let connection: Connection
    private let defaults: UserDefaults
    private let webView: WKWebView
    private let progress = LoadingBar()
    private let problem = NSHostingView(rootView: AnyView(EmptyView()))
    private var observations: [NSKeyValueObservation] = []
    private var backButton: NSButton?
    private var forwardButton: NSButton?

    private var lastPageKey: String { "dashboard.\(connection.id.uuidString).page" }

    init(connection: Connection, defaults: UserDefaults) {
        self.connection = connection
        self.defaults = defaults

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.applicationNameForUserAgent = "Runlight/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")"
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        // The window's own colour shows until the page paints, so dark mode never flashes white.
        webView.setValue(false, forKey: "drawsBackground")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.minSize = NSSize(width: 640, height: 480)
        window.title = connection.name
        window.subtitle = connection.name
        window.titlebarSeparatorStyle = .automatic
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("Dashboard-\(connection.id.uuidString)")
        super.init(window: window)

        let container = NSView()
        for view in [webView, progress, problem] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            progress.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            progress.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            progress.heightAnchor.constraint(equalToConstant: 2),
            problem.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            problem.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            problem.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            problem.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        problem.isHidden = true
        window.contentView = container

        let toolbar = NSToolbar(identifier: "Dashboard")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self

        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.titleChanged(webView.title) }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.progress.set(webView.estimatedProgress, loading: webView.isLoading) }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.progress.set(webView.estimatedProgress, loading: webView.isLoading) }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.backButton?.isEnabled = webView.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.forwardButton?.isEnabled = webView.canGoForward }
            },
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Showing

    func show(_ url: URL?) {
        if let url {
            load(url)
        } else if webView.url == nil {
            load(lastPage ?? connection.baseURL.appending(path: ""))
        }
        DockPresence.windowOpened()
        if window?.isVisible != true, defaults.string(forKey: "NSWindow Frame Dashboard-\(connection.id.uuidString)") == nil {
            window?.center()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(webView)
        NSApp.activate()
    }

    private func load(_ url: URL) {
        hideProblem()
        webView.load(URLRequest(url: url))
    }

    /// The last page of this install's dashboard the window showed, to open on next time.
    private var lastPage: URL? {
        defaults.string(forKey: lastPageKey).flatMap(URL.init(string:)).flatMap {
            DashboardPolicy.route($0, base: connection.baseURL) == .stay ? $0 : nil
        }
    }

    private func titleChanged(_ title: String?) {
        let page = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        window?.title = page.isEmpty ? connection.name : page
    }

    func windowWillClose(_ notification: Notification) {
        DockPresence.windowClosed()
    }

    // MARK: Actions (the toolbar and the View menu)

    @objc func goBack(_ sender: Any?) { webView.goBack() }
    @objc func goForward(_ sender: Any?) { webView.goForward() }
    @objc func reloadPage(_ sender: Any?) {
        hideProblem()
        if webView.url == nil { show(nil) } else { webView.reload() }
    }
    @objc func openInBrowser(_ sender: Any?) {
        NSWorkspace.shared.open(webView.url ?? connection.baseURL)
    }
    @objc func actualSize(_ sender: Any?) { webView.pageZoom = 1 }
    @objc func zoomIn(_ sender: Any?) { webView.pageZoom = min(webView.pageZoom + 0.1, 3) }
    @objc func zoomOut(_ sender: Any?) { webView.pageZoom = max(webView.pageZoom - 0.1, 0.5) }

    // MARK: Navigation

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.shouldPerformDownload { return .download }
        guard let url = navigationAction.request.url else { return .allow }
        // Frames inside the page load what they like; only where the window itself goes is decided here.
        if navigationAction.targetFrame?.isMainFrame == false { return .allow }
        switch DashboardPolicy.route(url, base: connection.baseURL) {
        case .stay:
            return .allow
        case .elsewhere:
            NSWorkspace.shared.open(url)
            return .cancel
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let attachment = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") ?? false
        return attachment || !navigationResponse.canShowMIMEType ? .download : .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hideProblem()
        if let url = webView.url, DashboardPolicy.route(url, base: connection.baseURL) == .stay, url.scheme?.hasPrefix("http") == true {
            defaults.set(url.absoluteString, forKey: lastPageKey)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showProblem(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showProblem(error)
    }

    /// The page asked for a new window, as a link with target=_blank does.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if DashboardPolicy.route(url, base: connection.baseURL) == .stay {
                webView.load(navigationAction.request)
            } else {
                NSWorkspace.shared.open(url)
            }
        }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    // MARK: Alerts the page raises

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        await present(alert)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return await present(alert) == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return await present(alert) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        guard let window else { return nil }
        return await panel.beginSheetModal(for: window) == .OK ? panel.urls : nil
    }

    @discardableResult
    private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window else { return alert.runModal() }
        return await alert.beginSheetModal(for: window)
    }

    // MARK: Downloads

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        Self.freeDestination(suggestedFilename, in: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0])
    }

    func downloadDidFinish(_ download: WKDownload) {
        // The Downloads stack in the Dock bounces, as it does for Safari.
        if let path = download.progress.fileURL?.path {
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: path)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let alert = NSAlert()
        alert.messageText = "The download didn't finish"
        alert.informativeText = error.localizedDescription
        Task { await present(alert) }
    }

    /// `name` in `folder`, or "name 2", "name 3", and so on when it's taken.
    nonisolated static func freeDestination(_ name: String, in folder: URL) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appending(path: name)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appending(path: ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }

    // MARK: When the install can't be reached

    private func showProblem(_ error: Error) {
        let error = error as NSError
        // A link that leaves the window, or a page swapped for a download, is cancelled, not failed.
        if error.code == NSURLErrorCancelled || error.domain == "WebKitErrorDomain" && error.code == 102 { return }
        let offline = error.domain == NSURLErrorDomain && [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost].contains(error.code)
        problem.rootView = AnyView(
            DashboardProblem(
                title: offline ? "You're offline" : "Can't reach \(connection.name)",
                detail: offline ? "The dashboard opens again once your Mac is back online." : error.localizedDescription,
                retry: { [weak self] in self?.reloadPage(nil) }
            )
        )
        problem.isHidden = false
    }

    private func hideProblem() {
        problem.isHidden = true
    }

    // MARK: Toolbar

    private static let back = NSToolbarItem.Identifier("back")
    private static let forward = NSToolbarItem.Identifier("forward")
    private static let reload = NSToolbarItem.Identifier("reload")
    private static let browser = NSToolbarItem.Identifier("browser")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.back, Self.forward, .flexibleSpace, Self.reload, Self.browser]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let (symbol, label, action): (String, String, Selector) = switch identifier {
        case Self.back: ("chevron.left", "Back", #selector(goBack(_:)))
        case Self.forward: ("chevron.right", "Forward", #selector(goForward(_:)))
        case Self.reload: ("arrow.clockwise", "Reload", #selector(reloadPage(_:)))
        default: ("safari", "Open in Browser", #selector(openInBrowser(_:)))
        }
        let item = NSToolbarItem(itemIdentifier: identifier)
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
        button.bezelStyle = .toolbar
        button.toolTip = label
        item.view = button
        item.label = label
        item.isNavigational = identifier == Self.back || identifier == Self.forward
        if identifier == Self.back {
            backButton = button
            button.isEnabled = false
        }
        if identifier == Self.forward {
            forwardButton = button
            button.isEnabled = false
        }
        return item
    }
}

/// A thin lamp-green line under the toolbar while a page loads.
private final class LoadingBar: NSView {
    private let fill = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(fill)
        fill.backgroundColor = NSColor(rgb: 0x22C55E).cgColor
        alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func set(_ fraction: Double, loading: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            fill.frame = CGRect(x: 0, y: 0, width: bounds.width * CGFloat(max(0.08, fraction)), height: bounds.height)
            animator().alphaValue = loading ? 1 : 0
        }
    }
}

/// Shown over the window when the dashboard couldn't load.
private struct DashboardProblem: View {
    let title: String
    let detail: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            RunlightMark(size: 40)
                .opacity(0.6)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("Try Again", action: retry)
                .buttonStyle(LampButtonStyle(compact: true))
                .keyboardShortcut(.defaultAction)
                .padding(.top, Theme.Space.xs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Runlight shows in the Dock and the app switcher while one of its windows is open, and goes back
/// to living in the menu bar when the last one closes.
@MainActor
enum DockPresence {
    static func windowOpened() {
        NSApp.setActivationPolicy(.regular)
    }

    static func windowClosed() {
        DispatchQueue.main.async {
            if !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
