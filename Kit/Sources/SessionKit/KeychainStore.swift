import Foundation
import Security

/// One generic-password entry in the login Keychain. The Anthropic API key lives only here,
/// never in files, logs, or source.
public struct KeychainStore: Sendable {
    public enum Error: Swift.Error, Equatable {
        case empty
        case status(OSStatus)
    }

    public static let apiKey = KeychainStore(service: "VoiceTranscriber", account: "anthropic-api-key")

    public let service: String
    public let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    /// Saves the value (surrounding whitespace removed), replacing any existing one.
    public func save(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Error.empty }
        let data = Data(trimmed.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let add = SecItemAdd(item as CFDictionary, nil)
            guard add == errSecSuccess else { throw Error.status(add) }
        } else if update != errSecSuccess {
            throw Error.status(update)
        }
    }

    public func load() -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Removes the entry; does nothing if there is none.
    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Error.status(status) }
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
