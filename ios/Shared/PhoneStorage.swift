import Foundation
import Security
import CryptoKit
import QuotaKit

enum PhoneStorage {
    static var group: String { Bundle.main.object(forInfoDictionaryKey: "QuotaAppGroup") as? String ?? "group.com.unixist.kidsquota.mobile" }
    static var accessGroup: String? {
        let value = Bundle.main.object(forInfoDictionaryKey: "QuotaKeychainGroup") as? String
        return value?.contains("$(") == false ? value : nil
    }
    private static var query: [String: Any] {
        var value: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "KidsQuotaPhone", kSecAttrAccount as String: "read-connection"]
        if let accessGroup { value[kSecAttrAccessGroup as String] = accessGroup }
        return value
    }
    static func connection() -> PhoneConnection? {
        var request = query; request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let value = try? JSONDecoder().decode(PhoneConnection.self, from: data),
              (try? value.validate()) != nil else { return nil }
        return value
    }
    static func save(_ connection: PhoneConnection) throws {
        try connection.validate()
        let data = try JSONEncoder().encode(connection)
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            guard status == errSecSuccess else { throw StorageError.keychain }
        } else if status != errSecSuccess { throw StorageError.keychain }
        clearCache()
    }
    static func disconnect() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StorageError.keychain }
        clearCache()
    }
    private static var cacheURL: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appendingPathComponent("family-cache.json") }
    private struct Cache: Codable { let connectionHash: String; let snapshot: Data }
    private static func fingerprint(_ connection: PhoneConnection) -> String {
        SHA256.hash(data: Data((connection.endpoint + "\n" + connection.readToken).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func cached(for connection: PhoneConnection) -> FamilySnapshot? {
        guard let url = cacheURL, let data = try? Data(contentsOf: url), data.count < 6_000_000,
              let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.connectionHash == fingerprint(connection) else { return nil }
        return try? FamilySnapshot.decode(cache.snapshot)
    }
    static func save(_ snapshot: FamilySnapshot, for original: PhoneConnection) throws -> FamilySnapshot {
        guard let url = cacheURL else { throw StorageError.appGroup }
        var coordinationError: NSError?
        var operationError: Error?
        var result = snapshot
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            do {
                guard connection() == original else { throw StorageError.changedConnection }
                result = snapshot.preservingNewerReports(from: cached(for: original))
                let data = try JSONEncoder().encode(Cache(connectionHash: fingerprint(original), snapshot: result.encoded()))
                try data.write(to: coordinatedURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch { operationError = error }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
        return result
    }
    private static func clearCache() {
        if let url = cacheURL {
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: nil) { try? FileManager.default.removeItem(at: $0) }
        }
    }
    enum StorageError: LocalizedError {
        case keychain, appGroup, changedConnection
        var errorDescription: String? {
            switch self {
            case .keychain: return "The secure connection could not be saved. Check this build's signing and shared Keychain configuration."
            case .appGroup: return "Shared widget storage is unavailable. Check this build's App Group configuration."
            case .changedConnection: return "The family connection changed. Open Kids Quota to refresh."
            }
        }
    }
}
