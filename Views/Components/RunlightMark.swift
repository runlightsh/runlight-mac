import CoreGraphics
import SwiftUI

/// The Runlight mark: an R in a rounded lamp housing, with one corner lit. The geometry is the
/// dashboard's favicon, drawn in a 32 by 32 space with y pointing down, so every rendering of it
/// (menu bar, popover, app icon) is the same shape.
enum MarkGeometry {
    static let canvas: CGFloat = 32
    static let housing = CGRect(x: 2.5, y: 2.5, width: 27, height: 27)
    static let housingRadius: CGFloat = 7
    static let strokeWidth: CGFloat = 2.8
    static let lampCenter = CGPoint(x: 23.6, y: 8.4)
    static let lampRadius: CGFloat = 2.6

    /// The R as a centre line, to be stroked.
    static var letterLine: CGPath {
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

    /// The R as a filled outline, ready to fill or knock out.
    static var letter: CGPath {
        letterLine.copy(strokingWithWidth: strokeWidth, lineCap: .round, lineJoin: .round, miterLimit: 10)
    }

    static var housingPath: CGPath {
        CGPath(roundedRect: housing, cornerWidth: housingRadius, cornerHeight: housingRadius, transform: nil)
    }

    static var lampPath: CGPath {
        CGPath(ellipseIn: CGRect(x: lampCenter.x - lampRadius, y: lampCenter.y - lampRadius, width: lampRadius * 2, height: lampRadius * 2), transform: nil)
    }

    /// Scales a path from the 32 point canvas into a rect.
    static func fit(_ path: CGPath, in rect: CGRect) -> CGPath {
        let scale = min(rect.width, rect.height) / canvas
        var transform = CGAffineTransform(translationX: rect.midX - canvas * scale / 2, y: rect.midY - canvas * scale / 2).scaledBy(x: scale, y: scale)
        return path.copy(using: &transform) ?? path
    }
}

/// The mark in SwiftUI: the housing filled with the primary colour, the R cut out of it, and the
/// lamp lit in green. When `glowing`, the lamp breathes slowly, unless Reduce Motion is on.
struct RunlightMark: View {
    var size: CGFloat = 20
    var lit = true
    var glowing = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    var body: some View {
        ZStack {
            // The R and the lamp's seat are knocked out of the housing, so overlapping strokes
            // inside the letter never show as seams.
            ZStack {
                PathShape(part: .housing).fill(.primary)
                PathShape(part: .letter).fill(.black).blendMode(.destinationOut)
                PathShape(part: .lamp).fill(.black).blendMode(.destinationOut)
            }
            .compositingGroup()
            if lit {
                PathShape(part: .lamp)
                    .fill(Theme.lamp)
                    .shadow(color: Theme.lamp.opacity(glowing ? (breathe ? 0.9 : 0.35) : 0), radius: size * (breathe ? 0.14 : 0.08))
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            guard glowing, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { breathe = true }
        }
        .accessibilityHidden(true)
    }

    /// One of the mark's paths, fitted to the frame.
    private struct PathShape: Shape {
        enum Part { case housing, letter, lamp }
        let part: Part

        func path(in rect: CGRect) -> Path {
            let source = switch part {
            case .housing: MarkGeometry.housingPath
            case .letter: MarkGeometry.letter
            case .lamp: MarkGeometry.lampPath
            }
            return Path(MarkGeometry.fit(source, in: rect))
        }
    }
}

#Preview {
    HStack(spacing: 20) {
        RunlightMark(size: 16)
        RunlightMark(size: 32)
        RunlightMark(size: 64, glowing: true)
    }
    .padding(40)
}
