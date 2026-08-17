import MacLinkKit
import SwiftUI

struct TrackpadPane: View {
    @Environment(RemoteSession.self) private var session
    @Environment(Preferences.self) private var preferences
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// Landscape on iPhone. Vertical room is scarce, so the chrome shrinks and the hint goes away —
    /// the trackpad itself should get almost all of it.
    private var isLandscape: Bool { verticalSizeClass == .compact }

    var body: some View {
        VStack(spacing: 0) {
            if !isLandscape {
                HostStatusBar()
            }

            TrackpadSurface()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary.opacity(0.4))
                .overlay(alignment: .center) {
                    if !isLandscape { hint }
                }
                .clipShape(RoundedRectangle(cornerRadius: isLandscape ? 12 : 18))
                .padding(isLandscape ? 6 : 12)

            buttons
                .padding(.horizontal, isLandscape ? 6 : 12)
                .padding(.bottom, isLandscape ? 6 : 12)
        }
        .navigationBarHidden(true)
    }

    private var hint: some View {
        VStack(spacing: 6) {
            Image(systemName: "hand.draw")
                .font(.system(size: 26, weight: .light))
            Text("Drag to move · Tap to click\nTwo fingers to scroll · Pinch to zoom\nThree fingers for spaces")
                .font(.caption2)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.tertiary)
        .allowsHitTesting(false)
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            MouseButtonView(label: "Left", button: .left)
            MouseButtonView(label: "Middle", button: .middle)
                .frame(maxWidth: 90)
            MouseButtonView(label: "Right", button: .right)
        }
        .frame(height: isLandscape ? 40 : 54)
    }
}

/// A physical-feeling button that presses and releases with the finger, so drag-select works.
private struct MouseButtonView: View {
    @Environment(RemoteSession.self) private var session
    @Environment(Preferences.self) private var preferences

    let label: String
    let button: MouseButton
    @State private var isDown = false

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(isDown ? AnyShapeStyle(Color.accentColor.opacity(0.25)) : AnyShapeStyle(.quaternary))
            .overlay {
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isDown else { return }
                        isDown = true
                        if preferences.hapticsEnabled {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                        session.send(.button(button: button, action: .down, clickCount: 1))
                    }
                    .onEnded { _ in
                        guard isDown else { return }
                        isDown = false
                        session.send(.button(button: button, action: .up, clickCount: 1))
                    }
            )
            .animation(.easeOut(duration: 0.08), value: isDown)
    }
}

/// Bridges the UIKit multi-touch surface into SwiftUI.
struct TrackpadSurface: UIViewRepresentable {
    @Environment(RemoteSession.self) private var session
    @Environment(Preferences.self) private var preferences

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeUIView(context: Context) -> TrackpadTouchView {
        let view = TrackpadTouchView()
        view.delegate = context.coordinator
        apply(preferences, to: view)
        view.desktopWidth = session.status?.displayWidth ?? 0
        return view
    }

    func updateUIView(_ view: TrackpadTouchView, context: Context) {
        context.coordinator.session = session
        apply(preferences, to: view)
        view.desktopWidth = session.status?.displayWidth ?? 0
    }

    private func apply(_ preferences: Preferences, to view: TrackpadTouchView) {
        view.sensitivity = preferences.sensitivity
        view.scrollSpeed = preferences.scrollSpeed
        view.naturalScrolling = preferences.naturalScrolling
        view.tapToClick = preferences.tapToClick
        view.hapticsEnabled = preferences.hapticsEnabled
    }

    @MainActor
    final class Coordinator: TrackpadTouchViewDelegate {
        var session: RemoteSession

        init(session: RemoteSession) {
            self.session = session
        }

        func trackpad(_ view: TrackpadTouchView, didProduce event: PointerEvent) {
            session.send(event)
        }

        func trackpad(_ view: TrackpadTouchView, didSwipeThreeFingers direction: TrackpadTouchView.SwipeDirection) {
            // Matches the Mac's own three-finger gestures: swiping the content left moves you to
            // the space on the right.
            let command: SystemCommand
            switch direction {
            case .up: command = .missionControl
            case .down: command = .applicationWindows
            case .left: command = .spaceRight
            case .right: command = .spaceLeft
            }
            session.send(.system(command))
        }

        func trackpadDidClick(_ view: TrackpadTouchView, button: MouseButton) {}
    }
}
