import AppKit
import Combine
import MacLinkKit
import Observation
import ServiceManagement

/// A pairing attempt that is waiting for the user to type the code on their phone.
struct PairingRequest: Identifiable, Equatable {
    var id: String { device.id }
    var device: DeviceDescriptor
    var code: String
    var startedAt: Date
}

/// Wires the network server to the input synthesiser and holds all the state the menu bar UI shows.
@MainActor
@Observable
final class HostCoordinator {

    // MARK: Observable state

    private(set) var serverState: HostServer.State = .stopped
    private(set) var connectedDevices: [DeviceDescriptor] = []
    private(set) var pairedDevices: [PairedDevice] = []
    private(set) var pendingPairing: PairingRequest? {
        didSet { onPairingChange?(pendingPairing) }
    }

    /// Set by the app delegate so a pairing request can raise its own window. The menu bar's popover
    /// only renders while it is open, so it cannot be the thing that surfaces the code.
    var onPairingChange: ((PairingRequest?) -> Void)?

    private(set) var accessibilityGranted = InputSynthesizer.isTrusted
    /// Mission Control, Spaces and the app switcher need this on top of Accessibility, because they
    /// are driven through System Events. See `SystemEventsBridge`.
    private(set) var automationGranted = false
    private(set) var log: [String] = []

    var hostName: String {
        didSet {
            guard hostName != oldValue else { return }
            let trimmed = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { hostName = oldValue; return }
            defaults.set(trimmed, forKey: Keys.hostName)
            server.restart(hostName: trimmed)
        }
    }

    var acceptsNewPairings: Bool {
        didSet { defaults.set(acceptsNewPairings, forKey: Keys.acceptsNewPairings) }
    }

    var syncsClipboardAutomatically: Bool {
        didSet {
            defaults.set(syncsClipboardAutomatically, forKey: Keys.autoClipboard)
            lastPasteboardChangeCount = NSPasteboard.general.changeCount
        }
    }

    var launchesAtLogin: Bool {
        didSet {
            guard launchesAtLogin != oldValue else { return }
            applyLaunchAtLogin(launchesAtLogin)
        }
    }

    var hasSeenWelcome: Bool {
        didSet { defaults.set(hasSeenWelcome, forKey: Keys.hasSeenWelcome) }
    }

    /// Set by the app delegate, which owns the window. Lets the menu reopen the setup guide.
    var onShowWelcome: (() -> Void)?

    #if DEBUG
    /// Where debug builds leave the current pairing code for automated end-to-end tests.
    static let debugPairingCodeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("maclink-debug-pairing-code.txt")
    #endif

    // MARK: Dependencies

    private let defaults = UserDefaults.standard
    private let trustStore: TrustStore
    private let input: InputSynthesizer
    private let system: SystemController
    private let server: HostServer

    private var statusTimer: Timer?
    private var pasteboardTimer: Timer?
    private var trustTimer: Timer?
    private var lastPasteboardChangeCount = NSPasteboard.general.changeCount

    /// Consecutive failed pairings, and the deadline until which new attempts are refused.
    private var failedPairings = 0
    private var pairingLockedUntil: Date?
    private static let failedPairingAllowance = 3
    private static let pairingLockout: TimeInterval = 60

    private enum Keys {
        static let hostName = "hostName"
        static let acceptsNewPairings = "acceptsNewPairings"
        static let autoClipboard = "syncsClipboardAutomatically"
        static let hasSeenWelcome = "hasSeenWelcome"
        static let enablePairingCodeFile = "EnablePairingCodeFile"
    }

    init() {
        // Everything is bound through locals: `self` is off limits until the last stored property
        // is assigned, and the server needs both the trust store's id and the resolved name.
        let defaults = UserDefaults.standard
        let trustStore = TrustStore()
        let synthesizer = InputSynthesizer()
        let resolvedName = defaults.string(forKey: Keys.hostName)
            ?? Host.current().localizedName
            ?? ProcessInfo.processInfo.hostName

        self.trustStore = trustStore
        input = synthesizer
        system = SystemController(input: synthesizer)
        server = HostServer(hostID: trustStore.hostID, hostName: resolvedName)

        hostName = resolvedName
        acceptsNewPairings = defaults.object(forKey: Keys.acceptsNewPairings) as? Bool ?? true
        syncsClipboardAutomatically = defaults.bool(forKey: Keys.autoClipboard)
        launchesAtLogin = SMAppService.mainApp.status == .enabled
        hasSeenWelcome = defaults.bool(forKey: Keys.hasSeenWelcome)
        pairedDevices = trustStore.devices

        configureServer()
    }

    // MARK: Lifecycle

