import Foundation
import Security
import Combine

/// Connection settings. The API key lives in the Keychain; the rest is UserDefaults.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published private(set) var settings: AppSettings {
        didSet { persistNonSecret() }
    }

    @Published private(set) var lastError: String?
    private let defaults: UserDefaults
    private let key = "luckyagent.settings"
    private let keychainService: String
    private let keychainAccount = "api-key"

    init(defaults: UserDefaults = .standard, keychainService: String = "com.luckyagent.ios") {
        self.defaults = defaults
        self.keychainService = keychainService
        var loaded = AppSettings()
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            loaded = decoded
        }
        loaded.apiKey = Self.readKeychain(service: keychainService, account: keychainAccount) ?? loaded.apiKey
        settings = loaded
    }

    @discardableResult
    func update(_ mutate: (inout AppSettings) -> Void) -> Bool {
        var next = settings
        mutate(&next)
        if next.apiKey != settings.apiKey {
            let status = Self.writeKeychain(service: keychainService, account: keychainAccount, value: next.apiKey)
            guard status == errSecSuccess else {
                lastError = "无法保存 API Key：\(SecCopyErrorMessageString(status, nil) as String? ?? String(status))"
                return false
            }
        }
        lastError = nil
        settings = next
        return true
    }

    private func persistNonSecret() {
        var copy = settings
        copy.apiKey = ""
        if let data = try? JSONEncoder().encode(copy) {
            defaults.set(data, forKey: key)
        }
    }

    private static func writeKeychain(service: String, account: String, value: String) -> OSStatus {
        let payload = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecItemNotFound ? errSecSuccess : status
        }
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: payload] as CFDictionary)
        if status != errSecItemNotFound { return status }
        var add = query
        add[kSecValueData as String] = payload
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil)
    }

    private static func readKeychain(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }
}
