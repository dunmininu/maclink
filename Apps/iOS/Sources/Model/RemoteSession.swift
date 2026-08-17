import MacLinkKit
import Network
import Observation
import UIKit

/// Everything the UI needs to know about the phone's link to a Mac.
@MainActor
@Observable
final class RemoteSession {

    // MARK: Observable state

    private(set) var hosts: [DiscoveredHost] = []
    private(set) var linkState: ClientLink.State = .idle
    private(set) var status: HostStatus?
    private(set) var connectedHost: DeviceDescriptor?
    private(set) var clipboardFromMac: String?
    private(set) var notice: Notice?
    private(set) var lastError: String?

    /// True while the Mac is showing a code and we are waiting for the user to type it.
    private(set) var isAwaitingPairingCode = false
    private(set) var pairingHostName: String?

    // MARK: Dependencies

    private let preferences: Preferences
    private let store = SecretStore(service: "africa.myladder.maclink")
    private let discovery = HostDiscovery()
    private var link: ClientLink
    private let deviceID: String

    private var pairingContinuation: CheckedContinuation<String, Error>?
    private var hasAttemptedAutoConnect = false

    private static let tokensKey = "host-tokens"

    init(preferences: Preferences) {
        self.preferences = preferences
        deviceID = InstallationIdentity.identifier(store: store)
        link = ClientLink(identity: DeviceDescriptor(id: deviceID, name: preferences.deviceName))
        configureLink()
        configureDiscovery()
    }

    // MARK: Derived state

    /// Derived from `linkState`, not from `link.isConnected`.
    ///
    /// `ClientLink` is a plain class, so Observation cannot see through it — a computed property
    /// reading `link.isConnected` never invalidates a SwiftUI view, and the UI sits on the host list
    /// forever while the link is actually connected. `linkState` is a stored property on this
    /// `@Observable` type, so reading that does register a dependency.
    var isConnected: Bool {
        if case .connected = linkState { return true }
        return false
    }

    var isBusy: Bool {
        switch linkState {
        case .connecting, .awaitingPairingCode: return true
        default: return false
        }
    }

    var pairedHostIDs: Set<String> { Set(tokens.keys) }

    // MARK: Lifecycle

    func start() {
        discovery.start()
    }

    func stop() {
        discovery.stop()
        cancelPairing()
        link.disconnect()
        connectedHost = nil
        status = nil
    }

    /// Called when the app returns to the foreground.
    func resume() {
        discovery.start()
        hasAttemptedAutoConnect = false
        attemptAutoConnect()
    }

    // MARK: Connecting

    func connect(to host: DiscoveredHost) {
        lastError = nil
        notice = nil
        preferences.lastHostID = host.id
        link.connect(to: host.endpoint, storedToken: tokens[host.id])
    }

    func disconnect() {
        cancelPairing()
        link.disconnect()
        connectedHost = nil
        status = nil
    }

    func forgetPairing(for hostID: String) {
        var updated = tokens
        updated.removeValue(forKey: hostID)
        tokens = updated
        if preferences.lastHostID == hostID { preferences.lastHostID = nil }
        if connectedHost?.id == hostID { disconnect() }
    }

    private func attemptAutoConnect() {
        guard !hasAttemptedAutoConnect, !isConnected, !isBusy else { return }
        guard let lastHostID = preferences.lastHostID,
              tokens[lastHostID] != nil,
              let host = hosts.first(where: { $0.id == lastHostID })
        else { return }

        hasAttemptedAutoConnect = true
        connect(to: host)
    }

    // MARK: Pairing

    func submitPairingCode(_ code: String) {
        let digits = code.filter(\.isNumber)
        guard digits.count == 6, let continuation = pairingContinuation else { return }
        pairingContinuation = nil
        isAwaitingPairingCode = false
        continuation.resume(returning: digits)
    }

    func cancelPairing() {
        guard let continuation = pairingContinuation else { return }
        pairingContinuation = nil
        isAwaitingPairingCode = false
        pairingHostName = nil
        continuation.resume(throwing: CancellationError())
        link.disconnect()
    }

    // MARK: Sending

    func send(_ message: ClientMessage) {
        link.send(message)
    }

    func send(_ event: PointerEvent) {
        link.send(.pointer(event))
    }

    func requestClipboard() {
        link.send(.clipboardPull)
    }

    func sendClipboard(_ text: String) {
        guard !text.isEmpty, text.utf8.count <= LinkProtocol.maxClipboardBytes else { return }
        link.send(.clipboardPush(text: text))
    }

    func clearClipboardFromMac() {
        clipboardFromMac = nil
    }

    func dismissNotice() {
        notice = nil
    }

    // MARK: Wiring

    private func configureDiscovery() {
        discovery.onChange = { [weak self] found in
            guard let self else { return }
            let paired = pairedHostIDs
            hosts = found.map { host in
                var copy = host
                copy.isPaired = paired.contains(host.id)
                return copy
            }
            attemptAutoConnect()
        }
    }

    private func configureLink() {
        link.onStateChange = { [weak self] state in
            guard let self else { return }
            linkState = state
            switch state {
            case .connected(let hostStatus):
                status = hostStatus
                connectedHost = link.host
                lastError = nil
                if !hostStatus.accessibilityGranted {
                    notice = Notice(
                        level: .warning,
                        message: "\(hostStatus.hostName) still needs Accessibility permission. Open MacLink Host on the Mac to grant it."
                    )
                }
            case .failed(let message):
                lastError = message
                status = nil
                connectedHost = nil
                cancelPairingContinuationIfNeeded()
            case .idle:
                status = nil
                connectedHost = nil
            case .awaitingPairingCode, .connecting:
                break
            }
        }

        link.onHostMessage = { [weak self] message in
            guard let self else { return }
            switch message {
            case .clipboard(let text):
                clipboardFromMac = text
            case .notice(let value):
                notice = value
            case .status, .pong:
                break
            }
        }

        link.onTokenIssued = { [weak self] hostID, token in
            guard let self else { return }
            var updated = tokens
            updated[hostID] = token
            tokens = updated
            preferences.lastHostID = hostID
        }

        link.pairingCodeProvider = { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.awaitPairingCode()
        }
    }

    private func awaitPairingCode() async throws -> String {
        // Only one pairing can be in flight; a second would strand the first continuation.
        cancelPairing()
        pairingHostName = hosts.first { $0.id == preferences.lastHostID }?.name
        isAwaitingPairingCode = true
        return try await withCheckedThrowingContinuation { continuation in
            pairingContinuation = continuation
        }
    }

    private func cancelPairingContinuationIfNeeded() {
        guard let continuation = pairingContinuation else {
            isAwaitingPairingCode = false
            return
        }
        pairingContinuation = nil
        isAwaitingPairingCode = false
        continuation.resume(throwing: CancellationError())
    }

    // MARK: Token storage

    private var tokens: [String: Data] {
        get { store.load([String: Data].self, forKey: Self.tokensKey) ?? [:] }
        set {
            store.save(newValue, forKey: Self.tokensKey)
            let paired = Set(newValue.keys)
            hosts = hosts.map { host in
                var copy = host
                copy.isPaired = paired.contains(host.id)
                return copy
            }
        }
    }
}
