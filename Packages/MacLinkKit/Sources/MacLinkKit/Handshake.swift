import CryptoKit
import Foundation

/// Identifies the phone that is asking to drive the Mac.
public struct DeviceDescriptor: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// The secret used to authenticate a key exchange.
public enum LinkCredential: Sendable {
    /// The 6-digit code the Mac is displaying, typed by the user on the phone.
    case pairingCode(String)
    /// The 32-byte token minted at the end of a successful pairing.
    case token(Data)

    var bytes: Data {
        switch self {
        case .pairingCode(let code):
            return Data(code.utf8)
        case .token(let token):
            return token
        }
    }
}

public struct ClientHandshakeResult: Sendable {
    public var host: DeviceDescriptor
    public var status: HostStatus
    /// Non-nil when this handshake completed a pairing; store it for future sessions.
    public var issuedToken: Data?
}

public struct HostHandshakeResult: Sendable {
    public var device: DeviceDescriptor
    /// Non-nil when this handshake completed a pairing; persist it against the device id.
    public var issuedToken: Data?
}

public enum Handshake {

    /// How long each side waits for the peer's next handshake frame. Generous enough for a human to
    /// read a code off the Mac and type it on the phone.
    public static let stepTimeout: TimeInterval = 120

    // MARK: Client side

    /// Runs the phone's half of the handshake.
    ///
    /// - Parameter credentialProvider: Called once the host's challenge arrives. Prompt the user for
    ///   the pairing code here when `challenge.pairingCodeRequired` is true.
    public static func runClient(
        channel: LinkChannel,
        hello identity: DeviceDescriptor,
        hasStoredToken: Bool,
        credentialProvider: @Sendable (HandshakeChallenge) async throws -> LinkCredential
    ) async throws -> ClientHandshakeResult {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let hello = HandshakeHello(
            version: LinkProtocol.version,
            deviceID: identity.id,
            deviceName: identity.name,
            publicKey: privateKey.publicKey.rawRepresentation,
            requestsPairing: !hasStoredToken
        )
        try await channel.send(HandshakeClientMessage.hello(hello))

        let challengeMessage = try await withLinkTimeout(stepTimeout) {
            try await channel.receive(HandshakeHostMessage.self)
        }
        let challenge: HandshakeChallenge
        switch challengeMessage {
        case .challenge(let value):
            challenge = value
        case .reject(let reject):
            throw LinkError.handshakeFailed(reject)
        case .accept:
            throw LinkError.protocolViolation("host accepted before challenging")
        }

        guard challenge.version == LinkProtocol.version else {
            throw LinkError.handshakeFailed(HandshakeReject(
                reason: .versionMismatch,
                detail: "This Mac is running MacLink Host v\(challenge.version); the app speaks v\(LinkProtocol.version)."
            ))
        }

        let credential = try await credentialProvider(challenge)
        let transcript = LinkCrypto.transcript(hello: hello, challenge: challenge)
        let master = try LinkCrypto.masterKey(
            privateKey: privateKey,
            peerPublicKey: challenge.publicKey,
            salt: challenge.salt,
            transcript: transcript
        )

        let mac = LinkCrypto.confirmationMAC(
            master: master,
            credential: credential.bytes,
            transcript: transcript,
            role: .client
        )
        try await channel.send(HandshakeClientMessage.confirm(HandshakeConfirm(mac: mac)))

        let acceptMessage = try await withLinkTimeout(stepTimeout) {
            try await channel.receive(HandshakeHostMessage.self)
        }
        let accept: HandshakeAccept
        switch acceptMessage {
        case .accept(let value):
            accept = value
        case .reject(let reject):
            throw LinkError.handshakeFailed(reject)
        case .challenge:
            throw LinkError.protocolViolation("host challenged twice")
        }

        // Authenticate the host before trusting anything it sent, so a rogue listener on the network
        // cannot impersonate the Mac and harvest keystrokes.
        guard LinkCrypto.verifyConfirmationMAC(
            accept.mac,
            master: master,
            credential: credential.bytes,
            transcript: transcript,
            role: .host
        ) else {
            throw LinkError.handshakeFailed(HandshakeReject(
                reason: .badCredential,
                detail: "Could not verify this Mac's identity. Pair again from the Mac's menu bar."
            ))
        }

        var issuedToken: Data?
        if let sealed = accept.sealedToken {
            issuedToken = try LinkCrypto.openToken(sealed, master: master)
        }

        await channel.activateEncryption(SessionCipher(master: master, role: .client))

        return ClientHandshakeResult(
            host: DeviceDescriptor(id: challenge.hostID, name: challenge.hostName),
            status: accept.status,
            issuedToken: issuedToken
        )
    }

    // MARK: Host side

    public struct HostConfiguration: Sendable {
        public var hostID: String
        public var hostName: String
        /// Returns the stored token for a known device, or nil if the device has never paired.
        public var tokenLookup: @Sendable (String) async -> Data?
        /// Called for an unknown device. Return the 6-digit code now displayed to the user, or nil to decline.
        public var beginPairing: @Sendable (DeviceDescriptor) async -> String?
        /// Reports the outcome so the UI can dismiss the pairing sheet.
        public var endPairing: @Sendable (DeviceDescriptor, Bool) async -> Void
        public var statusProvider: @Sendable () async -> HostStatus

