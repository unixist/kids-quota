import Foundation
import SwiftUI

@MainActor final class ParentStore: ObservableObject {
    @Published var state: AdminState?
    @Published var selectedChild = ""
    @Published var balances: [BalanceItem] = []
    @Published var error: String?
    @Published var busy = false
    @Published var connected = false
    @Published private(set) var isUnlocked = false
    private var authorization: (any ParentAuthorizationSession)?
    private var expirationTask: Task<Void, Never>?
    private var generation = UUID()
    private let authorizationFactory: @Sendable () throws -> any ParentAuthorizationSession
    private let transport: @Sendable (Data) async throws -> Data

    init(authorizationFactory: @escaping @Sendable () throws -> any ParentAuthorizationSession = { try ParentAuthorization.request() },
         transport: @escaping @Sendable (Data) async throws -> Data = { try await ParentStore.socketTransport($0) }) {
        self.authorizationFactory = authorizationFactory; self.transport = transport
        // The parent authorizes each session; no persistent parent credential is read.
    }
    func unlock() async {
        guard !busy, !isUnlocked else { return }
        busy = true; error = nil
        let attempt = generation, factory = authorizationFactory
        do {
            let grant = try await Task.detached(priority: .userInitiated) { try factory() }.value
            guard generation == attempt else { grant.invalidate(); return }
            authorization = grant; isUnlocked = true
            expirationTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
                guard let self, self.generation == attempt else { return }
                self.expireAuthorization()
            }
            await refresh()
        } catch { if generation == attempt { self.error = error.localizedDescription } }
        if generation == attempt { busy = false }
    }
    func lock() {
        expirationTask?.cancel(); expirationTask = nil
        generation = UUID(); authorization?.invalidate(); authorization = nil
        state = nil; balances = []; selectedChild = ""
        isUnlocked = false; connected = false; busy = false; error = nil
    }
    func applicationDidResignActive() {
        // SecurityAgent can take focus while the parent's authorization is pending.
        // Once unlocked, switching apps must not leave controls available to the child.
        if isUnlocked { lock() }
    }
    private func expireAuthorization() {
        lock(); error = "Administrator access expired. Unlock to continue."
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
    func refresh() async {
        guard isUnlocked else { return }
        let attempt = generation
        do { try await refreshOrThrow(); if generation == attempt { error = nil } }
        catch { if isUnlocked, generation == attempt { connected = false; self.error = error.localizedDescription } }
    }
    private func refreshOrThrow() async throws {
        let attempt = generation
        let latest: AdminState = try await request("GET", "/admin/state")
        guard isUnlocked, generation == attempt else { throw ParentError.message("Parent settings are locked.") }
        state = latest
        if !children.contains(where: { $0.id == selectedChild }) { selectedChild = children.first?.id ?? "" }
        if !selectedChild.isEmpty {
            let result: BalanceList = try await request("GET", "/children/\(selectedChild)/balances")
            guard isUnlocked, generation == attempt else { throw ParentError.message("Parent settings are locked.") }
            balances = result.items
        } else { balances = [] }
        connected = true
    }
    func request<T: Decodable>(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> T {
        let data = try await raw(method, path, body: body); return try JSONDecoder().decode(T.self, from: data)
    }
    func raw(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
        guard isUnlocked, let authorization else { throw ParentError.message("Unlock parent settings first.") }
        let requestGeneration = generation
        // The root daemon verifies both this process's identity and the OS grant.
        // The proof only travels over the socket after verifying its root peer.
        var envelope: [String: Any] = ["op": "parentHTTP", "method": method, "path": "/v1" + path, "authorizationExternalForm": authorization.externalForm]
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
                expireAuthorization()
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
