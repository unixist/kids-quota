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
            case .unauthorized: return "This phone's connection is no longer authorized. Get a new connection code from parent setup."
            case .redirect: return "The dashboard address redirected to another location. Reconnect using the correct address."
            case .responseTooLarge: return "The dashboard response was too large to read."
            case .unavailable: return "Couldn't reach your family dashboard. Showing the last known balances."
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
