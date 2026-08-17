import MacLinkKit
import SwiftUI

/// The list of Macs visible on the current network.
struct ConnectView: View {
    @Environment(RemoteSession.self) private var session
    @Environment(Preferences.self) private var preferences
    @State private var isShowingSettings = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if session.hosts.isEmpty {
                        searchingRow
                    } else {
                        ForEach(session.hosts) { host in
                            hostRow(host)
                        }
                    }
                } header: {
                    Text("Macs nearby")
                } footer: {
                    Text("Your Mac appears here while MacLink Host is running in its menu bar and the two devices are on the same Wi-Fi, or simply close to each other.")
                }

                if let error = session.lastError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    NavigationLink {
                        SettingsPane()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .navigationTitle("MacLink")
            .toolbar {
                if session.isBusy {
                    ToolbarItem(placement: .topBarTrailing) {
                        ProgressView()
                    }
                }
            }
        }
    }

    private var searchingRow: some View {
        HStack(spacing: 12) {
            ProgressView()
            VStack(alignment: .leading, spacing: 2) {
                Text("Looking for your Mac…")
                Text("Make sure MacLink Host is running")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private func hostRow(_ host: DiscoveredHost) -> some View {
        Button {
            session.connect(to: host)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(host.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(host.isPaired ? "Paired" : "Tap to pair")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        }
        .disabled(session.isBusy)
        .swipeActions(edge: .trailing) {
            if host.isPaired {
                Button("Forget", role: .destructive) {
                    session.forgetPairing(for: host.id)
                }
            }
        }
    }
}
