// Draws the app icon at every size the asset catalog needs.
// Run: swift scripts/make-icon.swift Resources/Assets.xcassets/AppIcon.appiconset
//
// The mark sits on a dark zinc squircle on Apple's macOS icon grid (an 824 point body in a 1024
// canvas, with room for the shadow). The R is lit faintly from above, and the lamp glows.

import AppKit
import CoreGraphics

let out = CommandLine.arguments.dropFirst().first ?? "Resources/Assets.xcassets/AppIcon.appiconset"

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// The mark's geometry, copied from MarkGeometry (32 point canvas, y down).
func letterPath() -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 11, y: 23))
    path.addLine(to: CGPoint(x: 11, y: 9))
    path.addLine(to: CGPoint(x: 17.2, y: 9))
    path.addArc(center: CGPoint(x: 17.2, y: 13.3), radius: 4.3, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
    path.addLine(to: CGPoint(x: 11, y: 17.6))
    path.move(to: CGPoint(x: 17, y: 17.6))
    path.addLine(to: CGPoint(x: 22, y: 23))
    return path
}

func draw(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Work in a 1024 canvas with y pointing down, like the mark.
    ctx.scaleBy(x: size / 1024, y: size / 1024)
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Drop shadow under the body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: rgb(0x000000, 0.35))
    ctx.addPath(squircle)
    ctx.setFillColor(rgb(0x18181B))
    ctx.fillPath()
    ctx.restoreGState()

    // Body: a deep zinc gradient, lighter at the top.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let bodyGradient = CGGradient(colorsSpace: space, colors: [rgb(0x2E2E33), rgb(0x111113)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bodyGradient, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])

    // Mark geometry scaled so the R fills the body comfortably.
    let scale: CGFloat = 26
    var transform = CGAffineTransform(translationX: 512 - 16 * scale, y: 512 - 16 * scale + 8).scaledBy(x: scale, y: scale)
    let lampCenter = CGPoint(x: 23.6, y: 8.4).applying(transform)
    let lampRadius = 2.6 * scale

    // The lamp's light spilling over the body.
    let spill = CGGradient(colorsSpace: space, colors: [rgb(0x22C55E, 0.38), rgb(0x22C55E, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(spill, startCenter: lampCenter, startRadius: 0, endCenter: lampCenter, endRadius: lampRadius * 6.5, options: [])
    ctx.restoreGState()

    // Hairline highlight along the top edge.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184, cornerHeight: 184, transform: nil))
    ctx.setLineWidth(3)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let rim = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.28), rgb(0xFFFFFF, 0.02)] as CFArray, locations: [0, 0.5])!
    ctx.drawLinearGradient(rim, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    ctx.restoreGState()

    // The R: near white, with a soft fall-off toward the bottom.
    let letter = letterPath().copy(strokingWithWidth: 2.8, lineCap: .round, lineJoin: .round, miterLimit: 10).copy(using: &transform)!
    // The lamp notches the R: a thin gap keeps the two from touching.
    let notch = CGMutablePath()
    notch.addRect(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    let gap = lampRadius * 1.32
    notch.addEllipse(in: CGRect(x: lampCenter.x - gap, y: lampCenter.y - gap, width: gap * 2, height: gap * 2))
    ctx.addPath(notch)
    ctx.clip(using: .evenOdd)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 14, color: rgb(0x000000, 0.45))
    ctx.addPath(letter)
    ctx.setFillColor(rgb(0xFAFAFA))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(letter)
    ctx.clip()
    let letterGradient = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF), rgb(0xD4D4D8)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(letterGradient, start: CGPoint(x: 512, y: 250), end: CGPoint(x: 512, y: 780), options: [])
    ctx.restoreGState()

    ctx.resetClip()

    // The lamp: a glow, the bulb, and a small specular highlight.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 60, color: rgb(0x4ADE80, 0.9))
    ctx.addEllipse(in: CGRect(x: lampCenter.x - lampRadius, y: lampCenter.y - lampRadius, width: lampRadius * 2, height: lampRadius * 2))
    ctx.setFillColor(rgb(0x22C55E))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: lampCenter.x - lampRadius, y: lampCenter.y - lampRadius, width: lampRadius * 2, height: lampRadius * 2))
    ctx.clip()
    let bulb = CGGradient(colorsSpace: space, colors: [rgb(0x86EFAC), rgb(0x22C55E), rgb(0x16A34A)] as CFArray, locations: [0, 0.55, 1])!
    let hot = CGPoint(x: lampCenter.x - lampRadius * 0.35, y: lampCenter.y - lampRadius * 0.4)
    ctx.drawRadialGradient(bulb, startCenter: hot, startRadius: 0, endCenter: lampCenter, endRadius: lampRadius, options: [.drawsAfterEndLocation])
    ctx.restoreGState()

    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])!
}

struct Slot { let points: Int; let scale: Int }
let slots = [16, 32, 128, 256, 512].flatMap { [Slot(points: $0, scale: 1), Slot(points: $0, scale: 2)] }
var images: [String] = []
for slot in slots {
    let name = "icon_\(slot.points)x\(slot.points)\(slot.scale == 2 ? "@2x" : "").png"
    try! draw(pixels: slot.points * slot.scale).write(to: URL(fileURLWithPath: "\(out)/\(name)"))
    images.append("""
        { "filename" : "\(name)", "idiom" : "mac", "scale" : "\(slot.scale)x", "size" : "\(slot.points)x\(slot.points)" }
    """)
}
let contents = "{\n  \"images\" : [\n\(images.joined(separator: ",\n"))\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
try! contents.write(toFile: "\(out)/Contents.json", atomically: true, encoding: .utf8)
print("Wrote \(slots.count) icons to \(out)")
