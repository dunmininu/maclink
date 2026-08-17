import Foundation
import Network
import os



/// A Mac found on the local network.
public struct DiscoveredHost: Identifiable, Sendable, Hashable {
    /// Stable host identifier from the Bonjour TXT record; falls back to the service name.
    public var id: String
    public var name: String
    public var endpoint: NWEndpoint
    public var isPaired: Bool = false

    /// Public so a host can also be constructed from a typed-in address, not only from discovery —
    /// the fallback when Bonjour is unavailable (a blocked Local Network permission, say).
    public init(id: String, name: String, endpoint: NWEndpoint, isPaired: Bool = false) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.isPaired = isPaired
    }

    public static func == (lhs: DiscoveredHost, rhs: DiscoveredHost) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.endpoint == rhs.endpoint && lhs.isPaired == rhs.isPaired
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(endpoint)
    }
}

/// Browses for MacLink hosts nearby.
///
/// Bonjour resolves only on the local link — a shared network, or the direct AWDL link when
/// peer-to-peer is in play. Either way a Mac is discoverable only from beside it, never across the
/// internet.
@MainActor
public final class HostDiscovery {
    public private(set) var hosts: [DiscoveredHost] = []
    public var onChange: (([DiscoveredHost]) -> Void)?
    public var onStateChange: ((NWBrowser.State) -> Void)?

    private var browsers: [NWBrowser] = []
    /// Latest results per browser, keyed by whether that browser was the peer-to-peer one.
    private var resultsByTransport: [Bool: [DiscoveredHost]] = [:]
    private let queue = DispatchQueue(label: "africa.myladder.maclink.browser")

    public init() {}

    /// Runs two browsers and merges them.
    ///
    /// A single browser cannot cover both cases. One with `includePeerToPeer = true` is what finds a
    /// Mac over AWDL when there is no shared network, but it does not reliably return ordinary
    /// infrastructure results alongside them — and in the Simulator, where there is no AWDL at all,
    /// it finds nothing. So we browse both ways and de-duplicate by host id.
    public func start() {
        guard browsers.isEmpty else { return }
        startBrowser(peerToPeer: false)
        startBrowser(peerToPeer: true)
    }

    private func startBrowser(peerToPeer: Bool) {
        let parameters = LinkParameters.discovery(peerToPeer: peerToPeer)
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: LinkProtocol.serviceType,
            domain: nil
        )
        let browser = NWBrowser(for: descriptor, using: parameters)

        browser.stateUpdateHandler = { [weak self] state in
            LinkLog.discovery.notice("browser(p2p: \(peerToPeer, privacy: .public)) state: \(String(describing: state), privacy: .public)")
            Task { @MainActor in self?.onStateChange?(state) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            LinkLog.discovery.notice("browser(p2p: \(peerToPeer, privacy: .public)) results: \(results.count, privacy: .public)")
            for result in results {
                LinkLog.discovery.debug("  endpoint: \(String(describing: result.endpoint), privacy: .public) interfaces: \(result.interfaces.map(\.debugDescription).joined(separator: ","), privacy: .public)")
            }
            Task { @MainActor in self?.apply(results, peerToPeer: peerToPeer) }
        }

        browsers.append(browser)
        browser.start(queue: queue)
    }

    public func stop() {
        for browser in browsers {
            browser.stateUpdateHandler = nil
            browser.browseResultsChangedHandler = nil
            browser.cancel()
        }
        browsers = []
        resultsByTransport = [:]
        hosts = []
        onChange?(hosts)
    }

    private func apply(_ results: Set<NWBrowser.Result>, peerToPeer: Bool) {
        var found: [DiscoveredHost] = []
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }

            var hostID = name
            var displayName = name
            if case .bonjour(let txt) = result.metadata {
                if let value = txt[LinkProtocol.TXTKey.hostID], !value.isEmpty { hostID = value }
                if let value = txt[LinkProtocol.TXTKey.hostName], !value.isEmpty { displayName = value }
            }
            found.append(DiscoveredHost(id: hostID, name: displayName, endpoint: result.endpoint))
        }
        resultsByTransport[peerToPeer] = found

        // Merge both browsers, keeping the first endpoint seen for each host. Infrastructure results
        // come first so a Mac reachable over Wi-Fi is preferred over the same Mac over AWDL, which is
        // slower to set up.
        var merged: [DiscoveredHost] = []
        var seen = Set<String>()
        for transport in [false, true] {
            for host in resultsByTransport[transport] ?? [] where !seen.contains(host.id) {
                seen.insert(host.id)
                merged.append(host)
            }
        }

        hosts = merged.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        onChange?(hosts)
    }
}