    func start() {
        server.start()
        startTimers()

        // Surface a failed system shortcut rather than letting it vanish — without Automation these
        // fail silently, which is exactly how Mission Control appeared to be "broken".
        system.events.onFailure = { [weak self] message in
            self?.append(log: message)
        }

        // Ask once, at launch, so the dialog lands while the user is at the Mac rather than mid-gesture.
        automationGranted = system.events.isAuthorized
        if !automationGranted {
            system.events.requestAuthorization { [weak self] granted in
                guard let self else { return }
                automationGranted = granted
                append(log: granted
                       ? "Automation permission granted — Mission Control and Spaces will work"
                       : "Automation permission denied — Mission Control, Spaces and the app switcher will not work")
            }
        }
    }

    func stop() {
        statusTimer?.invalidate()
        pasteboardTimer?.invalidate()
        trustTimer?.invalidate()
        input.releaseHeldButtons()
        server.stop()
    }

    func openAutomationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
        NSWorkspace.shared.open(url)
    }

    func requestAccessibilityPermission() {
        InputSynthesizer.requestTrust()
        // The prompt is modal to System Settings, so poll rather than expecting a callback.
        refreshTrust()
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    func revoke(_ device: PairedDevice) {
        trustStore.revoke(device.id)
        server.disconnectSessions(forDeviceID: device.id)
        append(log: "Revoked \(device.name)")
    }

    func revokeAll() {
        for device in trustStore.devices {
            server.disconnectSessions(forDeviceID: device.id)
        }
        trustStore.revokeAll()
        append(log: "Revoked all devices")
    }

    func cancelPendingPairing() {
        guard let pending = pendingPairing else { return }
        pendingPairing = nil
        server.disconnectSessions(forDeviceID: pending.device.id)
        append(log: "Pairing with \(pending.device.name) cancelled")
    }

    // MARK: Server wiring

    private func configureServer() {
        server.onStateChange = { [weak self] state in
            self?.serverState = state
        }

        server.onSessionsChange = { [weak self] sessions in
            guard let self else { return }
            connectedDevices = sessions.compactMap(\.device)
            for device in connectedDevices { trustStore.markSeen(device.id) }
            pairedDevices = trustStore.devices
            if connectedDevices.isEmpty {
                // Never leave a button stuck down because the phone vanished mid-drag.
                input.releaseHeldButtons()
            }
        }

        server.tokenLookup = { [weak self] deviceID in
            self?.trustStore.token(for: deviceID)
        }

        server.onPairingRequest = { [weak self] device in
            guard let self else { return nil }
            guard acceptsNewPairings else {
                append(log: "Declined \(device.name): new pairings are turned off")
                return nil
            }
            guard pendingPairing == nil else {
                append(log: "Declined \(device.name): another pairing is in progress")
                return nil
            }
            // Back off after repeated failures. Without this, anyone on the network can spawn an
            // unlimited stream of pairing windows — both a way to grind at the 6-digit code and a
            // way to make the Mac unusable by burying it in dialogs.
            if let until = pairingLockedUntil, Date() < until {
                let seconds = Int(until.timeIntervalSinceNow.rounded(.up))
                append(log: "Declined \(device.name): too many failed attempts, locked for \(seconds)s")
                return nil
            }

            let code = LinkCrypto.makePairingCode()
            #if DEBUG
            // Development affordance for automated end-to-end tests, which cannot read the code off
            // the screen. Doubly gated: compiled out of release builds entirely, and even in a debug
            // build it stays off unless explicitly switched on with
            //     defaults write africa.myladder.maclink.host EnablePairingCodeFile -bool true
            // so a normal debug build never writes a pairing code to disk.
            if defaults.bool(forKey: Keys.enablePairingCodeFile) {
                try? Data(code.utf8).write(to: Self.debugPairingCodeURL)
            }
            #endif
            pendingPairing = PairingRequest(device: device, code: code, startedAt: Date())
            append(log: "\(device.name) wants to pair")
            NSApp.activate(ignoringOtherApps: true)
            return code
        }

        server.onPairingFinished = { [weak self] device, success in
            guard let self else { return }
            pendingPairing = nil
            if success {
                failedPairings = 0
                pairingLockedUntil = nil
                append(log: "Paired with \(device.name)")
            } else {
                failedPairings += 1
                if failedPairings >= Self.failedPairingAllowance {
                    pairingLockedUntil = Date().addingTimeInterval(Self.pairingLockout)
                    failedPairings = 0
                    append(log: "Pairing with \(device.name) failed — pausing new pairings for \(Int(Self.pairingLockout))s")
                } else {
                    append(log: "Pairing with \(device.name) failed")
                }
            }
        }

        server.onDevicePaired = { [weak self] device, token in
            guard let self else { return }
            trustStore.upsert(device: device, token: token)
            pairedDevices = trustStore.devices
        }

        server.statusProvider = { [weak self] in
            guard let self else { return HostStatus(hostName: "Mac", accessibilityGranted: false) }
            return system.currentStatus(hostName: hostName)
        }

        server.onLog = { [weak self] message in
            self?.append(log: message)
        }

        server.onMessage = { [weak self] message, session in
            self?.handle(message, from: session)
        }
    }

    // MARK: Message handling

    private func handle(_ message: ClientMessage, from session: HostSession) {
        switch message {
        case .ping:
            session.send(.pong)

        case .requestStatus:
            session.send(.status(system.currentStatus(hostName: hostName)))

        case .pointer(let event):
            guard requireAccessibility(session) else { return }
            switch event {
            case .move(let dx, let dy):
                input.move(dx: dx, dy: dy)
            case .scroll(let dx, let dy, let phase):
                input.scroll(dx: dx, dy: dy, phase: phase)
            case .button(let button, let action, let clickCount):
                input.button(button, action: action, clickCount: clickCount)
            case .zoom(let magnification, let phase):
                input.zoom(magnification: magnification, phase: phase)
            }

        case .keyboard(let event):
            guard requireAccessibility(session) else { return }
            switch event {
            case .text(let text):
                input.type(text: text)
            case .key(let key, let modifiers):
                input.press(key, modifiers: modifiers)
            }

        case .media(let command):
            guard requireAccessibility(session) else { return }
            system.handle(command)
            scheduleStatusPush()

        case .setVolume(let value):
            system.setOutputVolume(value)
            scheduleStatusPush()

        case .system(let command):
            guard requireAccessibility(session) else { return }
            system.handle(command)

        case .clipboardPush(let text):
            system.writeClipboard(text)
            lastPasteboardChangeCount = NSPasteboard.general.changeCount
            append(log: "Received \(text.count) characters from \(session.device?.name ?? "iPhone")")

        case .clipboardPull:
            if let text = system.readClipboard() {
                session.send(.clipboard(text: text))
            } else {
                session.send(.notice(Notice(level: .info, message: "The Mac's clipboard has no text in it.")))
            }
        }
    }

    /// Input silently does nothing until the app is trusted, so tell the phone instead of pretending.
    private func requireAccessibility(_ session: HostSession) -> Bool {
        if accessibilityGranted { return true }
        refreshTrust()
        if accessibilityGranted { return true }
        session.send(.notice(Notice(
            level: .error,
            message: "\(hostName) needs Accessibility permission before it can be controlled. Open MacLink Host on the Mac to grant it."
        )))
        return false
    }

    // MARK: Timers

    private func startTimers() {
        statusTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pushStatus() }
        }
        pasteboardTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkPasteboard() }
        }
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshTrust() }
        }
    }

    private func scheduleStatusPush() {
        // Media keys take a moment to land before the new volume reads back.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            pushStatus()
        }
    }

    private func pushStatus() {
        guard !server.sessions.isEmpty else { return }
        server.broadcast(.status(system.currentStatus(hostName: hostName)))
    }

    private func refreshTrust() {
        let trusted = InputSynthesizer.isTrusted
        if trusted != accessibilityGranted {
            accessibilityGranted = trusted
            append(log: trusted ? "Accessibility permission granted" : "Accessibility permission revoked")
            pushStatus()
        }

        // Automation can be switched on in System Settings at any time, so poll it alongside.
        let automating = system.events.isAuthorized
        if automating != automationGranted {
            automationGranted = automating
            append(log: automating
                   ? "Automation permission granted — Mission Control and Spaces will work"
                   : "Automation permission revoked — Mission Control and Spaces will stop working")
        }
    }

    private func checkPasteboard() {
        guard syncsClipboardAutomatically, !server.sessions.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastPasteboardChangeCount else { return }
        lastPasteboardChangeCount = pasteboard.changeCount
        guard let text = system.readClipboard() else { return }
        server.broadcast(.clipboard(text: text))
    }

    // MARK: Misc

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            append(log: "Could not change login item: \(error.localizedDescription)")
            launchesAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func append(log message: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        log.append("\(stamp)  \(message)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    var statusSummary: String {
        switch serverState {
        case .stopped: return "Off"
        case .starting: return "Starting…"
        case .running: return connectedDevices.isEmpty ? "Waiting on \(networkName)" : "Connected"
        case .failed(let message): return "Error: \(message)"
        }
    }

    /// Best-effort name of the network both devices have to share.
    var networkName: String {
        CurrentNetwork.name() ?? "this network"
    }
}
