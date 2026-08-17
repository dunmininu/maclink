import Foundation
import Network

/// One connected phone, from the Mac's point of view.
@MainActor
public final class HostSession: Identifiable {
    public let id = UUID()
    public private(set) var device: DeviceDescriptor?
    public let remoteDescription: String

    private let channel: LinkChannel
    private var readTask: Task<Void, Never>?

    init(channel: LinkChannel, remoteDescription: String) {
        self.channel = channel
        self.remoteDescription = remoteDescription
    }

    fileprivate func adopt(device: DeviceDescriptor) {
        self.device = device
    }

    public func send(_ message: HostMessage) {
        Task { [channel] in
            try? await channel.send(message)
        }
    }

    fileprivate func beginReading(
        onMessage: @escaping @MainActor (ClientMessage) -> Void,
        onClose: @escaping @MainActor (Error?) -> Void
    ) {
        readTask = Task { [channel] in
            do {
                while !Task.isCancelled {
                    let message = try await channel.receive(ClientMessage.self)
                    await MainActor.run { onMessage(message) }
                }
                await MainActor.run { onClose(nil) }
            } catch {
                await MainActor.run { onClose(Task.isCancelled ? nil : error) }
            }
        }
    }

    public func disconnect() {
        readTask?.cancel()
        readTask = nil
        Task { [channel] in await channel.cancel() }
    }
}

/// Listens for phones on the local network and runs the Mac side of the link.
@MainActor
public final class HostServer {

    public enum State: Equatable {
        case stopped
        case starting
        case running(port: UInt16)
        case failed(String)
    }

    public private(set) var state: State = .stopped {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    public private(set) var sessions: [HostSession] = []

    // MARK: Hooks

    public var onStateChange: ((State) -> Void)?
    public var onSessionsChange: (([HostSession]) -> Void)?
    /// Fires for every decoded message from a paired phone.
    public var onMessage: ((ClientMessage, HostSession) -> Void)?
    /// Unknown device wants in. Return the 6-digit code you are now showing the user, or nil to decline.
    public var onPairingRequest: ((DeviceDescriptor) -> String?)?
    public var onPairingFinished: ((DeviceDescriptor, Bool) -> Void)?
    public var tokenLookup: ((String) -> Data?)?
    public var onDevicePaired: ((DeviceDescriptor, Data) -> Void)?
    public var statusProvider: (() -> HostStatus)?
    public var onLog: ((String) -> Void)?

    private let hostID: String
    private var hostName: String
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "africa.myladder.maclink.host", qos: .userInteractive)

    public init(hostID: String, hostName: String) {
        self.hostID = hostID
        self.hostName = hostName
    }

    /// - Parameter advertisesService: When false the listener accepts connections but publishes no
    ///   Bonjour record, so the only way in is a known address and port. Used by the tests, and a
    ///   reasonable knob for anyone who would rather not broadcast their Mac's name.
    public func start(advertisesService: Bool = true) {
        guard listener == nil else { return }
        state = .starting

        do {
            let listener = try NWListener(using: LinkParameters.tcp())

            if advertisesService {
                var txt = NWTXTRecord()
                txt[LinkProtocol.TXTKey.hostID] = hostID
                txt[LinkProtocol.TXTKey.hostName] = hostName
                txt[LinkProtocol.TXTKey.version] = String(LinkProtocol.version)
                listener.service = NWListener.Service(
                    name: hostName,
                    type: LinkProtocol.serviceType,
                    domain: nil,
                    txtRecord: txt
                )
            }

            listener.stateUpdateHandler = { [weak self] newState in
                Task { @MainActor in self?.handleListenerState(newState) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }

            self.listener = listener
            listener.start(queue: queue)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    public func stop() {
        for session in sessions { session.disconnect() }
        sessions = []
        onSessionsChange?(sessions)
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        state = .stopped
    }

    public func restart(hostName newName: String? = nil) {
        if let newName { hostName = newName }
        stop()
        start()
    }

    /// Drops any live session belonging to a device, e.g. after the user revokes it.
    public func disconnectSessions(forDeviceID deviceID: String) {
        let doomed = sessions.filter { $0.device?.id == deviceID }
        for session in doomed { session.disconnect() }
        sessions.removeAll { session in doomed.contains { $0.id == session.id } }
        onSessionsChange?(sessions)
    }

    public func broadcast(_ message: HostMessage) {
        for session in sessions { session.send(message) }
    }

    // MARK: Internals

    // Small main-actor shims so the handshake's `@Sendable` callbacks can reach the hooks above
    // without capturing `self` inside a nested concurrent closure.
    private func resolveToken(for deviceID: String) -> Data? {
        tokenLookup?(deviceID)
    }

    private func requestPairing(for device: DeviceDescriptor) -> String? {
        onPairingRequest?(device)
    }

    private func reportPairing(for device: DeviceDescriptor, success: Bool) {
        onPairingFinished?(device, success)
    }

    private func currentStatus() -> HostStatus {
        statusProvider?() ?? HostStatus(hostName: hostName, accessibilityGranted: false)
    }

    private func handleListenerState(_ newState: NWListener.State) {
        switch newState {
        case .ready:
            state = .running(port: listener?.port?.rawValue ?? 0)
            onLog?("Listening on port \(listener?.port?.rawValue ?? 0) as \"\(hostName)\"")
        case .failed(let error):
            state = .failed(error.localizedDescription)
            onLog?("Listener failed: \(error.localizedDescription)")
            listener = nil
        case .cancelled:
            state = .stopped
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let channel = LinkChannel(connection: connection)
        let session = HostSession(channel: channel, remoteDescription: String(describing: connection.endpoint))

        let configuration = Handshake.HostConfiguration(
            hostID: hostID,
            hostName: hostName,
            tokenLookup: { [weak self] deviceID in
                guard let self else { return nil }
                return await self.resolveToken(for: deviceID)
            },
            beginPairing: { [weak self] device in
                guard let self else { return nil }
                return await self.requestPairing(for: device)
            },
            endPairing: { [weak self] device, success in
                await self?.reportPairing(for: device, success: success)
            },
            statusProvider: { [weak self] in
                guard let self else { return HostStatus(hostName: "Mac", accessibilityGranted: false) }
                return await self.currentStatus()
            }
        )

        Task { @MainActor in
            do {
                try await channel.start(on: queue)
                let result = try await Handshake.runHost(channel: channel, configuration: configuration)

                session.adopt(device: result.device)
                if let token = result.issuedToken {
                    onDevicePaired?(result.device, token)
                }

                sessions.append(session)
                onSessionsChange?(sessions)
                onLog?("\(result.device.name) connected")

                session.beginReading(
                    onMessage: { [weak self] message in
                        self?.onMessage?(message, session)
                    },
                    onClose: { [weak self] error in
                        self?.finish(session, error: error)
                    }
                )
            } catch {
                onLog?("Handshake failed: \(error.localizedDescription)")
                await channel.cancel()
            }
        }
    }

    private func finish(_ session: HostSession, error: Error?) {
        session.disconnect()
        guard sessions.contains(where: { $0.id == session.id }) else { return }
        sessions.removeAll { $0.id == session.id }
        onSessionsChange?(sessions)
        if let name = session.device?.name {
            onLog?("\(name) disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
        }
    }
}
