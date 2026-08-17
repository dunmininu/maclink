import SwiftUI

/// First-run setup on the Mac.
///
/// This exists for one reason: MacLink Host is a menu bar app with no window, and it does nothing at
/// all until macOS grants it Accessibility. Without this window the first-run experience is an app
/// that appears to have not launched. The permission row watches the real trust state and flips to
/// "Ready" on its own, so nobody has to come back and confirm anything.
struct WelcomeView: View {
    @Bindable var coordinator: HostCoordinator
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            VStack(alignment: .leading, spacing: 18) {
                permissionCard
                readyCard
            }
            .padding(24)

            Divider()

            HStack {
                Toggle("Start at login", isOn: $coordinator.launchesAtLogin)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                Spacer()
                Button(coordinator.accessibilityGranted ? "Done" : "Close", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 460)
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "cursorarrow.motionlines")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.white)
                .frame(width: 84, height: 84)
                .background(
                    LinearGradient(
                        colors: [Color(red: 0.26, green: 0.29, blue: 0.55), Color(red: 0.45, green: 0.32, blue: 0.72)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )

            VStack(spacing: 5) {
                Text("MacLink Host is running")
                    .font(.title2.weight(.semibold))
                Text("Look for the pointer icon in your menu bar. There is no Dock icon — this app lives up there.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)
        }
        .padding(.top, 28)
        .padding(.bottom, 6)
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: coordinator.accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(coordinator.accessibilityGranted ? .green : .orange)
                Text(coordinator.accessibilityGranted ? "Accessibility granted" : "Accessibility permission needed")
                    .font(.headline)
                Spacer()
            }

            if coordinator.accessibilityGranted {
                Text("Your iPhone can move the pointer and type on this Mac.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("macOS blocks apps from moving the pointer or typing until you allow it. Until this is on, your iPhone will connect but nothing will move.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 7) {
                    step(1, "Click the button below to open Privacy & Security.")
                    step(2, "Find **MacLink Host** in the list.")
                    step(3, "Switch it on.")
                }
                .padding(.top, 2)

                HStack(spacing: 10) {
                    Button("Open Accessibility Settings") {
                        coordinator.openAccessibilitySettings()
                    }
                    .buttonStyle(.borderedProminent)

                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Waiting…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)

                if CodeSigningInfo.isAdHocSigned {
                    staleGrantNote
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (coordinator.accessibilityGranted ? Color.green : Color.orange).opacity(0.10),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    /// The "but I already switched it on" case. Worth calling out explicitly, because System Settings
    /// shows the row as enabled and gives no hint that the grant no longer matches this binary.
    private var staleGrantNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Already switched it on?", systemImage: "arrow.triangle.2.circlepath")
                .font(.subheadline.weight(.semibold))
            Text("This build is ad-hoc signed, and macOS ties the permission to the app's signature. Rebuilding changes that signature, so the switch still looks on but no longer applies. **Toggle MacLink Host off and back on** in the list to re-grant it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Setting a signing team on the MacLinkHost target makes the grant stick permanently.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
        .padding(.top, 2)
    }

    private var readyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .foregroundStyle(.tint)
                Text("Now open MacLink on your iPhone")
                    .font(.headline)
            }

            Text("This Mac appears as **\(coordinator.hostName)**. The app will show a 6-digit code to type — that is all the setup there is.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let interface = CurrentNetwork.primaryInterface() {
                Text("On \(interface.address) (\(interface.name)). Keep your iPhone nearby or on the same Wi-Fi.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func step(_ index: Int, _ markdown: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text("\(index)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 17, height: 17)
                .background(Color.accentColor, in: Circle())
            Text(.init(markdown))
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
