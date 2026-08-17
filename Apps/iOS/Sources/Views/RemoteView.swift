import MacLinkKit
import SwiftUI

struct RemoteView: View {
    @Environment(RemoteSession.self) private var session
    @State private var selection = Tab.trackpad

    enum Tab: Hashable {
        case trackpad, keyboard, media, more
    }

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack { TrackpadPane() }
                .tabItem { Label("Trackpad", systemImage: "rectangle.and.hand.point.up.left") }
                .tag(Tab.trackpad)

            NavigationStack { KeyboardPane() }
                .tabItem { Label("Keys", systemImage: "keyboard") }
                .tag(Tab.keyboard)

            NavigationStack { MediaPane() }
                .tabItem { Label("Media", systemImage: "play.circle") }
                .tag(Tab.media)

            NavigationStack { MorePane() }
                .tabItem { Label("More", systemImage: "square.grid.2x2") }
                .tag(Tab.more)
        }
    }
}

/// Shared header showing which Mac is being driven, plus battery and the frontmost app.
struct HostStatusBar: View {
    @Environment(RemoteSession.self) private var session

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "laptopcomputer")
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 1) {
                Text(session.status?.hostName ?? session.connectedHost?.name ?? "Mac")
                    .font(.subheadline.weight(.semibold))
                if let app = session.status?.frontmostApp {
                    Text(app)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let level = session.status?.batteryLevel {
                Label {
                    Text("\(Int((level * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                } icon: {
                    Image(systemName: batterySymbol(level: level, charging: session.status?.isCharging ?? false))
                }
                .foregroundStyle(level < 0.2 && !(session.status?.isCharging ?? false) ? .red : .secondary)
            }

            Button {
                session.disconnect()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .accessibilityLabel("Disconnect")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func batterySymbol(level: Double, charging: Bool) -> String {
        if charging { return "battery.100.bolt" }
        switch level {
        case ..<0.15: return "battery.0"
        case ..<0.35: return "battery.25"
        case ..<0.6: return "battery.50"
        case ..<0.85: return "battery.75"
        default: return "battery.100"
        }
    }
}

/// A chunky, repeat-friendly button used across the control panes.
struct CommandButton: View {
    let title: String
    let systemImage: String
    var tint: Color = .accentColor
    var isProminent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .medium))
                Text(title)
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 74)
            .background(
                isProminent ? AnyShapeStyle(tint.opacity(0.16)) : AnyShapeStyle(.quaternary),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .foregroundStyle(isProminent ? tint : .primary)
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}
