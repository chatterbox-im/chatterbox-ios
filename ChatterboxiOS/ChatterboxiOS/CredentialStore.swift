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

    func savePassword(_ password: String) {
        guard let data = password.data(using: .utf8) else { return }
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: username,
        ]
        // Delete any existing item first, then add the new one.
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData] = data
        SecItemAdd(item as CFDictionary, nil)
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

    func clearAll() {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService,
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: serverKey)
        UserDefaults.standard.removeObject(forKey: usernameKey)
    }

    /// Returns true if all three credentials are stored.
    var isComplete: Bool {
        !server.isEmpty && !username.isEmpty && loadPassword() != nil
    }
}
