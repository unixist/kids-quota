import SwiftUI
import WidgetKit
import QuotaKit

@MainActor final class FamilyStore: ObservableObject {
    struct Dependencies {
        var connection: () -> PhoneConnection? = { PhoneStorage.connection() }
        var cached: (PhoneConnection) -> FamilySnapshot? = { PhoneStorage.cached(for: $0) }
        var saveConnection: (PhoneConnection) throws -> Void = { try PhoneStorage.save($0) }
        var saveSnapshot: (FamilySnapshot, PhoneConnection) throws -> FamilySnapshot = { try PhoneStorage.save($0, for: $1) }
        var disconnect: () throws -> Void = { try PhoneStorage.disconnect() }
        var fetch: (PhoneConnection) async throws -> FamilySnapshot = { try await FamilyClient.fetch($0) }
        var reloadWidgets: () -> Void = { WidgetCenter.shared.reloadAllTimelines() }
    }
    @Published var snapshot: FamilySnapshot?
    @Published var connection: PhoneConnection?
    @Published var isRefreshing = false
    @Published var errorMessage: String?
    @Published var isDemo = false
    private var generation = RequestGeneration()
    private var isConnecting = false
    private let dependencies: Dependencies
    init(dependencies: Dependencies = Dependencies()) {
        self.dependencies = dependencies
        connection = dependencies.connection()
        if let connection { snapshot = dependencies.cached(connection) }
        if ProcessInfo.processInfo.arguments.contains("--demo") { showDemo() }
    }
    func connect(_ text: String) async throws {
        let newConnection = try PhoneConnection.parse(text)
        let requestGeneration = generation.advance()
        isConnecting = true; isRefreshing = false
        defer { if generation.accepts(requestGeneration) { isConnecting = false } }
        // Confirm the code before replacing a working connection.
        let value = try await dependencies.fetch(newConnection)
        guard generation.accepts(requestGeneration) else { throw CancellationError() }
        try dependencies.saveConnection(newConnection)
        connection = newConnection; snapshot = nil; isDemo = false; errorMessage = nil
        snapshot = try dependencies.saveSnapshot(value, newConnection)
        dependencies.reloadWidgets()
    }
    func refresh() async {
        guard !isDemo, !isConnecting, let connection, !isRefreshing else { return }
        isRefreshing = true
        let requestGeneration = generation.token
        defer { if generation.accepts(requestGeneration) { isRefreshing = false } }
        do {
            let value = try await dependencies.fetch(connection)
            guard generation.accepts(requestGeneration), self.connection == connection else { return }
            snapshot = try dependencies.saveSnapshot(value, connection).preservingNewerReports(from: snapshot); errorMessage = nil
            dependencies.reloadWidgets()
        } catch {
            guard generation.accepts(requestGeneration) else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Couldn't refresh. Showing your last known balances."
        }
    }
    func disconnect() throws {
        try dependencies.disconnect()
        generation.advance(); isConnecting = false; connection = nil; snapshot = nil; errorMessage = nil; isRefreshing = false; isDemo = false
        dependencies.reloadWidgets()
    }
    func showDemo() {
        generation.advance(); isConnecting = false; isRefreshing = false; isDemo = true; errorMessage = nil; snapshot = DemoFamily.snapshot()
    }
    func endDemo() {
        generation.advance(); isConnecting = false; isRefreshing = false; isDemo = false; connection = dependencies.connection(); snapshot = connection.flatMap { dependencies.cached($0) }
    }
    func cancelPairing() { if isConnecting { generation.advance(); isConnecting = false; isRefreshing = false } }
}
