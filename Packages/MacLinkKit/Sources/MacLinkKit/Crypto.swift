import CryptoKit
import Foundation

/// Key agreement and record encryption for the link.
///
/// Threat model: both devices sit on the same LAN, but so might other people. Every session runs a
/// fresh X25519 exchange, and the exchange is authenticated with a credential that only the two ends
/// know — a 6-digit code the Mac displays during pairing, then a random 32-byte token afterwards.
/// An attacker who cannot produce the credential cannot complete the handshake, and because the
/// session key comes from an ephemeral exchange, recording traffic today does not decrypt it later.
public enum LinkCrypto {

    // MARK: Labels

    private static let masterInfo = Data("maclink/v1/master".utf8)
    private static let confirmInfo = Data("maclink/v1/confirm".utf8)
    private static let clientToHostInfo = Data("maclink/v1/c2h".utf8)
    private static let hostToClientInfo = Data("maclink/v1/h2c".utf8)
    private static let tokenSealInfo = Data("maclink/v1/token".utf8)
    private static let clientTag = Data("client".utf8)
    private static let hostTag = Data("host".utf8)

    // MARK: Random

    public static func randomData(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        // SecRandomCopyBytes is the platform CSPRNG; fall back to SystemRandomNumberGenerator if it
        // ever fails so we never hand back predictable bytes.
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            bytes = (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        return Data(bytes)
    }

    /// A 6-digit pairing code, zero padded, drawn uniformly.
    public static func makePairingCode() -> String {
        var value: UInt32 = 0
        repeat {
            let bytes = randomData(count: 4)
            value = bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            // Reject the tail of the range so the modulo below stays uniform.
        } while value >= (UInt32.max - (UInt32.max % 1_000_000))
        return String(format: "%06u", value % 1_000_000)
    }

    public static func makeToken() -> Data { randomData(count: 32) }

    // MARK: Key schedule

    /// Everything both sides must agree on, hashed into one blob so a tampered handshake fails the MAC check.
    public static func transcript(hello: HandshakeHello, challenge: HandshakeChallenge) -> Data {
        var hasher = SHA256()
        hasher.update(data: Data("maclink/v1".utf8))
        hasher.update(data: Data(withUnsafeBytes(of: UInt32(hello.version).bigEndian) { Data($0) }))
        hasher.update(data: Data(hello.deviceID.utf8))
        hasher.update(data: Data(hello.deviceName.utf8))
        hasher.update(data: hello.publicKey)
        hasher.update(data: Data([hello.requestsPairing ? 1 : 0]))
        hasher.update(data: Data(challenge.hostID.utf8))
        hasher.update(data: Data(challenge.hostName.utf8))
        hasher.update(data: challenge.publicKey)
        hasher.update(data: challenge.salt)
        hasher.update(data: Data([challenge.pairingCodeRequired ? 1 : 0]))
        return Data(hasher.finalize())
    }

    public static func masterKey(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        peerPublicKey: Data,
        salt: Data,
        transcript: Data
    ) throws -> SymmetricKey {
        let peer: Curve25519.KeyAgreement.PublicKey
        do {
            peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        } catch {
            throw LinkError.cryptoFailure("peer sent an invalid public key")
        }
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: masterInfo + transcript,
            outputByteCount: 32
        )
    }

