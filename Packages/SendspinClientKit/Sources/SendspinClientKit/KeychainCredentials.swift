import Foundation
import Security

/// The client's credentials in the Keychain: one generic-password item holding them as JSON.
/// It stays on this device (never synced or restored elsewhere, since the identity is the
/// device's) and is readable while the device is locked, for playback in the background.
public enum KeychainCredentials {
    public enum KeychainError: Error, CustomStringConvertible {
        case status(OSStatus)
        case corrupt

        public var description: String {
            switch self {
            case .status(let status): "Keychain error \(status)"
            case .corrupt: "the stored credentials can't be read"
            }
        }
    }

    private static func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// The stored credentials, or nil when there are none yet.
    public static func load(service: String, account: String = "client") throws -> ClientCredentials? {
        var query = query(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        guard let data = result as? Data, let credentials = try? JSONDecoder().decode(ClientCredentials.self, from: data)
        else { throw KeychainError.corrupt }
        return credentials
    }

    public static func save(_ credentials: ClientCredentials, service: String, account: String = "client") throws {
        let data = try JSONEncoder().encode(credentials)
        let query = query(service: service, account: account)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    /// A store on the stored credentials, created on first use; every change is saved back.
    /// Throws rather than replace credentials that exist but can't be read, since that would
    /// silently drop the device's identity and pairings.
    public static func store(service: String, account: String = "client") throws -> CredentialStore {
        let credentials: ClientCredentials
        if let stored = try load(service: service, account: account) {
            credentials = stored
        } else {
            credentials = .generate()
            try save(credentials, service: service, account: account)
        }
        return CredentialStore(credentials: credentials) { changed in
            do {
                try save(changed, service: service, account: account)
            } catch {
                Log.error("Saving credentials to the Keychain failed: \(error)")
            }
        }
    }
}
