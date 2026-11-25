// Saves a PNG of each on-screen window that Runlight owns, and nothing else on screen.
// Run: swift scripts/shoot.swift build/shots
import CoreGraphics
import Foundation

let out = CommandLine.arguments.dropFirst().first ?? "build/shots"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
var n = 0
for window in windows where window[kCGWindowOwnerName as String] as? String == "Runlight" {
    guard let id = window[kCGWindowNumber as String] as? Int,
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
if n == 0 { print("No Runlight windows on screen.") }
