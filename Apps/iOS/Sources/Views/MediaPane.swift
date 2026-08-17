import MacLinkKit
import SwiftUI

struct MediaPane: View {
    @Environment(RemoteSession.self) private var session

    @State private var volume: Double = 0.5
    @State private var isAdjustingVolume = false

    var body: some View {
        VStack(spacing: 0) {
            HostStatusBar()

            ScrollView {
                VStack(spacing: 20) {
                    transport
                    volumeSection
                    brightnessSection
                }
                .padding(16)
            }
        }
        .navigationBarHidden(true)
        .onAppear { syncVolume() }
        .onChange(of: session.status?.volume) { _, _ in syncVolume() }
    }

    // MARK: Transport

    private var transport: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Playback")

            HStack(spacing: 12) {
                transportButton("backward.fill") { session.send(.media(.previousTrack)) }
                transportButton("playpause.fill", isPrimary: true) { session.send(.media(.playPause)) }
                transportButton("forward.fill") { session.send(.media(.nextTrack)) }
            }
        }
    }

    private func transportButton(_ symbol: String, isPrimary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: isPrimary ? 30 : 24, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: isPrimary ? 84 : 72)
                .background(
                    isPrimary ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.quaternary),
                    in: RoundedRectangle(cornerRadius: 16)
                )
                .foregroundStyle(isPrimary ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: Volume

    private var volumeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("Volume")
                Spacer()
                if session.status?.muted == true {
                    Text("Muted")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }

            HStack(spacing: 12) {
                Image(systemName: "speaker.fill")
                    .foregroundStyle(.secondary)
                Slider(
                    value: $volume,
                    in: 0...1,
                    onEditingChanged: { editing in
                        isAdjustingVolume = editing
                        if !editing { session.send(.setVolume(volume)) }
                    }
                )
                .onChange(of: volume) { _, newValue in
                    guard isAdjustingVolume else { return }
                    session.send(.setVolume(newValue))
                }
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                CommandButton(title: "Volume Down", systemImage: "speaker.minus") {
                    session.send(.media(.volumeDown))
                }
                CommandButton(title: "Mute", systemImage: "speaker.slash") {
                    session.send(.media(.mute))
                }
                CommandButton(title: "Volume Up", systemImage: "speaker.plus") {
                    session.send(.media(.volumeUp))
                }
            }
        }
    }

    private func syncVolume() {
        // Ignore status pushes while the user's thumb is on the slider, or it will fight them.
        guard !isAdjustingVolume, let value = session.status?.volume else { return }
        volume = value
    }

    // MARK: Brightness

    private var brightnessSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Brightness")

            HStack(spacing: 10) {
                CommandButton(title: "Screen −", systemImage: "sun.min") {
                    session.send(.media(.brightnessDown))
                }
                CommandButton(title: "Screen +", systemImage: "sun.max") {
                    session.send(.media(.brightnessUp))
                }
            }

            HStack(spacing: 10) {
                CommandButton(title: "Keyboard −", systemImage: "keyboard.chevron.compact.down") {
                    session.send(.media(.keyboardBrightnessDown))
                }
                CommandButton(title: "Keyboard +", systemImage: "keyboard") {
                    session.send(.media(.keyboardBrightnessUp))
                }
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}
