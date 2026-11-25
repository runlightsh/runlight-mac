import SwiftUI

/// Three small previews of the popover, one per appearance, like the system's own Appearance
/// setting. The chosen one gets an accent ring; the others lift slightly on hover.
struct AppearancePicker: View {
    @Binding var selection: AppAppearance

    var body: some View {
        HStack(spacing: Theme.Space.l) {
            ForEach(AppAppearance.allCases) { option in
                AppearanceOption(option: option, isSelected: option == selection) {
                    withAnimation(Theme.Motion.push) { selection = option }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Appearance")
    }
}

private struct AppearanceOption: View {
    let option: AppAppearance
    let isSelected: Bool
    let choose: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            VStack(spacing: Theme.Space.s - 2) {
                thumbnail
                    .frame(width: 76, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
                    }
                    .padding(3)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 2.5)
                            .opacity(isSelected ? 1 : 0)
                            .scaleEffect(isSelected ? 1 : 1.06)
                    }
                    .shadow(color: .black.opacity(hovering && !isSelected ? 0.12 : 0), radius: 4, y: 2)
                    .offset(y: hovering && !isSelected ? -1 : 0)
                Text(option.title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var thumbnail: some View {
        switch option {
        case .light: MiniPopover(dark: false)
        case .dark: MiniPopover(dark: true)
        case .system:
            ZStack {
                MiniPopover(dark: false)
                MiniPopover(dark: true)
                    .mask {
                        GeometryReader { proxy in
                            Path { path in
                                path.move(to: CGPoint(x: proxy.size.width, y: 0))
                                path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height))
                                path.addLine(to: CGPoint(x: 0, y: proxy.size.height))
                                path.closeSubpath()
                            }
                        }
                    }
            }
        }
    }
}

/// A sketch of the popover: a header, three site rows with their numbers, and a lit lamp.
private struct MiniPopover: View {
    let dark: Bool

    var body: some View {
        let paper = dark ? Color(white: 0.11) : Color(white: 0.96)
        let ink = dark ? Color.white : Color.black
        let lamp = dark ? Color(nsColor: NSColor(rgb: 0x4ADE80)) : Color(nsColor: NSColor(rgb: 0x16A34A))
        ZStack(alignment: .topLeading) {
            paper
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 1.5).fill(ink).frame(width: 7, height: 7)
                    Capsule().fill(ink.opacity(0.7)).frame(width: 20, height: 3)
                    Spacer()
                    Circle().fill(lamp).frame(width: 4, height: 4)
                }
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: 4) {
                        Circle().fill(ink.opacity(0.18)).frame(width: 5, height: 5)
                        Capsule().fill(ink.opacity(0.35)).frame(width: [26, 20, 30][row], height: 3)
                        Spacer()
                        Capsule().fill(row == 0 ? lamp : ink.opacity(0.5)).frame(width: [12, 9, 10][row], height: 3)
                    }
                }
            }
            .padding(7)
        }
    }
}

#Preview {
    @Previewable @State var selection = AppAppearance.system
    AppearancePicker(selection: $selection).padding(30)
}
