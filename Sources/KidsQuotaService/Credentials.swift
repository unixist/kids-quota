import Foundation
import CryptoKit
import Security

public struct APIError: Error {
    public let status: Int
    public let code: String
    public let message: String
    public init(_ status: Int, _ code: String, _ message: String) { self.status = status; self.code = code; self.message = message }
}

public struct ClientCredential: Codable {
    public let id: String
    public let name: String
    public let digest: String
    public let scopes: [String]
    public let childIds: [String]
    public let administrator: Bool
    public func allows(_ childId: String) -> Bool { administrator || childIds.contains(childId) }
    public var publicValue: [String: Any] { ["id": id, "name": name, "scopes": scopes, "childIds": childIds, "administrator": administrator] }
}

/// Access is serialized by ServiceController. Only token digests are persisted here.
public final class CredentialStore {
    private let url: URL
    private var clients: [ClientCredential]
    public static let readScopes = ["children:read", "services:read", "quotas:read", "balances:read"]
    public var publicClients: [[String: Any]] { clients.map(\.publicValue) }

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("clients.json")
        if FileManager.default.fileExists(atPath: url.path) {
            clients = try JSONDecoder().decode([ClientCredential].self, from: Data(contentsOf: url))
        } else {
            clients = []
            let (client, token) = try create(name: "Parent administrator", scopes: Self.readScopes + ["policy:write"], childIds: [], administrator: true)
            clients = [client]
            let bootstrap = directory.appendingPathComponent("admin.token")
            try Data((token + "\n").utf8).write(to: bootstrap, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bootstrap.path)
            // Commit the digest last. A crash before this point can safely retry
            // initialization; it cannot leave an unrecoverable administrator token.
            try save()
        }
    }

    private func hash(_ token: String) -> String { SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func create(name: String, scopes: [String], childIds: [String], administrator: Bool) throws -> (ClientCredential, String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw APIError(503,"unavailable","Random generator unavailable.") }
        let token = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return (ClientCredential(id: UUID().uuidString, name: name, digest: hash(token), scopes: scopes, childIds: childIds, administrator: administrator), token)
    }
    public func authenticate(_ header: String?) throws -> ClientCredential {
        guard let header, header.hasPrefix("Bearer "), header.count < 512 else { throw APIError(401,"unauthenticated","A bearer token is required.") }
        let target = Array(hash(String(header.dropFirst(7))).utf8)
        for client in clients {
            let candidate = Array(client.digest.utf8)
            guard candidate.count == target.count else { continue }
            var difference: UInt8 = 0
            for i in target.indices { difference |= target[i] ^ candidate[i] }
            if difference == 0 { return client }
        }
        throw APIError(401,"unauthenticated","Invalid or revoked credential.")
    }
    public func issue(name: String, scopes: [String], childIds: [String]) throws -> [String: Any] {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, name.count <= 100, !scopes.isEmpty,
              Set(scopes).isSubset(of: Set(Self.readScopes)), !childIds.isEmpty else {
            throw APIError(422,"invalid_policy","Choose a name, read permissions, and at least one child.")
        }
        let (client, token) = try create(name: name, scopes: Array(Set(scopes)).sorted(), childIds: Array(Set(childIds)).sorted(), administrator: false)
        clients.append(client)
        do { try save() } catch { clients.removeLast(); throw error }
        return ["id": client.id, "token": token, "client": client.publicValue]
    }
    public func revoke(id: String) throws {
        guard let index = clients.firstIndex(where: { $0.id == id && !$0.administrator }) else { throw APIError(404,"not_found","Client not found or protected administrator.") }
        let old = clients; clients.remove(at: index)
        do { try save() } catch { clients = old; throw error }
    }
    private func save() throws {
        try JSONEncoder().encode(clients).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
