import SwiftUI

@main
struct MacLinkApp: App {
    @State private var preferences: Preferences
    @State private var session: RemoteSession
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // One `Preferences` shared by both: declared without an initialiser so it is built exactly
        // once here, rather than constructed and immediately thrown away.
        let preferences = Preferences()
        _preferences = State(initialValue: preferences)
        _session = State(initialValue: RemoteSession(preferences: preferences))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(preferences)
                .environment(session)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        session.resume()
                    case .background:
                        // Holding a TCP connection open in the background just burns battery and
                        // gets killed anyway; reconnecting on return is fast.
                        session.stop()
                    default:
                        break
                    }
                }
        }
    }
}
