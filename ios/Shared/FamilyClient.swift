import Foundation
import QuotaKit

final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
enum FamilyClient {
    enum Failure: LocalizedError {
        case unauthorized, unavailable, redirect, responseTooLarge
        var errorDescription: String? {
            switch self {
            case .unauthorized, .redirect: return DashboardIssue.reconnect.message
            case .responseTooLarge: return DashboardIssue.invalidReport.message
            case .unavailable: return DashboardIssue.cannotRefresh.message
            }
        }
    }
    static func fetch(_ connection: PhoneConnection) async throws -> FamilySnapshot {
        try connection.validate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 30
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let url = connection.origin.appendingPathComponent("v1/family")
        var request = URLRequest(url: url); request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer " + connection.readToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw Failure.unavailable }
        if response.statusCode == 401 || response.statusCode == 403 { throw Failure.unauthorized }
        if (300..<400).contains(response.statusCode) { throw Failure.redirect }
        guard response.statusCode == 200 else { throw Failure.unavailable }
        guard response.expectedContentLength <= 4_194_304 else { throw Failure.responseTooLarge }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 4_194_304 else { throw Failure.responseTooLarge }
            data.append(byte)
        }
        return try FamilySnapshot.decode(data)
    }
}

extension DashboardIssue {
    static func reporting(_ error: Error) -> DashboardIssue {
        if let issue = error as? DashboardIssue { return issue }
        switch error {
        case FamilyClient.Failure.unauthorized, FamilyClient.Failure.redirect: return .reconnect
        case FamilyClient.Failure.responseTooLarge, is QuotaDataError: return .invalidReport
        case PhoneStorage.StorageError.keychain, PhoneStorage.StorageError.connectionUnavailable: return .connectionUnavailable
        case PhoneStorage.StorageError.appGroup: return .localStorage
        default: return .cannotRefresh
        }
    }
}

struct DashboardRead {
    let family: FamilySnapshot?
    let issue: DashboardIssue?
}

/// The widget has no long-lived store. Keep its read path explicit and testable,
/// including the difference between an unavailable connection and an absent one.
enum DashboardReader {
    static func load(
        connection: () -> ConnectionLoad = { PhoneStorage.connection() },
        cached: (PhoneConnection) -> FamilySnapshot? = { PhoneStorage.cached(for: $0) },
        save: (FamilySnapshot, PhoneConnection) throws -> FamilySnapshot = { try PhoneStorage.save($0, for: $1) },
        fetch: (PhoneConnection) async throws -> FamilySnapshot = { try await FamilyClient.fetch($0) }
    ) async -> DashboardRead {
        let loaded = connection()
        guard let original = loaded.connection else { return DashboardRead(family: nil, issue: loaded.issue) }
        let previous = cached(original)
        func changed(_ state: ConnectionLoad) -> DashboardRead? {
            guard state != .available(original) else { return nil }
            if state == .unavailable { return DashboardRead(family: previous, issue: .connectionUnavailable) }
            return DashboardRead(family: nil, issue: state.issue ?? .cannotRefresh)
        }
        do {
            let value = try await fetch(original)
            if let changed = changed(connection()) { return changed }
            let current = value.preservingNewerReports(from: previous)
            do {
                let saved = try save(current, original)
                if let changed = changed(connection()) { return changed }
                return DashboardRead(family: saved.preservingNewerReports(from: current), issue: nil)
            } catch {
                if let changed = changed(connection()) { return changed }
                if case PhoneStorage.StorageError.changedConnection = error {
                    return DashboardRead(family: previous, issue: .cannotRefresh)
                }
                return DashboardRead(family: current.preservingNewerReports(from: cached(original)), issue: .localStorage)
            }
        } catch {
            if let changed = changed(connection()) { return changed }
            return DashboardRead(family: cached(original)?.preservingNewerReports(from: previous) ?? previous,
                                 issue: .reporting(error))
        }
    }
}
