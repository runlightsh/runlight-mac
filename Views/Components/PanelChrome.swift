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

/// Gives the popover its shape: the material, rounded corners, and a hairline edge that is a touch
/// brighter along the top, like light catching a lip of glass.
struct PanelChrome: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
        content
            .background(VisualEffect(material: .popover))
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

/// The popover's main call to action: filled with the lamp colour, with a gentle lift on hover.
struct LampButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LampButton(configuration: configuration)
    }

    private struct LampButton: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, 7)
                .background {
                    Capsule(style: .continuous)
                        .fill(Theme.lamp)
                        .brightness(configuration.isPressed ? -0.08 : hovering ? 0.04 : 0)
                        .shadow(color: Theme.lamp.opacity(hovering ? 0.45 : 0.2), radius: hovering ? 8 : 4, y: 1)
                }
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .onHover { inside in
                    withAnimation(Theme.Motion.hover) { hovering = inside }
                }
                .animation(Theme.Motion.hover, value: configuration.isPressed)
        }
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
