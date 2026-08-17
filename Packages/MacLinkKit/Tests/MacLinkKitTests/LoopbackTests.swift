import Network
import XCTest
@testable import MacLinkKit

/// End-to-end tests that run a real `HostServer` and a real `ClientLink` over a real TCP connection
/// on loopback. Bonjour is skipped (the client dials 127.0.0.1 directly) so the tests exercise the
/// handshake, framing and encryption without depending on the network environment.
@MainActor
final class LoopbackTests: XCTestCase {

    private var server: HostServer!
    private var client: ClientLink!

    // Recorded host-side state.
    private var pairingCode = "482913"
    private var pairingRequests: [DeviceDescriptor] = []
    private var issuedTokens: [String: Data] = [:]
    private var received: [ClientMessage] = []
    private var hostStatus = HostStatus(
        hostName: "Test Mac",
        accessibilityGranted: true,
        volume: 0.5,
        muted: false,
        batteryLevel: 0.9,
        isCharging: false,
        frontmostApp: "Finder"
    )

    override func tearDown() async throws {
        client?.disconnect()
        server?.stop()
        client = nil
        server = nil
        try await super.tearDown()
    }

    // MARK: Harness

    private func startServer() async throws -> UInt16 {
        let server = HostServer(hostID: "host-under-test", hostName: "Test Mac")
        server.onPairingRequest = { [weak self] device in
            self?.pairingRequests.append(device)
            return self?.pairingCode
        }
        server.tokenLookup = { [weak self] deviceID in
            self?.issuedTokens[deviceID]
        }
        server.onDevicePaired = { [weak self] device, token in
            self?.issuedTokens[device.id] = token
        }
        server.statusProvider = { [weak self] in
            self?.hostStatus ?? HostStatus(hostName: "Test Mac", accessibilityGranted: false)
        }
        server.onMessage = { [weak self] message, _ in
            self?.received.append(message)
        }
        self.server = server

        server.start(advertisesService: false)

        var port: UInt16 = 0
        try await waitUntil("listener is running") {
            if case .running(let value) = server.state, value != 0 {
                port = value
                return true
            }
            return false
        }
        return port
    }

    private func makeClient(name: String = "Test iPhone", deviceID: String = "device-under-test") -> ClientLink {
        let link = ClientLink(identity: DeviceDescriptor(id: deviceID, name: name))
        link.onTokenIssued = { [weak self] hostID, token in
            self?.clientTokens[hostID] = token
        }
        client = link
        return link
    }

    private var clientTokens: [String: Data] = [:]

    private func endpoint(port: UInt16) -> NWEndpoint {
        .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
    }

