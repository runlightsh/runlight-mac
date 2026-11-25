import AppKit
import Testing
@testable import Runlight

@MainActor
struct MenuBarIconTests {
    @Test func normalIconIsATemplateSoTheSystemTintsIt() {
        let image = MenuBarIcon.image()
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))
    }

    @Test func litIconKeepsItsColour() {
        let image = MenuBarIcon.image(lit: true, appearance: NSAppearance(named: .darkAqua))
        #expect(!image.isTemplate)
        #expect(image.accessibilityDescription?.contains("spiking") == true)
    }
}

struct PanelPlacementTests {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 944)
    let size = CGSize(width: 360, height: 400)

    @Test func centresUnderTheItemJustBelowTheBar() {
        let anchor = CGRect(x: 1000, y: 944, width: 30, height: 24)
        let frame = PanelPlacement.frame(size: size, anchor: anchor, visible: screen)
        #expect(frame.midX == 1015)
        #expect(frame.maxY == 944 - PanelPlacement.gap)
        #expect(frame.height == 400)
    }

    @Test func staysOnScreenNearTheRightEdge() {
        let anchor = CGRect(x: 1490, y: 944, width: 20, height: 24)
        let frame = PanelPlacement.frame(size: size, anchor: anchor, visible: screen)
        #expect(frame.maxX == screen.maxX - PanelPlacement.margin)
    }

    @Test func staysOnScreenNearTheLeftEdge() {
        let anchor = CGRect(x: 4, y: 944, width: 20, height: 24)
        let frame = PanelPlacement.frame(size: size, anchor: anchor, visible: screen)
        #expect(frame.minX == screen.minX + PanelPlacement.margin)
    }

    @Test func shrinksToFitAShortScreen() {
        let short = CGRect(x: 0, y: 0, width: 1512, height: 300)
        let anchor = CGRect(x: 700, y: 300, width: 30, height: 24)
        let frame = PanelPlacement.frame(size: size, anchor: anchor, visible: short)
        #expect(frame.minY >= PanelPlacement.margin)
        #expect(frame.height < 400)
    }

    @Test func followsAScreenWithAnOffsetOrigin() {
        let second = CGRect(x: -1920, y: 0, width: 1920, height: 1055)
        let anchor = CGRect(x: -900, y: 1055, width: 30, height: 24)
        let frame = PanelPlacement.frame(size: size, anchor: anchor, visible: second)
        #expect(frame.midX == -885)
        #expect(second.contains(frame))
    }
}

struct MarkGeometryTests {
    @Test func fitsTheMarkIntoAnyRect() {
        let rect = CGRect(x: 10, y: 20, width: 64, height: 64)
        let housing = MarkGeometry.fit(MarkGeometry.housingPath, in: rect).boundingBox
        #expect(rect.contains(housing))
        #expect(abs(housing.width - 54) < 0.01)
    }

    @Test func theLampSitsInTheTopRightCorner() {
        let lamp = MarkGeometry.lampPath.boundingBox
        #expect(lamp.midX > MarkGeometry.housing.midX)
        #expect(lamp.midY < MarkGeometry.housing.midY)
    }
}
