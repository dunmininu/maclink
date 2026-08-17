import Foundation

/// Constants that pin both ends of the link to the same wire contract.
public enum LinkProtocol {
    public static let version = 1

    /// Bonjour service type. Must also be listed in the iOS app's `NSBonjourServices`.
    public static let serviceType = "_maclink._tcp"
    public static let domain = "local."

    /// Frames larger than this are treated as a protocol violation (clipboard payloads are capped below it).
    public static let maxFrameSize = 4 * 1024 * 1024

    /// Largest clipboard payload we are willing to move across the link.
    public static let maxClipboardBytes = 512 * 1024

    /// TXT record keys published by the host.
    public enum TXTKey {
        public static let hostID = "id"
        public static let hostName = "name"
        public static let version = "v"
    }
}

// MARK: - Client → host

public enum ClientMessage: Codable, Sendable, Equatable {
    case ping
    case pointer(PointerEvent)
    case keyboard(KeyboardEvent)
    case media(MediaCommand)
    /// Absolute output volume, 0...1. Backs the slider on the phone.
    case setVolume(Double)
    case system(SystemCommand)
    case clipboardPush(text: String)
    case clipboardPull
    case requestStatus
}

public enum GesturePhase: String, Codable, Sendable, Equatable {
    case began, changed, ended, cancelled
}

public enum MouseButton: String, Codable, Sendable {
    case left, right, middle
}

public enum ButtonAction: String, Codable, Sendable {
    case down, up
}

public enum PointerEvent: Codable, Sendable, Equatable {
    /// Relative cursor motion in points, already scaled/accelerated by the client.
    case move(dx: Double, dy: Double)
    /// Pixel-unit scroll deltas. Positive `dy` scrolls content the same way a two-finger swipe up does.
    case scroll(dx: Double, dy: Double, phase: GesturePhase)
    case button(button: MouseButton, action: ButtonAction, clickCount: Int)
    /// Pinch magnification, expressed as a per-event delta (0 == no change).
    case zoom(magnification: Double, phase: GesturePhase)
}

public enum KeyboardEvent: Codable, Sendable, Equatable {
    /// Literal text, typed layout-independently.
    case text(String)
    /// A single keystroke, optionally with modifiers held. Used for shortcuts and navigation keys.
    case key(KeyCode, modifiers: KeyModifiers)
}

public enum KeyCode: Codable, Sendable, Hashable {
    /// A character on the US-ANSI layout, used to resolve a virtual key code for shortcuts (e.g. ⌘ + "c").
    case character(String)
    case special(SpecialKey)
}

public enum SpecialKey: String, Codable, Sendable, Hashable, CaseIterable {
    case returnKey, enterKey, tab, space, escape, delete, forwardDelete
    case up, down, left, right
    case home, end, pageUp, pageDown
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
}

public struct KeyModifiers: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let shift = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let control = KeyModifiers(rawValue: 1 << 3)
    public static let function = KeyModifiers(rawValue: 1 << 4)
}

public enum MediaCommand: String, Codable, Sendable, CaseIterable {
    case playPause, nextTrack, previousTrack
    case volumeUp, volumeDown, mute
    case brightnessUp, brightnessDown
    case keyboardBrightnessUp, keyboardBrightnessDown
}

public enum SystemCommand: String, Codable, Sendable, CaseIterable {
    case missionControl, applicationWindows, showDesktop, launchpad
    case spaceLeft, spaceRight
    case lockScreen, sleepDisplay, sleepSystem
    case screenshotRegion, screenshotFull
    case quitApp, closeWindow, switchAppForward, switchAppBackward
}

// MARK: - Host → client

public enum HostMessage: Codable, Sendable, Equatable {
    case pong
    case status(HostStatus)
    case clipboard(text: String)
    case notice(Notice)
}

public struct HostStatus: Codable, Sendable, Equatable {
    public var hostName: String
    public var accessibilityGranted: Bool
    public var volume: Double?
    public var muted: Bool
    public var batteryLevel: Double?
    public var isCharging: Bool
    public var frontmostApp: String?
    /// Width of the union of all active displays, in points. The phone scales pointer motion by this
    /// so one swipe crosses the same fraction of the desktop on a laptop screen or a 4K monitor.
    public var displayWidth: Double?
    public var displayHeight: Double?

