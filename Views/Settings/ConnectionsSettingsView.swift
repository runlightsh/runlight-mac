import SwiftUI

/// Settings, Connections: every install, how it's doing, and the ways to fix or remove it.
struct ConnectionsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var replacing: ConnectionState?
    @State private var removing: ConnectionState?

    var body: some View {
        Group {
            if model.isEmpty {
                VStack(spacing: Theme.Space.s) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.tertiary)
                        .padding(.bottom, Theme.Space.xs)
                    Text("No connections yet")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Connect a Runlight install with its address and a read-only token.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                    Button("Add Connection…") { model.addingConnection = true }
                        .buttonStyle(LampButtonStyle(compact: true))
                        .padding(.top, Theme.Space.s)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, Theme.Space.xxl)
            } else {
                Form {
                    ForEach(model.connections) { state in
                        Section {
                            ConnectionRow(state: state, replace: { replacing = state }, remove: { removing = state })
                        }
                    }
                }
                .formStyle(.grouped)
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        Spacer()
                        Button("Add Connection…") { model.addingConnection = true }
                    }
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.bottom, Theme.Space.l)
                }
            }
        }
        .frame(width: SettingsLayout.paneSize.width, height: SettingsLayout.paneSize.height)
        .sheet(isPresented: Binding(get: { model.addingConnection }, set: { model.addingConnection = $0 })) {
            AddConnectionSheet(done: { model.addingConnection = false })
        }
        .sheet(item: $replacing) { state in
            SheetFrame(title: "Replace Token", symbol: "key", detail: "Paste a new read-only token for \(state.connection.name). The current one stays until the new one works.") {
                ReplaceTokenForm(state: state, done: { replacing = nil })
            }
        }
        .confirmationDialog(
            removing.map { "Remove \($0.connection.name)?" } ?? "",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { state in
            Button("Remove \(state.connection.name)", role: .destructive) {
                withAnimation(Theme.Motion.push) { model.remove(state.id) }
            }
        } message: { state in
            Text("Its \(state.sites.count) \(state.sites.count == 1 ? "site leaves" : "sites leave") Runlight for Mac, and its token is removed from the Keychain. The token keeps working on the install until you delete it there.")
        }
    }
}

private struct ConnectionRow: View {
    let state: ConnectionState
    let replace: () -> Void
    let remove: () -> Void

    @Environment(AppModel.self) private var model
    @State private var testedOK = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                RunlightMark(size: 28, lit: state.status.isOK)
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.connection.name)
                        .font(.system(size: 13, weight: .semibold))
                    Text(details)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(status: state.status, testedOK: testedOK)
            }
            if case .problem(let message) = state.status {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.down)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Theme.Space.s) {
                Button {
                    Task {
                        await model.test(state.id)
                        if model.connections.first(where: { $0.id == state.id })?.status == .ok {
                            withAnimation(Theme.Motion.push) { testedOK = true }
                            try? await Task.sleep(for: .seconds(2))
                            withAnimation(Theme.Motion.push) { testedOK = false }
                        }
                    }
                } label: {
                    Text("Test")
                }
                .disabled(state.status == .checking)
                Button("Replace Token…", action: replace)
                Spacer()
                Button("Remove…", role: .destructive, action: remove)
            }
            .controlSize(.small)
        }
        .padding(.vertical, Theme.Space.xs)
    }

    private var details: String {
        var parts = ["Runlight \(state.connection.version)", "\(state.sites.count) \(state.sites.count == 1 ? "site" : "sites")"]
        if let token = state.token {
            parts.append(token.scope == .read ? "read-only token" : "\(token.scope.rawValue) token")
        }
        return parts.joined(separator: " · ")
    }
}

/// Connected, checking, or what's wrong, as a small coloured capsule.
private struct StatusPill: View {
    let status: ConnectionStatus
    let testedOK: Bool

    var body: some View {
        HStack(spacing: 5) {
            if status == .checking {
                Spinner(size: 8)
            } else {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
                    .shadow(color: tint.opacity(status.isOK ? 0.6 : 0), radius: 3)
            }
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .contentTransition(.opacity)
        }
        .foregroundStyle(status == .checking ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.12)))
        .animation(Theme.Motion.push, value: status)
        .animation(Theme.Motion.push, value: testedOK)
        .accessibilityElement(children: .combine)
    }

    private var label: String {
        switch status {
        case .ok: testedOK ? "Working" : "Connected"
        case .checking: "Checking"
        case .tokenRejected: "Token rejected"
        case .tokenMissing: "Token missing"
        case .offline: "Offline"
        case .problem: "Unreachable"
        }
    }

    private var tint: Color {
        switch status {
        case .ok: Theme.up
        case .checking, .offline: .secondary
        case .tokenRejected, .tokenMissing, .problem: Theme.down
        }
    }
}

/// A new token for an existing connection, checked before it replaces the old one.
private struct ReplaceTokenForm: View {
    let state: ConnectionState
    let done: () -> Void

    @Environment(AppModel.self) private var model
    @State private var token = ""
    @State private var error: String?
    @State private var working = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            RunlightField(label: "Read-only token", placeholder: "rl_…", text: $token, secure: true, error: error, focused: $focused, onSubmit: save)
            SheetFooter {
                Spacer()
                Button("Cancel", action: done)
                    .buttonStyle(QuietButtonStyle(compact: true))
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
                Button(action: save) {
                    HStack(spacing: 6) {
                        if working { Spinner() }
                        Text(working ? "Checking…" : "Replace")
                    }
                }
                .buttonStyle(LampButtonStyle(compact: true))
                .keyboardShortcut(.defaultAction)
                .disabled(working)
            }
        }
        .animation(Theme.Motion.push, value: error)
        .onAppear { focused = true }
        .onChange(of: token) { error = nil }
    }

    private func save() {
        guard !working else { return }
        working = true
        Task {
            do throws(ConnectError) {
                try await model.replaceToken(state.id, with: token)
                done()
            } catch {
                self.error = error.message
                focused = true
            }
            working = false
        }
    }
}

/// The Add Connection sheet: the form, then a beat of confirmation before it closes.
private struct AddConnectionSheet: View {
    let done: () -> Void
    @State private var connected: ConnectionState?

    var body: some View {
        Group {
            if let connected {
                ConnectedMoment(state: connected)
                    .frame(width: 420)
                    .background(Theme.panel)
                    .presentationBackground(Theme.panel)
                    .task {
                        try? await Task.sleep(for: .seconds(1.4))
                        done()
                    }
            } else {
                SheetFrame(title: "Add a Runlight Connection", symbol: "point.3.connected.trianglepath.dotted", detail: "Enter an install's address and a read-only token from its Settings, MCP & API.") {
                    ConnectForm(onConnected: { state in withAnimation(Theme.Motion.push) { connected = state } }, onCancel: done)
                }
            }
        }
        .transition(.opacity)
    }
}

