// Draws the made-up sites' icons for the demo install (scripts/demo/serve.mts): a coloured tile with
// a letter, at 128 pixels. Run: swift scripts/demo/make-icons.swift
import AppKit

let sites: [(host: String, color: NSColor, letter: String)] = [
    ("tulvane.com", NSColor(srgbRed: 0.06, green: 0.46, blue: 0.43, alpha: 1), "T"),
    ("kettleandpine.com", NSColor(srgbRed: 0.71, green: 0.33, blue: 0.04, alpha: 1), "K"),
    ("maplestack.dev", NSColor(srgbRed: 0.31, green: 0.27, blue: 0.90, alpha: 1), "M"),
    ("fieldnote.blog", NSColor(srgbRed: 0.75, green: 0.07, blue: 0.24, alpha: 1), "F"),
    ("saltgrass.studio", NSColor(srgbRed: 0.20, green: 0.25, blue: 0.33, alpha: 1), "S"),
]
let dir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "scripts/demo/icons")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let size = 128
for site in sites {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    site.color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: 28, yRadius: 28).fill()
    let base = NSFont.systemFont(ofSize: 76, weight: .bold)
    let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 76) } ?? base
    let text = NSAttributedString(string: site.letter, attributes: [.font: font, .foregroundColor: NSColor.white])
    let bounds = text.size()
    text.draw(at: NSPoint(x: (CGFloat(size) - bounds.width) / 2, y: (CGFloat(size) - bounds.height) / 2 + 1))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: dir.appending(path: "\(site.host).png"))
}
print("Drew \(sites.count) icons into \(dir.path)")
