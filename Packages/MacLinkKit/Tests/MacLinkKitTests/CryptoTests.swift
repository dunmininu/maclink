import CryptoKit
import XCTest
@testable import MacLinkKit

final class CryptoTests: XCTestCase {

    private func makePair(pairing: Bool) -> (hello: HandshakeHello, challenge: HandshakeChallenge, clientKey: Curve25519.KeyAgreement.PrivateKey, hostKey: Curve25519.KeyAgreement.PrivateKey) {
        let clientKey = Curve25519.KeyAgreement.PrivateKey()
        let hostKey = Curve25519.KeyAgreement.PrivateKey()
        let hello = HandshakeHello(
            version: LinkProtocol.version,
            deviceID: "device-1",
            deviceName: "iPhone",
            publicKey: clientKey.publicKey.rawRepresentation,
            requestsPairing: pairing
        )
        let challenge = HandshakeChallenge(
            version: LinkProtocol.version,
            hostID: "host-1",
            hostName: "MacBook",
            publicKey: hostKey.publicKey.rawRepresentation,
            salt: LinkCrypto.randomData(count: 32),
            pairingCodeRequired: pairing
        )
        return (hello, challenge, clientKey, hostKey)
    }

    func testBothSidesDeriveTheSameMasterKey() throws {
        let (hello, challenge, clientKey, hostKey) = makePair(pairing: true)
        let transcript = LinkCrypto.transcript(hello: hello, challenge: challenge)

        let clientMaster = try LinkCrypto.masterKey(
            privateKey: clientKey, peerPublicKey: challenge.publicKey, salt: challenge.salt, transcript: transcript
        )
        let hostMaster = try LinkCrypto.masterKey(
            privateKey: hostKey, peerPublicKey: hello.publicKey, salt: challenge.salt, transcript: transcript
        )
        XCTAssertEqual(clientMaster, hostMaster)
    }

    func testConfirmationMACRejectsTheWrongCode() throws {
        let (hello, challenge, clientKey, hostKey) = makePair(pairing: true)
        let transcript = LinkCrypto.transcript(hello: hello, challenge: challenge)
        let clientMaster = try LinkCrypto.masterKey(
            privateKey: clientKey, peerPublicKey: challenge.publicKey, salt: challenge.salt, transcript: transcript
        )
        let hostMaster = try LinkCrypto.masterKey(
            privateKey: hostKey, peerPublicKey: hello.publicKey, salt: challenge.salt, transcript: transcript
        )

        let mac = LinkCrypto.confirmationMAC(
            master: clientMaster, credential: Data("123456".utf8), transcript: transcript, role: .client
        )
        XCTAssertTrue(LinkCrypto.verifyConfirmationMAC(
            mac, master: hostMaster, credential: Data("123456".utf8), transcript: transcript, role: .client
        ))
        XCTAssertFalse(LinkCrypto.verifyConfirmationMAC(
            mac, master: hostMaster, credential: Data("654321".utf8), transcript: transcript, role: .client
        ))
    }

    func testTranscriptTamperingBreaksTheMAC() throws {
        let (hello, challenge, clientKey, hostKey) = makePair(pairing: true)
        let transcript = LinkCrypto.transcript(hello: hello, challenge: challenge)
        let clientMaster = try LinkCrypto.masterKey(
            privateKey: clientKey, peerPublicKey: challenge.publicKey, salt: challenge.salt, transcript: transcript
        )
        let hostMaster = try LinkCrypto.masterKey(
            privateKey: hostKey, peerPublicKey: hello.publicKey, salt: challenge.salt, transcript: transcript
        )

        var tampered = challenge
        tampered.hostName = "Evil Mac"
        let tamperedTranscript = LinkCrypto.transcript(hello: hello, challenge: tampered)

        let mac = LinkCrypto.confirmationMAC(
            master: clientMaster, credential: Data("000000".utf8), transcript: transcript, role: .client
        )
        XCTAssertFalse(LinkCrypto.verifyConfirmationMAC(
            mac, master: hostMaster, credential: Data("000000".utf8), transcript: tamperedTranscript, role: .client
        ))
    }

    func testClientAndHostMACsAreDistinct() throws {
        let (hello, challenge, clientKey, _) = makePair(pairing: false)
        let transcript = LinkCrypto.transcript(hello: hello, challenge: challenge)
        let master = try LinkCrypto.masterKey(
            privateKey: clientKey, peerPublicKey: challenge.publicKey, salt: challenge.salt, transcript: transcript
        )
        let credential = LinkCrypto.makeToken()

        let clientMAC = LinkCrypto.confirmationMAC(master: master, credential: credential, transcript: transcript, role: .client)
        let hostMAC = LinkCrypto.confirmationMAC(master: master, credential: credential, transcript: transcript, role: .host)

        // A reflected client MAC must not authenticate the host.
        XCTAssertNotEqual(clientMAC, hostMAC)
        XCTAssertFalse(LinkCrypto.verifyConfirmationMAC(
            clientMAC, master: master, credential: credential, transcript: transcript, role: .host
        ))
    }

