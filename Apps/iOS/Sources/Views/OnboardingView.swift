import MacLinkKit
import SwiftUI

/// First-run setup.
///
/// The wizard watches real state rather than asking the user to confirm things: it moves on by
/// itself the moment a Mac appears, connects on its own when there is only one, and finishes when
/// the Mac reports it has the permission it needs. The only thing a person has to type is the
/// pairing code, because that is the step whose whole purpose is proving a human is present.
struct OnboardingView: View {
    @Environment(RemoteSession.self) private var session
    @Environment(Preferences.self) private var preferences

    @State private var hasStarted = false
    @State private var autoConnectAttempted: String?
    @State private var code = ""
    @FocusState private var codeFocused: Bool

    private enum Step {
        case welcome
        case findMac
        case chooseMac
        case pairing
        case accessibility
        case done
    }

    private var step: Step {
        if !hasStarted { return .welcome }
        if session.isAwaitingPairingCode { return .pairing }
        if session.isConnected {
            if session.status?.accessibilityGranted == false { return .accessibility }
            return .done
        }
        if session.hosts.isEmpty { return .findMac }
        return .chooseMac
    }

    var body: some View {
        VStack(spacing: 0) {
            progressBar
                .padding(.horizontal, 24)
                .padding(.top, 12)

            ScrollView {
                VStack(spacing: 28) {
                    switch step {
                    case .welcome: welcome
                    case .findMac: findMac
                    case .chooseMac: chooseMac
                    case .pairing: pairing
                    case .accessibility: accessibility
                    case .done: done
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .padding(.top, 36)
            }
        }
        .animation(.snappy, value: step)
        .onAppear { session.start() }
        .onChange(of: session.hosts) { _, hosts in
            autoConnectIfObvious(hosts)
        }
    }

    // MARK: Progress

    private var stepIndex: Int {
        switch step {
        case .welcome: return 0
        case .findMac, .chooseMac: return 1
        case .pairing: return 2
        case .accessibility: return 3
        case .done: return 4
        }
    }

    private var progressBar: some View {
        HStack(spacing: 6) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(index <= stepIndex ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(height: 4)
            }
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 24) {
            appMark

            VStack(spacing: 10) {
                Text("MacLink")
                    .font(.largeTitle.weight(.bold))
                Text("Turn this iPhone into a trackpad and keyboard for your Mac.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 16) {
                bullet("cursorarrow.motionlines", "Trackpad", "Move, click, scroll and pinch, with gestures that match your Mac.")
                bullet("keyboard", "Keyboard", "Type and send shortcuts straight to whatever app is in front.")
                bullet("lock.shield", "Stays between your devices", "Works over your Wi-Fi, or directly when your iPhone is near your Mac. Never over the internet.")
            }
            .padding(.top, 6)

            primaryButton("Get Started") { hasStarted = true }
                .padding(.top, 8)
        }
    }

    private var findMac: some View {
        VStack(spacing: 24) {
            stepIcon("laptopcomputer.and.iphone", spinning: true)

            VStack(spacing: 10) {
                Text("Open MacLink on your Mac")
                    .font(.title2.weight(.semibold))
                Text("Looking for it now — this screen moves on by itself as soon as your Mac shows up.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 14) {
                numbered(1, "On your Mac, open **MacLink Host**.")
                numbered(2, "Look for the pointer icon in the menu bar, at the top right.")
                numbered(3, "Keep both devices near each other, or on the same Wi-Fi.")
            }
            .padding(18)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))

            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Searching…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var chooseMac: some View {
        VStack(spacing: 24) {
            stepIcon("laptopcomputer")

            VStack(spacing: 10) {
                Text("Choose your Mac")
                    .font(.title2.weight(.semibold))
                Text("More than one Mac is running MacLink Host.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                ForEach(session.hosts) { host in
                    Button {
                        session.connect(to: host)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "laptopcomputer")
                                .font(.title2)
                                .foregroundStyle(.tint)
                            Text(host.name)
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(16)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
            }

            if session.isBusy {
                ProgressView()
            }
        }
    }

    private var pairing: some View {
        VStack(spacing: 24) {
            stepIcon("number.circle")

            VStack(spacing: 10) {
                Text("Enter the code")
                    .font(.title2.weight(.semibold))
                Text("Your Mac is showing a 6-digit code. Type it here so it knows this iPhone is yours.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            codeBoxes
                .onTapGesture { codeFocused = true }

            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($codeFocused)
                .opacity(0.01)
                .frame(height: 1)
                .onChange(of: code) { _, newValue in
                    let filtered = String(newValue.filter(\.isNumber).prefix(6))
                    if filtered != newValue { code = filtered }
                    if filtered.count == 6 { session.submitPairingCode(filtered) }
                }

            Button("Cancel") {
                code = ""
                session.cancelPairing()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .onAppear { codeFocused = true }
    }

    private var accessibility: some View {
        VStack(spacing: 24) {
            stepIcon("lock.shield", tint: .orange)

            VStack(spacing: 10) {
                Text("One last thing")
                    .font(.title2.weight(.semibold))
                Text("Connected to \(session.status?.hostName ?? "your Mac"). macOS still needs your permission before anything can move the pointer.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 14) {
                numbered(1, "On your Mac, click the **MacLink** icon in the menu bar.")
                numbered(2, "Click **Open Accessibility Settings**.")
                numbered(3, "Switch on **MacLink Host** in the list.")
            }
            .padding(18)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))

            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for permission…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button("Skip for now") { finish() }
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var done: some View {
        VStack(spacing: 24) {
            stepIcon("checkmark.circle.fill", tint: .green)

            VStack(spacing: 10) {
                Text("You're all set")
                    .font(.title2.weight(.semibold))
                Text("Connected to \(session.status?.hostName ?? "your Mac"). From now on MacLink reconnects on its own whenever you open it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 16) {
                bullet("hand.draw", "Drag to move", "One finger moves the pointer. Tap to click.")
                bullet("hand.point.up.left", "Two fingers", "Scroll, or tap with two for a right-click.")
                bullet("hand.tap", "Three fingers", "Swipe to switch Spaces or open Mission Control.")
            }

            primaryButton("Start Using MacLink") { finish() }
                .padding(.top, 8)
        }
    }

    // MARK: Pieces

    private var appMark: some View {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
            .fill(LinearGradient(
                colors: [Color(red: 0.26, green: 0.29, blue: 0.55), Color(red: 0.45, green: 0.32, blue: 0.72)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            .frame(width: 108, height: 108)
            .overlay {
                Image(systemName: "cursorarrow.motionlines")
                    .font(.system(size: 46, weight: .medium))
                    .foregroundStyle(.white)
            }
            .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
    }

    private func stepIcon(_ symbol: String, tint: Color = .accentColor, spinning: Bool = false) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 52, weight: .light))
            .foregroundStyle(tint)
            .symbolEffect(.pulse, isActive: spinning)
            .frame(height: 62)
    }

    private func bullet(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func numbered(_ index: Int, _ markdown: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(index)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: Circle())
            Text(.init(markdown))
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private var codeBoxes: some View {
        let digits = Array(code.prefix(6))
        return HStack(spacing: 10) {
            ForEach(0..<6, id: \.self) { index in
                Text(index < digits.count ? String(digits[index]) : "")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .frame(width: 44, height: 56)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(index == digits.count ? Color.accentColor : .clear, lineWidth: 2)
                    }
            }
        }
    }

    // MARK: Behaviour

    /// With exactly one Mac on the network there is nothing to choose, so don't make them choose.
    private func autoConnectIfObvious(_ hosts: [DiscoveredHost]) {
        guard hasStarted, hosts.count == 1, !session.isConnected, !session.isBusy else { return }
        let host = hosts[0]
        guard autoConnectAttempted != host.id else { return }
        autoConnectAttempted = host.id
        session.connect(to: host)
    }

    private func finish() {
        preferences.hasCompletedOnboarding = true
    }
}
