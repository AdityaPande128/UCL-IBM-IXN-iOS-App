import Foundation
import Security

// Host, port and switches in UserDefaults; the pairing token and the direct
// secret only ever in the Keychain, this-device-only, never synced.
final class Prefs {
    private let defaults = UserDefaults.standard

    var paired: Bool {
        get { defaults.bool(forKey: "paired") }
        set { defaults.set(newValue, forKey: "paired") }
    }

    var host: String {
        get { defaults.string(forKey: "host") ?? "" }
        set { defaults.set(newValue, forKey: "host") }
    }

    var port: Int {
        get { defaults.object(forKey: "port") as? Int ?? 8080 }
        set { defaults.set(newValue, forKey: "port") }
    }

    var remoteHost: String {
        get { defaults.string(forKey: "remoteHost") ?? "" }
        set { defaults.set(newValue, forKey: "remoteHost") }
    }

    var remotePort: Int {
        get { defaults.object(forKey: "remotePort") as? Int ?? 0 }
        set { defaults.set(newValue, forKey: "remotePort") }
    }

    var speakReplies: Bool {
        get { defaults.object(forKey: "speakReplies") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "speakReplies") }
    }

    var token: String {
        get { Keychain.read("token") ?? "" }
        set { Keychain.write("token", newValue) }
    }

    var secret: String {
        get { Keychain.read("secret") ?? "" }
        set { Keychain.write("secret", newValue) }
    }

    func unpair() {
        paired = false
        host = ""
        remoteHost = ""
        remotePort = 0
        Keychain.delete("token")
        Keychain.delete("secret")
    }
}

enum Keychain {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.jarvis.companion.ios",
         kSecAttrAccount as String: account]
    }

    static func read(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ account: String, _ value: String) {
        delete(account)
        guard !value.isEmpty else { return }
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