        public init(
            hostID: String,
            hostName: String,
            tokenLookup: @escaping @Sendable (String) async -> Data?,
            beginPairing: @escaping @Sendable (DeviceDescriptor) async -> String?,
            endPairing: @escaping @Sendable (DeviceDescriptor, Bool) async -> Void,
            statusProvider: @escaping @Sendable () async -> HostStatus
        ) {
            self.hostID = hostID
            self.hostName = hostName
            self.tokenLookup = tokenLookup
            self.beginPairing = beginPairing
            self.endPairing = endPairing
            self.statusProvider = statusProvider
        }
    }

    /// Runs the Mac's half of the handshake.
    public static func runHost(
        channel: LinkChannel,
        configuration: HostConfiguration
    ) async throws -> HostHandshakeResult {
        let helloMessage = try await withLinkTimeout(stepTimeout) {
            try await channel.receive(HandshakeClientMessage.self)
        }
        guard case .hello(let hello) = helloMessage else {
            let reject = HandshakeReject(reason: .malformed, detail: "Expected a hello frame.")
            try? await channel.send(HandshakeHostMessage.reject(reject))
            throw LinkError.handshakeFailed(reject)
        }

        guard hello.version == LinkProtocol.version else {
            let reject = HandshakeReject(
                reason: .versionMismatch,
                detail: "That iPhone speaks MacLink v\(hello.version); this Mac speaks v\(LinkProtocol.version)."
            )
            try? await channel.send(HandshakeHostMessage.reject(reject))
            throw LinkError.handshakeFailed(reject)
        }

        let device = DeviceDescriptor(id: hello.deviceID, name: hello.deviceName)

        // A device that already has a token resumes silently; anything else has to be approved by a
        // human standing at the Mac.
        var credential: LinkCredential
        var isPairing = false
        if !hello.requestsPairing, let token = await configuration.tokenLookup(hello.deviceID) {
            credential = .token(token)
        } else {
            guard let code = await configuration.beginPairing(device) else {
                let reject = HandshakeReject(reason: .pairingDeclined, detail: "The Mac declined the pairing request.")
                try? await channel.send(HandshakeHostMessage.reject(reject))
                throw LinkError.handshakeFailed(reject)
            }
            credential = .pairingCode(code)
            isPairing = true
        }

        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let challenge = HandshakeChallenge(
            version: LinkProtocol.version,
            hostID: configuration.hostID,
            hostName: configuration.hostName,
            publicKey: privateKey.publicKey.rawRepresentation,
            salt: LinkCrypto.randomData(count: 32),
            pairingCodeRequired: isPairing
        )

        func finishPairing(_ success: Bool) async {
            if isPairing { await configuration.endPairing(device, success) }
        }

        do {
            try await channel.send(HandshakeHostMessage.challenge(challenge))

            let transcript = LinkCrypto.transcript(hello: hello, challenge: challenge)
            let master = try LinkCrypto.masterKey(
                privateKey: privateKey,
                peerPublicKey: hello.publicKey,
                salt: challenge.salt,
                transcript: transcript
            )

            let confirmMessage = try await withLinkTimeout(stepTimeout) {
                try await channel.receive(HandshakeClientMessage.self)
            }
            guard case .confirm(let confirm) = confirmMessage else {
                throw LinkError.protocolViolation("expected a confirm frame")
            }

            guard LinkCrypto.verifyConfirmationMAC(
                confirm.mac,
                master: master,
                credential: credential.bytes,
                transcript: transcript,
                role: .client
            ) else {
                let reject = HandshakeReject(
                    reason: .badCredential,
                    detail: isPairing ? "That pairing code was incorrect." : "This device's saved pairing is no longer valid."
                )
                try? await channel.send(HandshakeHostMessage.reject(reject))
                await finishPairing(false)
                throw LinkError.handshakeFailed(reject)
            }

            var issuedToken: Data?
            var sealedToken: Data?
            if isPairing {
                let token = LinkCrypto.makeToken()
                issuedToken = token
                sealedToken = try LinkCrypto.sealToken(token, master: master)
            }

            let accept = HandshakeAccept(
                mac: LinkCrypto.confirmationMAC(
                    master: master,
                    credential: credential.bytes,
                    transcript: transcript,
                    role: .host
                ),
                sealedToken: sealedToken,
                status: await configuration.statusProvider()
            )
            try await channel.send(HandshakeHostMessage.accept(accept))
            await channel.activateEncryption(SessionCipher(master: master, role: .host))
            await finishPairing(true)

            return HostHandshakeResult(device: device, issuedToken: issuedToken)
        } catch {
            await finishPairing(false)
            throw error
        }
    }
}

/// Races an operation against a deadline, cancelling the loser.
func withLinkTimeout<T: Sendable>(
    _ seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw LinkError.timedOut
        }
        guard let result = try await group.next() else {
            throw LinkError.timedOut
        }
        group.cancelAll()
        return result
    }
}