    func testSessionCipherRoundTripsInOrder() throws {
        let master = SymmetricKey(size: .bits256)
        let client = SessionCipher(master: master, role: .client)
        let host = SessionCipher(master: master, role: .host)

        for index in 0..<64 {
            let plaintext = Data("payload-\(index)".utf8)
            let sealed = try client.seal(plaintext)
            XCTAssertNotEqual(sealed, plaintext)
            XCTAssertEqual(try host.open(sealed), plaintext)
        }
    }

    func testSessionCipherRejectsTamperedRecords() throws {
        let master = SymmetricKey(size: .bits256)
        let client = SessionCipher(master: master, role: .client)
        let host = SessionCipher(master: master, role: .host)

        var sealed = try client.seal(Data("hello".utf8))
        sealed[sealed.startIndex] ^= 0xFF
        XCTAssertThrowsError(try host.open(sealed))
    }

    /// Regression: sealed records must be zero-based Data. CryptoKit returns `ciphertext` as a slice
    /// of its combined buffer, so a naive `ciphertext + tag` yields a Data whose `startIndex` is 12
    /// and traps on absolute indexing.
    func testSealedRecordIsZeroBased() throws {
        let cipher = SessionCipher(master: SymmetricKey(size: .bits256), role: .client)
        let sealed = try cipher.seal(Data("hello".utf8))
        XCTAssertEqual(sealed.startIndex, 0)
        XCTAssertEqual(sealed.count, 5 + 16)
    }

    func testOpenSurvivesASlicedRecord() throws {
        let master = SymmetricKey(size: .bits256)
        let client = SessionCipher(master: master, role: .client)
        let host = SessionCipher(master: master, role: .host)

        let sealed = try client.seal(Data("payload".utf8))
        // Simulate a record that arrives as a slice of a larger buffer.
        let padded = Data(repeating: 0, count: 8) + sealed
        let slice = padded.dropFirst(8)
        XCTAssertNotEqual(slice.startIndex, 0)
        XCTAssertEqual(try host.open(slice), Data("payload".utf8))
    }

    func testSessionCipherRejectsReplay() throws {
        let master = SymmetricKey(size: .bits256)
        let client = SessionCipher(master: master, role: .client)
        let host = SessionCipher(master: master, role: .host)

        let first = try client.seal(Data("one".utf8))
        XCTAssertEqual(try host.open(first), Data("one".utf8))
        // The counter has advanced, so replaying the same record no longer authenticates.
        XCTAssertThrowsError(try host.open(first))
    }

    func testTokenSealing() throws {
        let master = SymmetricKey(size: .bits256)
        let token = LinkCrypto.makeToken()
        let sealed = try LinkCrypto.sealToken(token, master: master)
        XCTAssertEqual(try LinkCrypto.openToken(sealed, master: master), token)
        XCTAssertThrowsError(try LinkCrypto.openToken(sealed, master: SymmetricKey(size: .bits256)))
    }

    func testPairingCodeShape() {
        for _ in 0..<200 {
            let code = LinkCrypto.makePairingCode()
            XCTAssertEqual(code.count, 6)
            XCTAssertTrue(code.allSatisfy(\.isNumber))
        }
    }
}

final class ProtocolCodingTests: XCTestCase {

    func testPointerEventsRoundTrip() throws {
        let cases: [ClientMessage] = [
            .ping,
            .pointer(.move(dx: 12.5, dy: -3)),
            .pointer(.scroll(dx: 0, dy: 40, phase: .changed)),
            .pointer(.button(button: .right, action: .down, clickCount: 1)),
            .pointer(.zoom(magnification: 0.05, phase: .began)),
            .keyboard(.text("hello world")),
            .keyboard(.key(.character("c"), modifiers: [.command])),
            .keyboard(.key(.special(.up), modifiers: [])),
            .media(.playPause),
            .system(.missionControl),
            .clipboardPush(text: "copied"),
            .clipboardPull,
            .requestStatus,
        ]

        for message in cases {
            let data = try LinkJSON.encode(message)
            XCTAssertEqual(try LinkJSON.decode(ClientMessage.self, from: data), message)
        }
    }

    func testHostMessagesRoundTrip() throws {
        let status = HostStatus(
            hostName: "MacBook Pro",
            accessibilityGranted: true,
            volume: 0.4,
            muted: false,
            batteryLevel: 0.82,
            isCharging: true,
            frontmostApp: "Xcode"
        )
        let cases: [HostMessage] = [.pong, .status(status), .clipboard(text: "x"), .notice(Notice(level: .warning, message: "y"))]
        for message in cases {
            let data = try LinkJSON.encode(message)
            XCTAssertEqual(try LinkJSON.decode(HostMessage.self, from: data), message)
        }
    }

    func testModifiersAreStable() throws {
        let modifiers: KeyModifiers = [.command, .shift]
        let data = try LinkJSON.encode(modifiers)
        XCTAssertEqual(try LinkJSON.decode(KeyModifiers.self, from: data), modifiers)
    }
}
