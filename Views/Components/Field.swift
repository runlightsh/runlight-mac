import SwiftUI

/// A labelled text field in Runlight's style: a soft well that brightens its edge in the lamp colour
/// when focused, turns red with the message beneath it when something's wrong, and can hide what's
/// typed with an eye button to peek.
struct RunlightField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var secure = false
    var error: String?
    var focused: FocusState<Bool>.Binding
    var onSubmit: () -> Void = {}

    @State private var revealed = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Group {
                    if secure && !revealed {
                        SecureField(placeholder, text: $text)
                    } else {
                        TextField(placeholder, text: $text)
                    }
                }
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: secure && revealed ? .monospaced : .default))
                .focused(focused)
                .onSubmit(onSubmit)
                .autocorrectionDisabled()

                if secure && !text.isEmpty {
                    Button {
                        revealed.toggle()
                        focused.wrappedValue = true
                    } label: {
                        Image(systemName: revealed ? "eye.slash" : "eye")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(revealed ? "Hide token" : "Show token")
                    .accessibilityLabel(revealed ? "Hide token" : "Show token")
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.primary.opacity(hovering || focused.wrappedValue ? 0.06 : 0.045))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: focused.wrappedValue || error != nil ? 1.5 : 0.5)
            }
            .shadow(color: ringColor, radius: 3)
            .onHover { hovering = $0 }
            .animation(Theme.Motion.hover, value: focused.wrappedValue)
            .animation(Theme.Motion.hover, value: error)
            .animation(Theme.Motion.hover, value: text.isEmpty)

            if let error {
                Label {
                    Text(error).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.circle.fill")
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.down)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .accessibilityLabel("\(label): \(error)")
            }
        }
    }

    private var borderColor: Color {
        if error != nil { return Theme.down.opacity(0.8) }
        if focused.wrappedValue { return Theme.lamp.opacity(0.85) }
        return .primary.opacity(0.14)
    }

    private var ringColor: Color {
        if error != nil { return Theme.down.opacity(0.25) }
        return focused.wrappedValue ? Theme.lamp.opacity(0.3) : .clear
    }
}

/// A horizontal shake, for a form that didn't go through. Settles in about a third of a second.
struct Shake: GeometryEffect {
    var travel: CGFloat = 6
    var shakes: CGFloat = 3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: travel * sin(animatableData * .pi * shakes * 2) * (1 - min(animatableData, 1)), y: 0))
    }
}

// MARK: Sheets

/// The frame every sheet shares: an icon tile, a title, a line of explanation, then the form, which
/// ends with a SheetFooter of buttons on a band across the bottom.
struct SheetFrame<Content: View>: View {
    let title: String
    var symbol: String?
    var width: CGFloat = 440
    let detail: String
    @ViewBuilder let content: Content

    static var padding: CGFloat { Theme.Space.xl }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                if let symbol {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.primary.opacity(0.06))
                        .frame(width: 38, height: 38)
                        .overlay {
                            Image(systemName: symbol)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .lineSpacing(1.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .padding(Self.padding)
        .frame(width: width)
        // Solid, not the see-through sheet material that takes on the colours behind it.
        .background(Theme.panel)
        .presentationBackground(Theme.panel)
    }
}

/// The buttons at the foot of a sheet, on a band that runs to the sheet's edges under a hairline.
struct SheetFooter<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: Theme.Space.s) { content }
            .padding(.horizontal, SheetFrame<EmptyView>.padding)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(.primary.opacity(0.035))
            .overlay(alignment: .top) { Hairline() }
            .padding(.horizontal, -SheetFrame<EmptyView>.padding)
            .padding(.bottom, -SheetFrame<EmptyView>.padding)
            .padding(.top, 4)
    }
}
