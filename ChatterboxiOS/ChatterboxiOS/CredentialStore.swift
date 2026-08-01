import Foundation
import Security

/// Persists XMPP credentials across app launches.
/// Server + username: UserDefaults (not sensitive).
/// Password: iOS Keychain (GenericPassword).
struct CredentialStore {
    static var shared = CredentialStore()
    private init() {}

    private let keychainService = "chatterbox-xmpp"
    private let serverKey  = "xmpp.server"
    private let usernameKey = "xmpp.username"

    // MARK: - Server & username (UserDefaults)

    var server: String {
        get { UserDefaults.standard.string(forKey: serverKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: serverKey) }
    }

    var username: String {
        get { UserDefaults.standard.string(forKey: usernameKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: usernameKey) }
    }

    // MARK: - Password (Keychain)

    func savePassword(_ password: String) throws {
        guard let data = password.data(using: .utf8) else { return }
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: username,
        ]
        // Delete any existing item first, then add the new one.
        let deleteStatus = SecItemDelete(query as CFDictionary)
        if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
            throw keychainError(status: deleteStatus, operation: "delete")
        }
        var item = query
        item[kSecValueData] = data
        var added: AnyObject?
        let addStatus = SecItemAdd(item as CFDictionary, &added)
        if addStatus != errSecSuccess {
            throw keychainError(status: addStatus, operation: "save")
        }
    }

    private func keychainError(status: OSStatus, operation: String) -> Error {
        NSError(
            domain: "CredentialStore",
            code: Int(status),
            userInfo: [
                NSLocalizedDescriptionKey: "Keychain \(operation) failed (status: \(status))",
                NSLocalizedFailureReasonErrorKey: keychainStatusString(status)
            ]
        )
    }

    private func keychainStatusString(_ status: OSStatus) -> String {
        switch status {
        case errSecSuccess:               return "Success"
        case -25299:                      return "Unspecified error"
        case errSecItemNotFound:          return "Item not found"
        case errSecInteractionNotAllowed: return "User interaction not allowed"
        case -25243:                      return "Access denied"
        case errSecAuthFailed:            return "Authentication failed"
        case -25247:                      return "Keychain not found"
        case errSecReadOnly:              return "Keychain is read-only"
        default:                          return "Unknown error (\(status))"
        }
    }

    func loadPassword() -> String? {
        let query: [CFString: Any] = [
            kSecClass:           kSecClassGenericPassword,
            kSecAttrService:     keychainService,
            kSecAttrAccount:     username,
            kSecReturnData:      true,
            kSecMatchLimit:      kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func clearAll() throws {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw keychainError(status: status, operation: "delete")
        }
        UserDefaults.standard.removeObject(forKey: serverKey)
        UserDefaults.standard.removeObject(forKey: usernameKey)
    }

    /// Returns true if all three credentials are stored.
    var isComplete: Bool {
        !server.isEmpty && !username.isEmpty && loadPassword() != nil
    }
}
