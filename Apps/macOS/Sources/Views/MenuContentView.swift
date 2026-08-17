import MacLinkKit
import SwiftUI

/// The menu bar popover: status, who is connected, and the two things that go wrong most often
/// (missing Accessibility permission, and not being on the same network).
struct MenuContentView: View {
    @Bindable var coordinator: HostCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if !coordinator.accessibilityGranted {
                accessibilityBanner
            }

            if case .failed(let message) = coordinator.serverState {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            connections

            Divider()

            Toggle("Allow new devices to pair", isOn: $coordinator.acceptsNewPairings)
            Toggle("Share clipboard automatically", isOn: $coordinator.syncsClipboardAutomatically)

            Divider()

            HStack {
                Button("Setup Guide…") { coordinator.onShowWelcome?() }
                SettingsLink {
                    Text("Settings…")
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(16)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "cursorarrow.motionlines")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(coordinator.hostName)
                    .font(.headline)
                Text(coordinator.statusSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(indicatorColor)
                .frame(width: 9, height: 9)
        }
    }

    private var indicatorColor: Color {
        if !coordinator.accessibilityGranted { return .orange }
        switch coordinator.serverState {
        case .running: return coordinator.connectedDevices.isEmpty ? .secondary : .green
        case .failed: return .red
        default: return .secondary
        }
    }

    private var accessibilityBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Accessibility permission needed", systemImage: "lock.shield")
                .font(.callout.weight(.semibold))
            Text("macOS blocks apps from moving the pointer or typing until you allow it. Nothing will respond on your phone until this is on.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Accessibility Settings") {
                coordinator.openAccessibilitySettings()
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var connections: some View {
        if coordinator.connectedDevices.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("No phone connected")
                    .font(.callout.weight(.medium))
                Text("Open MacLink on your iPhone while it is on the same Wi-Fi network as this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let interface = CurrentNetwork.primaryInterface() {
                    Text("This Mac is on \(interface.address) (\(interface.name))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(coordinator.connectedDevices) { device in
                    Label(device.name, systemImage: "iphone")
                        .font(.callout)
                }
            }
        }
    }
}
