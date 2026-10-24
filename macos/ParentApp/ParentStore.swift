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
    @Published private(set) var isUnlocked = false
    @Published private(set) var isAdministrator: Bool
    private var token = ""
    private var authorization: (any ParentAuthorizationSession)?
    private var generation = UUID()
    private let credentialReader: () -> String
    private let authorizationFactory: @Sendable () throws -> any ParentAuthorizationSession
    private let transport: @Sendable (Data) async throws -> Data

    init(isAdministrator: Bool? = nil,
         credentialReader: @escaping () -> String = ParentStore.storedToken,
         authorizationFactory: @escaping @Sendable () throws -> any ParentAuthorizationSession = { try ParentAuthorization.request() },
         transport: @escaping @Sendable (Data) async throws -> Data = { try await ParentStore.socketTransport($0) }) {
        self.isAdministrator = isAdministrator ?? AccountDiscovery.isCurrentUserAdministrator()
        self.credentialReader = credentialReader; self.authorizationFactory = authorizationFactory; self.transport = transport
        // Deliberately do not read Keychain, credentials, or service state while locked.
    }
    func unlock() async {
        guard isAdministrator, !busy, !isUnlocked else { return }
        busy = true; error = nil
        let attempt = generation, factory = authorizationFactory
        do {
            let grant = try await Task.detached(priority: .userInitiated) { try factory() }.value
            guard generation == attempt else { grant.invalidate(); return }
            authorization = grant; token = credentialReader(); isUnlocked = true
            await refresh()
        } catch { if generation == attempt { self.error = error.localizedDescription } }
        if generation == attempt { busy = false }
    }
    func lock() {
        generation = UUID(); authorization?.invalidate(); authorization = nil
        token = ""; state = nil; balances = []; selectedChild = ""
        isUnlocked = false; connected = false; busy = false; error = nil
    }
    nonisolated private static func storedToken() -> String {
        let saved = TokenKeychain.read() ?? ""
        if !saved.isEmpty { return saved }
        let directory = ProcessInfo.processInfo.environment["KIDS_QUOTA_DATA_DIR"] ?? "/Library/Application Support/KidsQuota"
        return (try? String(contentsOfFile: directory + "/admin.token", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
    }
    nonisolated private static func socketTransport(_ requestData: Data) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            guard let object = try JSONSerialization.jsonObject(with: requestData) as? [String: Any] else { throw ParentError.message("Invalid request.") }
            return try JSONSerialization.data(withJSONObject: DaemonSocket.request(object))
        }.value
    }
    var children: [ChildItem] { state?.policy.children ?? [] }
    var services: [ServiceItem] { state?.policy.services ?? [] }
    var childName: String { children.first { $0.id == selectedChild }?.displayName ?? "child" }
    var quotas: [QuotaItem] { state?.policy.quotas.filter { $0.childId == selectedChild } ?? [] }
    func connect(_ newToken: String) async throws {
        guard isUnlocked else { throw ParentError.message("Unlock parent settings first.") }
        let old = token; token = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
        do { try await refreshOrThrow(); try TokenKeychain.save(token) }
        catch { if isUnlocked { token = old }; throw error }
    }
    func refresh() async {
        guard isUnlocked else { return }
        do { try await refreshOrThrow(); error = nil }
        catch { if isUnlocked { connected = false; self.error = error.localizedDescription } }
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
        guard isUnlocked, let authorization else { throw ParentError.message("Unlock parent settings first.") }
        let requestGeneration = generation
        guard !token.isEmpty else { throw ParentError.message("Install the service or enter the parent access token in Settings.") }
        // Send the privileged bearer only after the kernel has identified the root daemon.
        // A child can pre-bind a loopback TCP port while the service is down.
        var envelope: [String: Any] = ["op": "parentHTTP", "method": method, "path": "/v1" + path, "authorization": "Bearer " + token, "authorizationExternalForm": authorization.externalForm]
        if let body { envelope["body"] = body }
        let requestData = try JSONSerialization.data(withJSONObject: envelope)
        let responseData = try await transport(requestData)
        guard isUnlocked, generation == requestGeneration else { throw ParentError.message("Parent settings are locked.") }
        guard let response = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let status = response["status"] as? Int, let value = response["body"] else {
            throw ParentError.message("The parent service connection was rejected.")
        }
        let data = try JSONSerialization.data(withJSONObject: value)
        guard (200..<300).contains(status) else {
            let decoded = value as? [String: Any]
            if (decoded?["error"] as? [String: Any])?["code"] as? String == "administrator_required" {
                lock(); error = "Administrator access expired. Unlock to continue."
                throw ParentError.message("Administrator access expired. Unlock to continue.")
            }
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
