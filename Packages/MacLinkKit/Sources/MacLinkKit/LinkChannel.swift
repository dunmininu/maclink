import Foundation
import Network

/// A length-prefixed message channel over a single `NWConnection`, with optional record encryption.
///
/// Frames are `UInt32` big-endian length + payload. Before the handshake completes the payload is
/// plaintext JSON; afterwards every payload is a ChaChaPoly record.
public actor LinkChannel {
    private let connection: NWConnection
    private var cipher: SessionCipher?
    private var isCancelled = false
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var hasStarted = false

    public init(connection: NWConnection) {
        self.connection = connection
    }

    public var endpointDescription: String {
        String(describing: connection.endpoint)
    }

    /// Starts the connection and resolves once it reaches `.ready`.
    public func start(on queue: DispatchQueue) async throws {
        guard !hasStarted else { return }
        hasStarted = true

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.startContinuation = continuation
                connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    Task { await self.handleState(state) }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            resumeStart(with: .success(()))
        case .failed(let error):
            resumeStart(with: .failure(error))
        case .cancelled:
            resumeStart(with: .failure(LinkError.connectionClosed))
        case .waiting(let error):
            // `.waiting` means the path is not usable yet (e.g. no route to the host). For a LAN
            // remote there is nothing to wait for, so surface it instead of hanging.
            resumeStart(with: .failure(error))
        default:
            break
        }
    }

    private func resumeStart(with result: Result<Void, Error>) {
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        continuation.resume(with: result)
    }

    public func activateEncryption(_ cipher: SessionCipher) {
        self.cipher = cipher
    }

    // MARK: Sending

    public func send<T: Encodable>(_ message: T) async throws {
        try await sendPayload(LinkJSON.encode(message))
    }

    private func sendPayload(_ payload: Data) async throws {
        let body: Data
        if let cipher {
            body = try cipher.seal(payload)
        } else {
            body = payload
        }
        guard body.count <= LinkProtocol.maxFrameSize else {
            throw LinkError.protocolViolation("outbound frame of \(body.count) bytes exceeds the limit")
        }

        var frame = Data(capacity: body.count + 4)
        withUnsafeBytes(of: UInt32(body.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(body)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    // MARK: Receiving

    public func receive<T: Decodable>(_ type: T.Type) async throws -> T {
        let payload = try await receivePayload()
        do {
            return try LinkJSON.decode(type, from: payload)
        } catch {
            throw LinkError.protocolViolation("could not decode \(type): \(error.localizedDescription)")
        }
    }

    private func receivePayload() async throws -> Data {
        let header = try await receiveExactly(4)
        // `loadUnaligned`, because Data's backing bytes carry no alignment guarantee.
        let length = header.withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self).bigEndian) }
        guard length > 0, length <= LinkProtocol.maxFrameSize else {
            throw LinkError.protocolViolation("inbound frame length \(length) is out of range")
        }
        let body = try await receiveExactly(length)
        if let cipher {
            return try cipher.open(body)
        }
        return body
    }

    private func receiveExactly(_ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, data.count == count {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: LinkError.connectionClosed)
                } else {
                    continuation.resume(throwing: LinkError.protocolViolation("short read"))
                }
            }
        }
    }

    // MARK: Teardown

    public func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        resumeStart(with: .failure(LinkError.connectionClosed))
    }
}

// MARK: - Shared network parameters

public enum LinkParameters {

    /// TCP parameters tuned for a latency-sensitive local link.
    ///
    /// Two deliberate choices, and the difference between them matters:
    ///
    /// - **Peer-to-peer is on.** This lets Network.framework use AWDL — the same direct Wi-Fi radio
    ///   link AirDrop rides on — so the phone and Mac find each other when they are near each other,
    ///   even with no shared Wi-Fi network, no router, and no infrastructure at all. This is the
    ///   Apple-ecosystem behaviour: it just works when the two devices are together.
    /// - **Cellular is prohibited.** This is what keeps the link local. AWDL is a proximity radio
    ///   link, not the internet; cellular would be the internet. Excluding it means the OS can never
    ///   route this connection off the local link, so there is still no path from the outside world
    ///   to your Mac.
    public static func tcp() -> NWParameters {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true                 // never coalesce; a 40 ms Nagle delay is visible on a cursor
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 5
        tcpOptions.keepaliveInterval = 3
        tcpOptions.keepaliveCount = 3
        tcpOptions.connectionTimeout = 8

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.includePeerToPeer = true
        parameters.prohibitedInterfaceTypes = [.cellular]
        parameters.serviceClass = .responsiveData
        return parameters
    }

    /// Discovery parameters.
    ///
    /// `HostDiscovery` runs one browser of each kind and merges them: a peer-to-peer browser finds a
    /// Mac over AWDL with no shared network, while a plain one covers ordinary Wi-Fi. Cellular stays
    /// prohibited either way, which is what keeps discovery — and therefore the whole app — local.
    public static func discovery(peerToPeer: Bool) -> NWParameters {
        let parameters = NWParameters()
        parameters.includePeerToPeer = peerToPeer
        parameters.prohibitedInterfaceTypes = [.cellular]
        return parameters
    }
}
