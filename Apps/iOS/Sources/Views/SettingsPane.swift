import SwiftUI

struct SettingsPane: View {
    @Environment(RemoteSession.self) private var session
    @Environment(Preferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            Section("Trackpad") {
                LabeledContent("Speed") {
                    Text(String(format: "%.1f×", preferences.sensitivity))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $preferences.sensitivity, in: 0.4...3.0, step: 0.1)

                LabeledContent("Scrolling") {
                    Text(String(format: "%.1f×", preferences.scrollSpeed))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $preferences.scrollSpeed, in: 0.3...3.0, step: 0.1)

                Toggle("Natural scrolling", isOn: $preferences.naturalScrolling)
                Toggle("Tap to click", isOn: $preferences.tapToClick)
                Toggle("Haptic feedback", isOn: $preferences.hapticsEnabled)
            }

            Section {
                Toggle("Keep screen awake", isOn: $preferences.keepScreenAwake)
            } footer: {
                Text("Stops the iPhone locking while you are using it as a trackpad.")
            }

            Section {
                TextField("iPhone name", text: $preferences.deviceName)
            } header: {
                Text("This device")
            } footer: {
                Text("This is the name your Mac shows when you pair. Reconnect for a change to take effect.")
            }

            if let host = session.connectedHost {
                Section("Connected Mac") {
                    LabeledContent("Name", value: host.name)
                    if let status = session.status {
                        LabeledContent("Accessibility", value: status.accessibilityGranted ? "Granted" : "Not granted")
                    }
                    Button("Disconnect") { session.disconnect() }
                    Button("Forget this Mac", role: .destructive) {
                        session.forgetPairing(for: host.id)
                    }
                }
            }

            Section {
                Text("MacLink reaches your Mac over your Wi-Fi, or over a direct link when the two devices are near each other — the same kind of connection AirDrop uses. It never uses the internet, iCloud, or any server in between, and cellular is excluded outright.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("How it connects")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}
