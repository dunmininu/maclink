import Foundation
import MacLinkKit

/// A phone that has completed pairing with this Mac.
struct PairedDevice: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var token: Data
    var pairedAt: Date
    var lastSeen: Date?
}

/// Keychain-backed record of which phones are allowed to drive this Mac.
@MainActor
final class TrustStore {
    private static let devicesKey = "paired-devices"
    private static let hostIDKey = "host-id"

    private let store = SecretStore(service: "africa.myladder.maclink.host")
    private(set) var devices: [PairedDevice] = []

    var onChange: (([PairedDevice]) -> Void)?

    /// Stable identity for this Mac, so a phone recognises it across renames and restarts.
    let hostID: String

    init() {
        hostID = InstallationIdentity.identifier(store: store, key: Self.hostIDKey)
        devices = store.load([PairedDevice].self, forKey: Self.devicesKey) ?? []
    }

    func token(for deviceID: String) -> Data? {
        devices.first { $0.id == deviceID }?.token
    }

    func upsert(device: DeviceDescriptor, token: Data) {
        var updated = devices.filter { $0.id != device.id }
        updated.append(PairedDevice(
            id: device.id,
            name: device.name,
            token: token,
            pairedAt: Date(),
            lastSeen: Date()
        ))
        persist(updated)
    }

    func markSeen(_ deviceID: String) {
        guard let index = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        var updated = devices
        updated[index].lastSeen = Date()
        persist(updated)
    }

    func revoke(_ deviceID: String) {
        persist(devices.filter { $0.id != deviceID })
    }

    func revokeAll() {
        persist([])
    }

    private func persist(_ updated: [PairedDevice]) {
        devices = updated.sorted { $0.pairedAt > $1.pairedAt }
        store.save(devices, forKey: Self.devicesKey)
        onChange?(devices)
    }
}
