import Foundation
import Security

/// Where tokens live. Only the Keychain in the app; tests use a dictionary.
protocol TokenVault: Sendable {
    func token(for account: String) -> String?
    func setToken(_ token: String, for account: String) throws
    func removeToken(for account: String)
}

/// Accounts in the vault: a connection's read token, and (from milestone 9) a site's manage token.
enum VaultAccount {
    static func read(_ connection: UUID) -> String { connection.uuidString }
    static func manage(_ connection: UUID, site: String) -> String { "\(connection.uuidString)/\(site)" }
}

/// Tokens as generic passwords in the login Keychain, service `sh.runlight.mac`. They are readable
/// after first unlock, so the app can poll when it starts at login, and never sync to other Macs.
struct Keychain: TokenVault {
    var service = "sh.runlight.mac"

    struct Failure: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String { SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)" }
    }

    func token(for account: String) -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setToken(_ token: String, for account: String) throws {
        let data = Data(token.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(base(account) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base(account)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrLabel as String] = "Runlight token"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    func removeToken(for account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }

    private func base(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// A vault in memory, for tests and previews.
final class MemoryVault: TokenVault, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: String] = [:]

    func token(for account: String) -> String? { lock.withLock { tokens[account] } }
    func setToken(_ token: String, for account: String) throws { lock.withLock { tokens[account] = token } }
    func removeToken(for account: String) { lock.withLock { _ = tokens.removeValue(forKey: account) } }
    var count: Int { lock.withLock { tokens.count } }
}
