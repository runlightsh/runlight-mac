import AppKit

// An agent app: no Dock icon, no main window, just the menu bar item. AppKit owns the lifecycle
// so the popover can be opened from anywhere (a notification, a shortcut), which MenuBarExtra
// doesn't allow.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