    /// Binds the ephemeral exchange to the shared credential (pairing code or stored token).
    private static func confirmationKey(master: SymmetricKey, credential: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: master.withUnsafeBytes { Data($0) } + credential),
            info: confirmInfo,
            outputByteCount: 32
        )
    }

    public static func confirmationMAC(
        master: SymmetricKey,
        credential: Data,
        transcript: Data,
        role: Role
    ) -> Data {
        let key = confirmationKey(master: master, credential: credential)
        let tag = role == .client ? clientTag : hostTag
        return Data(HMAC<SHA256>.authenticationCode(for: tag + transcript, using: key))
    }

    public static func verifyConfirmationMAC(
        _ mac: Data,
        master: SymmetricKey,
        credential: Data,
        transcript: Data,
        role: Role
    ) -> Bool {
        let expected = confirmationMAC(master: master, credential: credential, transcript: transcript, role: role)
        // Constant-time comparison; `==` on Data short-circuits.
        guard expected.count == mac.count else { return false }
        var difference: UInt8 = 0
        for (lhs, rhs) in zip(expected, mac) { difference |= lhs ^ rhs }
        return difference == 0
    }

    public enum Role: Sendable {
        case client
        case host
    }

    public static func sessionKeys(master: SymmetricKey) -> (clientToHost: SymmetricKey, hostToClient: SymmetricKey) {
        let c2h = HKDF<SHA256>.deriveKey(inputKeyMaterial: master, info: clientToHostInfo, outputByteCount: 32)
        let h2c = HKDF<SHA256>.deriveKey(inputKeyMaterial: master, info: hostToClientInfo, outputByteCount: 32)
        return (c2h, h2c)
    }

    // MARK: Token sealing

    public static func sealToken(_ token: Data, master: SymmetricKey) throws -> Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: master, info: tokenSealInfo, outputByteCount: 32)
        return try ChaChaPoly.seal(token, using: key).combined
    }

    public static func openToken(_ sealed: Data, master: SymmetricKey) throws -> Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: master, info: tokenSealInfo, outputByteCount: 32)
        let box = try ChaChaPoly.SealedBox(combined: sealed)
        return try ChaChaPoly.open(box, using: key)
    }
}

/// Encrypts and decrypts the framed records that follow a successful handshake.
///
/// Nonces are a per-direction counter rather than random bytes. TCP gives us in-order delivery, so
/// both ends stay in lockstep, and a counter can never repeat the way random 96-bit nonces might.
public final class SessionCipher: @unchecked Sendable {
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0
    private let lock = NSLock()

    public init(sendKey: SymmetricKey, receiveKey: SymmetricKey) {
        self.sendKey = sendKey
        self.receiveKey = receiveKey
    }

    public convenience init(master: SymmetricKey, role: LinkCrypto.Role) {
        let keys = LinkCrypto.sessionKeys(master: master)
        switch role {
        case .client:
            self.init(sendKey: keys.clientToHost, receiveKey: keys.hostToClient)
        case .host:
            self.init(sendKey: keys.hostToClient, receiveKey: keys.clientToHost)
        }
    }

    private static func nonce(counter: UInt64) throws -> ChaChaPoly.Nonce {
        var bytes = Data(repeating: 0, count: 4)
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
        return try ChaChaPoly.Nonce(data: bytes)
    }

    public func seal(_ plaintext: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        let nonce = try Self.nonce(counter: sendCounter)
        sendCounter &+= 1
        let box = try ChaChaPoly.seal(plaintext, using: sendKey, nonce: nonce)
        // The nonce is implicit, so only ciphertext + tag go on the wire.
        //
        // Built by appending into a fresh buffer rather than `box.ciphertext + box.tag`: CryptoKit
        // hands back `ciphertext` as a slice of its combined representation, so the `+` result would
        // keep that slice's non-zero `startIndex` and trap on any absolute-index access downstream.
        var record = Data(capacity: box.ciphertext.count + 16)
        record.append(box.ciphertext)
        record.append(box.tag)
        return record
    }

    public func open(_ record: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard record.count >= 16 else {
            throw LinkError.cryptoFailure("record too short")
        }
        let nonce = try Self.nonce(counter: receiveCounter)
        let ciphertext = record.prefix(record.count - 16)
        let tag = record.suffix(16)
        let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        do {
            let plaintext = try ChaChaPoly.open(box, using: receiveKey)
            receiveCounter &+= 1
            return plaintext
        } catch {
            throw LinkError.cryptoFailure("record failed authentication")
        }
    }
}
