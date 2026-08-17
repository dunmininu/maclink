import Foundation
import Security

/// A tiny Keychain-backed JSON store.
///
/// Pairing tokens are the keys to someone's Mac, so they live in the Keychain rather than
/// UserDefaults on both ends of the link.
public struct SecretStore: Sendable {
    private let service: String

    public init(service: String) {
        self.service = service
    }

    public func load<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = loadData(forKey: key) else { return nil }
        return try? LinkJSON.decode(type, from: data)
    }

    @discardableResult
    public func save<T: Encodable>(_ value: T, forKey key: String) -> Bool {
        guard let data = try? LinkJSON.encode(value) else { return false }
        return saveData(data, forKey: key)
    }

    public func loadData(forKey key: String) -> Data? {
        var query = baseQuery(forKey: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    /// Protection class for everything stored here.
    ///
    /// A pairing token is a key to someone's Mac, so it gets the strictest class that still works:
    /// - `WhenUnlocked` — the app only needs it while someone is actively using it, so there is no
    ///   reason to leave it readable on a locked device.
    /// - `ThisDeviceOnly` — it never leaves in an encrypted backup, so a token cannot be restored
    ///   onto a *different* phone. A restored or cloned device has to pair again, in person, which
    ///   is the correct outcome for a credential that can drive your Mac.
    private static let protection = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

    @discardableResult
    public func saveData(_ data: Data, forKey key: String) -> Bool {
        let query = baseQuery(forKey: key)
        // Accessibility is set on update as well as insert, so an item written by an older build
        // is upgraded in place rather than keeping its weaker class forever.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: Self.protection,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = Self.protection
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public func remove(forKey key: String) -> Bool {
        let status = SecItemDelete(baseQuery(forKey: key) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private func baseQuery(forKey key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}

/// A stable identifier for this installation, generated once and kept in the Keychain so it survives
/// app updates (and, on iOS, reinstalls within the same keychain group).
public enum InstallationIdentity {
    public static func identifier(store: SecretStore, key: String = "installation-id") -> String {
        if let data = store.loadData(forKey: key), let existing = String(data: data, encoding: .utf8), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        store.saveData(Data(fresh.utf8), forKey: key)
        return fresh
    }
}
