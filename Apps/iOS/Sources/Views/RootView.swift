import MacLinkKit
import SwiftUI

struct RootView: View {
    @Environment(RemoteSession.self) private var session
    @Environment(Preferences.self) private var preferences

    var body: some View {
        Group {
            if !preferences.hasCompletedOnboarding {
                OnboardingView()
            } else if session.isConnected {
                RemoteView()
            } else {
                ConnectView()
            }
        }
        .animation(.snappy, value: session.isConnected)
        .animation(.snappy, value: preferences.hasCompletedOnboarding)
        // The wizard collects the code inline, so the sheet is only for re-pairing later on.
        .sheet(isPresented: Binding(
            get: { preferences.hasCompletedOnboarding && session.isAwaitingPairingCode },
            // Any dismissal route has to unblock the handshake's continuation, not just the
            // Cancel button, or the connection attempt would hang until it times out.
            set: { if !$0 { session.cancelPairing() } }
        )) {
            PairingSheet()
                .interactiveDismissDisabled()
        }
        .overlay(alignment: .top) {
            if let notice = session.notice {
                NoticeBanner(notice: notice) { session.dismissNotice() }
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: session.notice)
        .onAppear {
            preferences.applyIdleTimer()
            session.start()
        }
    }
}

struct NoticeBanner: View {
    let notice: Notice
    let onDismiss: () -> Void

    private var tint: Color {
        switch notice.level {
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }

    private var symbol: String {
        switch notice.level {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(notice.message)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(tint.opacity(0.35)))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }
}
