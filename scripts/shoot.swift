// Saves a PNG of each on-screen window that Runlight for Mac (sh.runlight.mac) owns, and nothing
// else on screen: windows are matched by process, not by name, since other apps can be called Runlight.
// Run: swift scripts/shoot.swift build/shots
import AppKit
import CoreGraphics

let out = CommandLine.arguments.dropFirst().first ?? "build/shots"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "sh.runlight.mac").map(\.processIdentifier))
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
var n = 0
for window in windows {
    guard let pid = window[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid),
          let id = window[kCGWindowNumber as String] as? Int,
          let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
          (bounds["Height"] ?? 0) > 30 else { continue }
    let path = "\(out)/runlight-\(n).png"
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-x", "-o", "-l", String(id), path]
    try task.run()
    task.waitUntilExit()
    print(path, bounds)
    n += 1
}
if n == 0 { print("No Runlight for Mac windows on screen.") }
