import Foundation
import Security

/// Connection settings. The API key lives in the Keychain; the rest is UserDefaults.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var settings: AppSettings {
        didSet { persistNonSecret() }
    }

    private let defaults = UserDefaults.standard
    private let key = "luckyagent.settings"
    private let keychainService = "com.luckyagent.ios"
    private let keychainAccount = "api-key"

    init() {
        var loaded = AppSettings()
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            loaded = decoded
        }
        loaded.apiKey = Self.readKeychain(service: keychainService, account: keychainAccount) ?? loaded.apiKey
        settings = loaded
    }

    func update(_ mutate: (inout AppSettings) -> Void) {
        var next = settings
        mutate(&next)
        if next.apiKey != settings.apiKey {
            Self.writeKeychain(service: keychainService, account: keychainAccount, value: next.apiKey)
        }
        settings = next
    }

    private func persistNonSecret() {
        var copy = settings
        copy.apiKey = ""
        if let data = try? JSONEncoder().encode(copy) {
            defaults.set(data, forKey: key)
        }
    }

    private static func writeKeychain(service: String, account: String, value: String) {
        let payload = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = payload
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
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