/// The phone's end of the link: connect, handshake, then stream input events.
@MainActor
public final class ClientLink {

    public enum State: Equatable {
        case idle
        case connecting
        case awaitingPairingCode
        case connected(HostStatus)
        case failed(String)
    }

    public private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    public private(set) var host: DeviceDescriptor?

    public var onStateChange: ((State) -> Void)?
    public var onHostMessage: ((HostMessage) -> Void)?
    /// Called when the Mac is showing a pairing code. Return the digits the user typed.
    public var pairingCodeProvider: (@Sendable () async throws -> String)?
    /// Called with a freshly minted token so the app can persist it against the host id.
    public var onTokenIssued: ((String, Data) -> Void)?

    private let identity: DeviceDescriptor
    private var channel: LinkChannel?
    private var readTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private let queue = DispatchQueue(label: "africa.myladder.maclink.client", qos: .userInteractive)

    public init(identity: DeviceDescriptor) {
        self.identity = identity
    }

    public var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    public func connect(to endpoint: NWEndpoint, storedToken: Data?) {
        disconnect()
        state = .connecting

        let connection = NWConnection(to: endpoint, using: LinkParameters.tcp())
        let channel = LinkChannel(connection: connection)
        self.channel = channel

        connectTask = Task { @MainActor in
            do {
                try await channel.start(on: queue)

                let result = try await Handshake.runClient(
                    channel: channel,
                    hello: identity,
                    hasStoredToken: storedToken != nil,
                    credentialProvider: { [weak self] challenge in
                        guard let self else { throw LinkError.notConnected }
                        if challenge.pairingCodeRequired {
                            await MainActor.run { self.state = .awaitingPairingCode }
                            guard let provider = await MainActor.run(body: { self.pairingCodeProvider }) else {
                                throw LinkError.handshakeFailed(HandshakeReject(
                                    reason: .pairingDeclined,
                                    detail: "No pairing code was entered."
                                ))
                            }
                            let code = try await provider()
                            return .pairingCode(code)
                        }
                        guard let storedToken else {
                            throw LinkError.handshakeFailed(HandshakeReject(
                                reason: .unknownDevice,
                                detail: "This Mac no longer recognises this iPhone. Pair again."
                            ))
                        }
                        return .token(storedToken)
                    }
                )

                guard !Task.isCancelled else { return }

                host = result.host
                if let token = result.issuedToken {
                    onTokenIssued?(result.host.id, token)
                }
                state = .connected(result.status)
                beginReading(on: channel)
                beginKeepAlive()
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed(error.localizedDescription)
                await channel.cancel()
                self.channel = nil
            }
        }
    }

    public func disconnect() {
        connectTask?.cancel()
        connectTask = nil
        readTask?.cancel()
        readTask = nil
        keepAliveTask?.cancel()
        keepAliveTask = nil
        if let channel {
            Task { await channel.cancel() }
        }
        channel = nil
        host = nil
        if case .idle = state {} else { state = .idle }
    }

    /// Fire-and-forget send. Input events are worthless once they are late, so a failed send is
    /// dropped rather than queued.
    public func send(_ message: ClientMessage) {
        guard let channel, isConnected else { return }
        Task { try? await channel.send(message) }
    }

    private func beginReading(on channel: LinkChannel) {
        readTask = Task { @MainActor [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await channel.receive(HostMessage.self)
                    guard let self else { return }
                    if case .status(let status) = message {
                        self.state = .connected(status)
                    }
                    self.onHostMessage?(message)
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.state = .failed(error.localizedDescription)
                self.channel = nil
            }
        }
    }

    private func beginKeepAlive() {
        keepAliveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard let self, self.isConnected else { return }
                self.send(.ping)
            }
        }
    }
}

/// Log channels. Discovery is the one worth watching: when a Mac does not appear, the browser's own
/// state and result count are the only things that distinguish "no service on the network" from
/// "the browser never started".
enum LinkLog {
    static let discovery = Logger(subsystem: "africa.myladder.maclink", category: "discovery")
}
