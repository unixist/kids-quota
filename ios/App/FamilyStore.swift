import SwiftUI
import WidgetKit
import QuotaKit

@MainActor final class FamilyStore: ObservableObject {
    struct Dependencies {
        var connection: () -> ConnectionLoad = { PhoneStorage.connection() }
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
    @Published var issue: DashboardIssue?
    @Published var isDemo = false
    private var generation = RequestGeneration()
    private var isConnecting = false
    private let dependencies: Dependencies
    init(dependencies: Dependencies = Dependencies()) {
        self.dependencies = dependencies
        applyConnection(dependencies.connection())
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
        connection = newConnection; snapshot = nil; isDemo = false; issue = nil
        guard retain(value, for: newConnection) else { throw CancellationError() }
    }
    func refresh() async {
        guard !isDemo, !isConnecting, !isRefreshing else { return }
        // Keychain access can recover after unlocking. Never treat a read failure
        // as a missing connection or require the parent to pair again for it.
        applyConnection(dependencies.connection())
        guard issue != .connectionUnavailable, let connection else { return }
        isRefreshing = true
        let requestGeneration = generation.token
        defer { if generation.accepts(requestGeneration) { isRefreshing = false } }
        do {
            let value = try await dependencies.fetch(connection)
            guard generation.accepts(requestGeneration), self.connection == connection else { return }
            _ = retain(value, for: connection)
        } catch {
            guard generation.accepts(requestGeneration), confirmConnection(connection) else { return }
            issue = .reporting(error)
        }
    }
    /// Display a validated response even when the cache cannot be written. The
    /// connection is rechecked so this fallback can never revive another family.
    @discardableResult private func retain(_ value: FamilySnapshot, for connection: PhoneConnection) -> Bool {
        guard confirmConnection(connection) else { return false }
        let current = value.preservingNewerReports(from: snapshot)
        do {
            let saved = try dependencies.saveSnapshot(current, connection)
            guard confirmConnection(connection) else { return false }
            snapshot = saved.preservingNewerReports(from: current); issue = nil
        } catch {
            guard confirmConnection(connection) else { return false }
            if case PhoneStorage.StorageError.changedConnection = error {
                issue = .cannotRefresh
                return false
            }
            snapshot = current.preservingNewerReports(from: dependencies.cached(connection))
            issue = .localStorage
        }
        dependencies.reloadWidgets()
        return true
    }
    private func confirmConnection(_ expected: PhoneConnection) -> Bool {
        let loaded = dependencies.connection()
        guard loaded == .available(expected) else {
            applyConnection(loaded)
            if case .available = loaded { issue = .cannotRefresh }
            return false
        }
        return true
    }
    private func applyConnection(_ loaded: ConnectionLoad) {
        switch loaded {
        case .available(let value):
            if connection != value {
                generation.advance(); isConnecting = false; isRefreshing = false
                connection = value; snapshot = dependencies.cached(value); issue = nil
            } else if issue == .connectionUnavailable { issue = nil }
        case .unavailable:
            // Preserve this phone's last known family while access is temporary.
            issue = .connectionUnavailable
        case .absent, .invalid:
            if connection != nil { generation.advance(); isConnecting = false; isRefreshing = false }
            connection = nil; snapshot = nil; issue = loaded.issue
        }
    }
    func disconnect() throws {
        try dependencies.disconnect()
        generation.advance(); isConnecting = false; connection = nil; snapshot = nil; issue = .notConnected; isRefreshing = false; isDemo = false
        dependencies.reloadWidgets()
    }
    func showDemo() {
        generation.advance(); isConnecting = false; isRefreshing = false; isDemo = true; issue = nil; snapshot = DemoFamily.snapshot()
    }
    func endDemo() {
        generation.advance(); isConnecting = false; isRefreshing = false; isDemo = false; connection = nil; snapshot = nil; issue = nil
        applyConnection(dependencies.connection())
    }
    func cancelPairing() { if isConnecting { generation.advance(); isConnecting = false; isRefreshing = false } }
}
