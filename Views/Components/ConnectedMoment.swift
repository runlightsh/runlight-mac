import SwiftUI

/// A beat of confirmation: the lamp brightens, a check draws in, and the count of sites found.
struct ConnectedMoment: View {
    let state: ConnectionState
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            ZStack {
                Circle()
                    .fill(Theme.lamp.opacity(0.14))
                    .frame(width: 56, height: 56)
                    .scaleEffect(drawn ? 1 : 0.6)
                Circle()
                    .fill(Theme.lamp.opacity(0.08))
                    .frame(width: 80, height: 80)
                    .scaleEffect(drawn ? 1 : 0.4)
                    .opacity(drawn ? 1 : 0)
                Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.lamp)
                    .scaleEffect(drawn ? 1 : 0.3)
                    .opacity(drawn ? 1 : 0)
            }
            .frame(height: 80)
            VStack(spacing: 3) {
                Text("Connected")
                    .font(.system(size: 15, weight: .semibold))
                Text("\(state.sites.count) \(state.sites.count == 1 ? "site" : "sites") on \(state.connection.name)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .opacity(drawn ? 1 : 0)
            .offset(y: drawn ? 0 : 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.xxl)
        .onAppear {
            withAnimation(reduceMotion ? .none : .spring(response: 0.45, dampingFraction: 0.62)) { drawn = true }
        }
        .accessibilityElement(children: .combine)
    }
}