    public init(
        hostName: String,
        accessibilityGranted: Bool,
        volume: Double? = nil,
        muted: Bool = false,
        batteryLevel: Double? = nil,
        isCharging: Bool = false,
        frontmostApp: String? = nil,
        displayWidth: Double? = nil,
        displayHeight: Double? = nil
    ) {
        self.hostName = hostName
        self.accessibilityGranted = accessibilityGranted
        self.volume = volume
        self.muted = muted
        self.batteryLevel = batteryLevel
        self.isCharging = isCharging
        self.frontmostApp = frontmostApp
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
    }
}

public struct Notice: Codable, Sendable, Equatable {
    public enum Level: String, Codable, Sendable { case info, warning, error }
    public var level: Level
    public var message: String

    public init(level: Level, message: String) {
        self.level = level
        self.message = message
    }
}

// MARK: - Handshake (plaintext phase)

public enum HandshakeClientMessage: Codable, Sendable {
    case hello(HandshakeHello)
    case confirm(HandshakeConfirm)
}

public enum HandshakeHostMessage: Codable, Sendable {
    case challenge(HandshakeChallenge)
    case accept(HandshakeAccept)
    case reject(HandshakeReject)
}

public struct HandshakeHello: Codable, Sendable {
    public var version: Int
    public var deviceID: String
    public var deviceName: String
    /// Ephemeral X25519 public key for this session.
    public var publicKey: Data
    /// `true` when the client has no stored token and wants to pair with a code.
    public var requestsPairing: Bool

    public init(version: Int, deviceID: String, deviceName: String, publicKey: Data, requestsPairing: Bool) {
        self.version = version
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.publicKey = publicKey
        self.requestsPairing = requestsPairing
    }
}

public struct HandshakeChallenge: Codable, Sendable {
    public var version: Int
    public var hostID: String
    public var hostName: String
    public var publicKey: Data
    public var salt: Data
    /// `true` when the host is showing a pairing code that the user must type on the phone.
    public var pairingCodeRequired: Bool

    public init(version: Int, hostID: String, hostName: String, publicKey: Data, salt: Data, pairingCodeRequired: Bool) {
        self.version = version
        self.hostID = hostID
        self.hostName = hostName
        self.publicKey = publicKey
        self.salt = salt
        self.pairingCodeRequired = pairingCodeRequired
    }
}

public struct HandshakeConfirm: Codable, Sendable {
    public var mac: Data
    public init(mac: Data) { self.mac = mac }
}

public struct HandshakeAccept: Codable, Sendable {
    public var mac: Data
    /// Long-lived token for this device, sealed under the session key. Only sent when pairing.
    public var sealedToken: Data?
    public var status: HostStatus

    public init(mac: Data, sealedToken: Data?, status: HostStatus) {
        self.mac = mac
        self.sealedToken = sealedToken
        self.status = status
    }
}

public struct HandshakeReject: Codable, Sendable {
    public enum Reason: String, Codable, Sendable {
        case versionMismatch
        case unknownDevice
        case badCredential
        case pairingDeclined
        case pairingTimeout
        case busy
        case malformed
    }

    public var reason: Reason
    public var detail: String

    public init(reason: Reason, detail: String) {
        self.reason = reason
        self.detail = detail
    }
}

// MARK: - Errors

public enum LinkError: LocalizedError, Sendable {
    case connectionClosed
    case handshakeFailed(HandshakeReject)
    case protocolViolation(String)
    case cryptoFailure(String)
    case timedOut
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .connectionClosed:
            return "The connection to your Mac was closed."
        case .handshakeFailed(let reject):
            return reject.detail
        case .protocolViolation(let detail):
            return "Protocol error: \(detail)"
        case .cryptoFailure(let detail):
            return "Secure channel error: \(detail)"
        case .timedOut:
            return "The Mac did not respond in time."
        case .notConnected:
            return "Not connected to a Mac."
        }
    }
}

// MARK: - JSON helpers

public enum LinkJSON {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        return encoder
    }()

    public static let decoder = JSONDecoder()

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }
}
