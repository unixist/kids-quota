import Foundation
import Security
import SwiftUI

@MainActor final class ParentStore: ObservableObject {
    @Published var state: AdminState?
    @Published var selectedChild = ""
    @Published var balances: [BalanceItem] = []
    @Published var error: String?
    @Published var busy = false
    @Published var connected = false
    private var token = ""
    init() {
        token = TokenKeychain.read() ?? ""
        if token.isEmpty {
            let directory = ProcessInfo.processInfo.environment["KIDS_QUOTA_DATA_DIR"] ?? "/Library/Application Support/KidsQuota"
            token = (try? String(contentsOfFile: directory + "/admin.token", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        }
    }
    var children: [ChildItem] { state?.policy.children ?? [] }
    var services: [ServiceItem] { state?.policy.services ?? [] }
    var childName: String { children.first { $0.id == selectedChild }?.displayName ?? "child" }
    var quotas: [QuotaItem] { state?.policy.quotas.filter { $0.childId == selectedChild } ?? [] }
    func connect(_ newToken: String) async throws {
        let old = token; token = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
        do { try await refreshOrThrow(); try TokenKeychain.save(token) }
        catch { token = old; throw error }
    }
    func refresh() async {
        do { try await refreshOrThrow(); error = nil } catch { connected = false; self.error = error.localizedDescription }
    }
    private func refreshOrThrow() async throws {
        let latest: AdminState = try await request("GET", "/admin/state")
        state = latest
        if !children.contains(where: { $0.id == selectedChild }) { selectedChild = children.first?.id ?? "" }
        if !selectedChild.isEmpty {
            let result: BalanceList = try await request("GET", "/children/\(selectedChild)/balances"); balances = result.items
        } else { balances = [] }
        connected = true
    }
    func request<T: Decodable>(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> T {
        let data = try await raw(method, path, body: body); return try JSONDecoder().decode(T.self, from: data)
    }
    func raw(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
        guard !token.isEmpty else { throw ParentError.message("Install the service or enter the parent access token in Settings.") }
        // Send the privileged bearer only after the kernel has identified the root daemon.
        // A child can pre-bind a loopback TCP port while the service is down.
        var envelope: [String: Any] = ["op": "parentHTTP", "method": method, "path": "/v1" + path, "authorization": "Bearer " + token]
        if let body { envelope["body"] = body }
        let requestData = try JSONSerialization.data(withJSONObject: envelope)
        let responseData = try await Task.detached(priority: .userInitiated) {
            guard let object = try JSONSerialization.jsonObject(with: requestData) as? [String: Any] else { throw ParentError.message("Invalid request.") }
            return try JSONSerialization.data(withJSONObject: DaemonSocket.request(object))
        }.value
        guard let response = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let status = response["status"] as? Int, let value = response["body"] else {
            throw ParentError.message("The parent service connection was rejected.")
        }
        let data = try JSONSerialization.data(withJSONObject: value)
        guard (200..<300).contains(status) else {
            let decoded = value as? [String: Any]
            let message = decoded?["message"] as? String ?? (decoded?["error"] as? [String: Any])?["message"] as? String
            throw ParentError.message(message ?? "The service rejected the change. Close the editor, refresh, and try again.")
        }
        return data
    }
    func mutate(_ method: String, _ path: String, _ body: [String: Any], expectedRevision: Int? = nil) async throws -> [String: Any] {
        var body = body; body["expectedPolicyRevision"] = expectedRevision ?? state?.policyRevision ?? 0
        let result = try await raw(method, path, body: body)
        let object = (try? JSONSerialization.jsonObject(with: result)) as? [String: Any] ?? [:]
        try await refreshOrThrow(); return object
    }
}
enum ParentError: LocalizedError { case message(String); var errorDescription: String? { if case .message(let value) = self { return value }; return nil } }

enum TokenKeychain {
    private static let service = "com.kidsquota.parent-access"
    static func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "parent", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ token: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "parent"]
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw ParentError.message("Could not save the parent token in Keychain.") }
    }
}
