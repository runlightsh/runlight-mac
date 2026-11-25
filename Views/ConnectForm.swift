import SwiftUI

/// The address and token form, in the popover on first launch and in a sheet in Settings.
/// Return moves from the address to the token and then connects.
struct ConnectForm: View {
    enum Style { case popover, sheet }

    var style: Style = .popover
    var onConnected: (ConnectionState) -> Void = { _ in }
    var onCancel: (() -> Void)?

    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var address = ""
    @State private var token = ""
    @State private var step: ConnectStep?
    @State private var error: ConnectError?
    @State private var shake: CGFloat = 0
    @FocusState private var addressFocused: Bool
    @FocusState private var tokenFocused: Bool

    static let tokenHelp = URL(string: "https://runlight.sh/docs/api/")!

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            RunlightField(
                label: "Address",
                placeholder: "analytics.example.com",
                text: $address,
                error: error?.field == .address ? error?.message : nil,
                focused: $addressFocused,
                onSubmit: { tokenFocused = true }
            )
            RunlightField(
                label: "Read-only token",
                placeholder: "rl_…",
                text: $token,
                secure: true,
                error: error?.field == .token ? error?.message : nil,
                focused: $tokenFocused,
                onSubmit: connect
            )

            HStack(spacing: Theme.Space.s) {
                if style == .popover {
                    Button {
                        openURL(Self.tokenHelp)
                    } label: {
                        Label("Making a read-only token", systemImage: "arrow.up.right")
                            .labelStyle(TrailingIconLabelStyle())
                    }
                    .buttonStyle(LinkButtonStyle())
                }
                Spacer()
                if let onCancel {
                    Button("Cancel", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                        .disabled(step != nil)
                }
                Button(action: connect) {
                    HStack(spacing: 6) {
                        if step != nil {
                            Spinner()
                                .transition(.opacity.combined(with: .scale))
                        }
                        Text(step?.label ?? "Connect")
                            .contentTransition(.opacity)
                    }
                    .frame(minWidth: 84)
                }
                .buttonStyle(LampButtonStyle(compact: style == .sheet))
                .keyboardShortcut(.defaultAction)
                .disabled(step != nil)
            }
            .padding(.top, Theme.Space.xs)
            .animation(Theme.Motion.push, value: step)
        }
        .modifier(Shake(animatableData: shake))
        .animation(Theme.Motion.push, value: error)
        .onAppear { addressFocused = true }
        .onChange(of: address) { if error?.field == .address { error = nil } }
        .onChange(of: token) { if error?.field == .token { error = nil } }
    }

    private func connect() {
        guard step == nil else { return }
        error = nil
        Task { @MainActor in
            do throws(ConnectError) {
                let state = try await model.connect(address: address, token: token) { step in
                    withAnimation(Theme.Motion.push) { self.step = step }
                }
                step = nil
                onConnected(state)
            } catch {
                step = nil
                withAnimation(Theme.Motion.push) { self.error = error }
                if !reduceMotion {
                    shake = 0
                    withAnimation(.easeOut(duration: 0.38)) { shake = 1 }
                }
                if error.field == .address { addressFocused = true } else { tokenFocused = true }
            }
        }
    }
}

/// Text that reads as a link: secondary until hovered, then the lamp colour, underlined.
struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Hovering { hovering in
            configuration.label
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovering ? AnyShapeStyle(Theme.lamp) : AnyShapeStyle(.secondary))
                .opacity(configuration.isPressed ? 0.7 : 1)
        }
    }
}

/// A label with its icon after the text, for links that leave the app.
struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.title
            configuration.icon.font(.system(size: 8, weight: .bold))
        }
    }
}

/// Tracks the pointer over its content and hands the state to it, animated.
struct Hovering<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content
    @State private var hovering = false

    var body: some View {
        content(hovering)
            .contentShape(Rectangle())
            .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
    }
}