    /// Polls until the condition holds. Simpler and less flaky here than juggling expectations
    /// across two actors that both hop to the main queue.
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 10,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for: \(description)")
        throw LinkError.timedOut
    }

    // MARK: Tests

    func testPairsWithACodeThenResumesWithTheStoredToken() async throws {
        let port = try await startServer()

        // First run: no stored token, so the host asks for a pairing code.
        let link = makeClient()
        link.pairingCodeProvider = { [pairingCode] in pairingCode }
        link.connect(to: endpoint(port: port), storedToken: nil)

        try await waitUntil("client connects") { link.isConnected }

        XCTAssertEqual(pairingRequests.count, 1)
        XCTAssertEqual(pairingRequests.first?.name, "Test iPhone")
        XCTAssertEqual(link.host?.name, "Test Mac")
        XCTAssertEqual(link.host?.id, "host-under-test")

        // Both ends must have ended up with the same token.
        let hostToken = try XCTUnwrap(issuedTokens["device-under-test"])
        let clientToken = try XCTUnwrap(clientTokens["host-under-test"])
        XCTAssertEqual(hostToken, clientToken)
        XCTAssertEqual(hostToken.count, 32)

        // The accepted status rides along with the handshake.
        guard case .connected(let status) = link.state else {
            return XCTFail("expected a connected state")
        }
        XCTAssertEqual(status.hostName, "Test Mac")
        XCTAssertEqual(status.frontmostApp, "Finder")

        link.disconnect()
        try await waitUntil("server drops the session") { self.server.sessions.isEmpty }

        // Second run: the stored token should get us in with no pairing prompt.
        let resumed = makeClient()
        resumed.pairingCodeProvider = { XCTFail("should not be asked to pair again"); return "000000" }
        resumed.connect(to: endpoint(port: port), storedToken: clientToken)

        try await waitUntil("client resumes") { resumed.isConnected }
        XCTAssertEqual(pairingRequests.count, 1, "resuming must not trigger a second pairing request")
    }

    func testMessagesArriveIntactOverTheEncryptedChannel() async throws {
        let port = try await startServer()
        let link = makeClient()
        link.pairingCodeProvider = { [pairingCode] in pairingCode }
        link.connect(to: endpoint(port: port), storedToken: nil)
        try await waitUntil("client connects") { link.isConnected }

        let sent: [ClientMessage] = [
            .pointer(.move(dx: 12.25, dy: -7.5)),
            .pointer(.scroll(dx: 0, dy: 44, phase: .began)),
            .pointer(.button(button: .right, action: .down, clickCount: 2)),
            .keyboard(.text("hello ünïcode 🎉")),
            .keyboard(.key(.character("c"), modifiers: [.command, .shift])),
            .media(.playPause),
            .setVolume(0.33),
            .system(.missionControl),
            .clipboardPush(text: String(repeating: "abc ", count: 500)),
        ]
        for message in sent { link.send(message) }

        try await waitUntil("all messages arrive") { self.received.count >= sent.count }
        // Ordering matters for input events; the transport must not reorder them.
        XCTAssertEqual(Array(received.prefix(sent.count)), sent)
    }

    func testHostRepliesReachTheClient() async throws {
        let port = try await startServer()
        let link = makeClient()
        link.pairingCodeProvider = { [pairingCode] in pairingCode }

        var hostMessages: [HostMessage] = []
        link.onHostMessage = { hostMessages.append($0) }
        link.connect(to: endpoint(port: port), storedToken: nil)
        try await waitUntil("client connects") { link.isConnected }

        server.broadcast(.clipboard(text: "from the mac"))
        server.broadcast(.notice(Notice(level: .warning, message: "heads up")))

        try await waitUntil("replies arrive") { hostMessages.count >= 2 }
        XCTAssertEqual(hostMessages[0], .clipboard(text: "from the mac"))
        XCTAssertEqual(hostMessages[1], .notice(Notice(level: .warning, message: "heads up")))
    }

    func testWrongPairingCodeIsRejected() async throws {
        let port = try await startServer()
        let link = makeClient()
        link.pairingCodeProvider = { "000000" }
        link.connect(to: endpoint(port: port), storedToken: nil)

        try await waitUntil("client is rejected") {
            if case .failed = link.state { return true }
            return false
        }
        XCTAssertFalse(link.isConnected)
        XCTAssertTrue(issuedTokens.isEmpty, "no token may be issued for a failed pairing")
        XCTAssertTrue(server.sessions.isEmpty)
    }

    func testRevokedTokenIsRejected() async throws {
        let port = try await startServer()
        let link = makeClient()
        link.pairingCodeProvider = { [pairingCode] in pairingCode }
        link.connect(to: endpoint(port: port), storedToken: nil)
        try await waitUntil("client connects") { link.isConnected }
        link.disconnect()
        try await waitUntil("session drops") { self.server.sessions.isEmpty }

        // The Mac revokes the device, then the phone tries its now-stale token.
        issuedTokens.removeAll()
        pairingCode = "111111"

        let stale = makeClient()
        stale.pairingCodeProvider = { "999999" }   // user declines / mistypes the new code
        stale.connect(to: endpoint(port: port), storedToken: Data(repeating: 7, count: 32))

        try await waitUntil("stale token is refused") {
            if case .failed = stale.state { return true }
            return false
        }
        XCTAssertFalse(stale.isConnected)
        // A revoked device must fall back to a fresh, human-approved pairing rather than silently
        // getting back in.
        XCTAssertEqual(pairingRequests.count, 2)
    }

    func testDeclinedPairingIsRejected() async throws {
        let port = try await startServer()
        server.onPairingRequest = { [weak self] device in
            self?.pairingRequests.append(device)
            return nil   // the Mac says no
        }

        let link = makeClient()
        link.pairingCodeProvider = { XCTFail("should never be asked for a code"); return "000000" }
        link.connect(to: endpoint(port: port), storedToken: nil)

        try await waitUntil("client is refused") {
            if case .failed = link.state { return true }
            return false
        }
        XCTAssertFalse(link.isConnected)
    }
}
