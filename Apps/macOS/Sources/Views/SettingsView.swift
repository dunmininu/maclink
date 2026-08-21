import SwiftUI

struct SettingsView: View {
    @Bindable var coordinator: HostCoordinator

    var body: some View {
        TabView {
            GeneralSettings(coordinator: coordinator)
                .tabItem { Label("General", systemImage: "gearshape") }
            DeviceSettings(coordinator: coordinator)
                .tabItem { Label("Devices", systemImage: "iphone") }
            ActivityLog(coordinator: coordinator)
                .tabItem { Label("Activity", systemImage: "list.bullet.rectangle") }
        }
        .frame(width: 460, height: 380)
    }
}

private struct GeneralSettings: View {
    @Bindable var coordinator: HostCoordinator

    var body: some View {
        Form {
            Section {
                TextField("Mac name", text: $coordinator.hostName)
                Text("This is the name your iPhone shows in its list of Macs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Start MacLink Host at login", isOn: $coordinator.launchesAtLogin)
                Toggle("Allow new devices to pair", isOn: $coordinator.acceptsNewPairings)
                Toggle("Share clipboard automatically", isOn: $coordinator.syncsClipboardAutomatically)
                    .disabled(!HostCoordinator.automaticClipboardSharingAvailable)
                Text(HostCoordinator.automaticClipboardSharingAvailable
                     ? "Anything you copy on this Mac is sent to the connected phone — except passwords, and except anything that arrived from another device."
                     : "Turned off: macOS Universal Clipboard already copies between your own devices, and a second thing polling the clipboard gets in its way. Use Copy to Phone in the app when you want to send something deliberately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permission") {
                LabeledContent("Accessibility") {
                    HStack(spacing: 8) {
                        Image(systemName: coordinator.accessibilityGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(coordinator.accessibilityGranted ? .green : .orange)
                        Text(coordinator.accessibilityGranted ? "Granted" : "Not granted")
                        if !coordinator.accessibilityGranted {
                            Button("Open Settings") { coordinator.openAccessibilitySettings() }
                                .controlSize(.small)
                        }
                    }
                }
            }

            Section("Network") {
                if let interface = CurrentNetwork.primaryInterface() {
                    LabeledContent("Address", value: "\(interface.address) (\(interface.name))")
                } else {
                    LabeledContent("Address", value: "Not on a network")
                }
                Text("MacLink only works while your iPhone and this Mac are on the same network. It never routes over the internet or a direct radio link.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct DeviceSettings: View {
    @Bindable var coordinator: HostCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if coordinator.pairedDevices.isEmpty {
                ContentUnavailableView(
                    "No paired devices",
                    systemImage: "iphone.slash",
                    description: Text("Open MacLink on your iPhone and choose this Mac to pair.")
                )
            } else {
                List {
                    ForEach(coordinator.pairedDevices) { device in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                Text(subtitle(for: device))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if coordinator.connectedDevices.contains(where: { $0.id == device.id }) {
                                Text("Connected")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.green)
                            }
                            Button("Revoke") { coordinator.revoke(device) }
                                .controlSize(.small)
                        }
                        .padding(.vertical, 2)
                    }
                }

                HStack {
                    Spacer()
                    Button("Revoke All", role: .destructive) { coordinator.revokeAll() }
                        .controlSize(.small)
                }
                .padding(12)
            }
        }
    }

    private func subtitle(for device: PairedDevice) -> String {
        let paired = device.pairedAt.formatted(date: .abbreviated, time: .shortened)
        guard let lastSeen = device.lastSeen else { return "Paired \(paired)" }
        return "Paired \(paired) · Last seen \(lastSeen.formatted(date: .abbreviated, time: .shortened))"
    }
}

private struct ActivityLog: View {
    @Bindable var coordinator: HostCoordinator

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(coordinator.log.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .onChange(of: coordinator.log.count) { _, count in
                guard count > 0 else { return }
                proxy.scrollTo(count - 1, anchor: .bottom)
            }
        }
    }
}
