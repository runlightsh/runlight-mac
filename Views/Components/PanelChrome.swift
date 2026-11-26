import AppKit
import SwiftUI

/// The system's translucent material, as the popover's backdrop.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// Gives the popover its shape: the brand surface over a soft blur, rounded corners, and a hairline edge that is a touch
/// brighter along the top, like light catching a lip of glass.
struct PanelChrome: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
        content
            .background {
                ZStack {
                    VisualEffect(material: .popover)
                    Theme.panel.opacity(Theme.panelOpacity)
                }
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: colorScheme == .dark
                            ? [.white.opacity(0.18), .white.opacity(0.06)]
                            : [.black.opacity(0.10), .black.opacity(0.14)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.5
                )
            }
    }
}

extension View {
    func panelChrome() -> some View { modifier(PanelChrome()) }
}

/// A quiet icon button for the popover's toolbar: a soft rounded highlight on hover that deepens
/// when pressed, with the glyph dipping slightly as you click.
struct ToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ToolbarButton(configuration: configuration)
    }

    private struct ToolbarButton: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering && isEnabled ? .primary : .secondary)
                .frame(minWidth: 26, minHeight: 26)
                .padding(.horizontal, 2)
                .background {
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.08 : 0))
                }
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .contentShape(Rectangle())
                .onHover { inside in
                    withAnimation(Theme.Motion.hover) { hovering = inside }
                }
                .animation(Theme.Motion.hover, value: configuration.isPressed)
                .opacity(isEnabled ? 1 : 0.4)
        }
    }
}

/// The main call to action: filled with the lamp colour, with a gentle lift on hover. `compact`
/// matches a standard push button's height, for sheets.
struct LampButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        LampButton(configuration: configuration, compact: compact)
    }

    private struct LampButton: View {
        let configuration: Configuration
        let compact: Bool
        @State private var hovering = false
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: compact ? 12 : 13, weight: .semibold))
                .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                .padding(.horizontal, compact ? 12 : Theme.Space.l)
                .padding(.vertical, compact ? 4 : 7)
                .background {
                    Capsule(style: .continuous)
                        .fill(Theme.lamp)
                        .brightness(configuration.isPressed ? -0.08 : hovering && isEnabled ? 0.04 : 0)
                        .shadow(color: Theme.lamp.opacity(hovering && isEnabled ? 0.45 : 0.2), radius: hovering && isEnabled ? 8 : 4, y: 1)
                }
                .opacity(isEnabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .onHover { inside in
                    withAnimation(Theme.Motion.hover) { hovering = inside }
                }
                .animation(Theme.Motion.hover, value: configuration.isPressed)
                .animation(Theme.Motion.hover, value: isEnabled)
        }
    }
}

/// The quiet partner to the lamp button, such as Cancel beside it: the same capsule and size on a
/// soft fill, so the pair reads as one set.
struct QuietButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        QuietButton(configuration: configuration, compact: compact)
    }

    private struct QuietButton: View {
        let configuration: Configuration
        let compact: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: compact ? 12 : 13, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, compact ? 12 : Theme.Space.l)
                .padding(.vertical, compact ? 4 : 7)
                .background {
                    Capsule(style: .continuous)
                        .fill(.primary.opacity(configuration.isPressed ? 0.16 : hovering && isEnabled ? 0.12 : 0.08))
                }
                .opacity(isEnabled ? 1 : 0.5)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .onHover { inside in
                    withAnimation(Theme.Motion.hover) { hovering = inside }
                }
                .animation(Theme.Motion.hover, value: configuration.isPressed)
        }
    }
}

/// A small spinning arc in the current foreground colour, for buttons that are working.
struct Spinner: View {
    var size: CGFloat = 11
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(.foreground, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { spinning = true }
            }
            .accessibilityLabel("Working")
    }
}

/// A one pixel rule, lighter than Divider, for separating the popover's sections.
struct Hairline: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 1 / displayScale)
            .accessibilityHidden(true)
    }
}
