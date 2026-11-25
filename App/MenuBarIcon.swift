import AppKit

/// Draws the mark for the menu bar.
///
/// Normally it is a template image, so the system tints it for light and dark menu bars, and the
/// lamp is an empty seat. When a site is spiking the lamp lights up green; a template image can't
/// hold colour, so that state is drawn in the menu bar's own label colour for the given appearance.
enum MenuBarIcon {
    static let size = NSSize(width: 18, height: 18)

    static func image(lit: Bool = false, appearance: NSAppearance? = nil) -> NSImage {
        let image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let ink: NSColor = lit ? labelColor(for: appearance) : .black
            context.setFillColor(ink.cgColor)
            context.addPath(MarkGeometry.fit(MarkGeometry.housingPath, in: rect))
            context.fillPath()

            context.setBlendMode(.destinationOut)
            context.addPath(MarkGeometry.fit(MarkGeometry.letter, in: rect))
            context.fillPath()
            context.addPath(MarkGeometry.fit(MarkGeometry.lampPath, in: rect))
            context.fillPath()

            if lit {
                context.setBlendMode(.normal)
                context.setFillColor(NSColor(rgb: 0x22C55E).cgColor)
                context.addPath(MarkGeometry.fit(MarkGeometry.lampPath, in: rect))
                context.fillPath()
            }
            return true
        }
        image.isTemplate = !lit
        image.accessibilityDescription = lit ? "Runlight, a site is spiking" : "Runlight"
        return image
    }

    private static func labelColor(for appearance: NSAppearance?) -> NSColor {
        let isDark = appearance?.bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight]).map { $0 == .darkAqua || $0 == .vibrantDark } ?? false
        return isDark ? .white : .black
    }
}
