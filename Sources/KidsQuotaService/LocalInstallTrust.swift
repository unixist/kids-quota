import Foundation
import Darwin
import Security

/// Trust for the explicitly selected certificate-free installation. The root
/// installer pins exact ad-hoc-signed builds; it does not grant trust to arbitrary
/// filenames or to all applications run by a child. Developer ID mode is separate.
public struct LocalInstallTrust {
    public static let manifestPath = "/Library/Application Support/KidsQuota/local-trust.json"
    static let dataRoot = "/Library/Application Support/KidsQuota"
    static let appRoot = "/Applications/Kids Quota.app"
    static let expected: [String: (path: String, identifier: String)] = [
        "service": (dataRoot + "/bin/kids-quota-service", "com.kidsquota.service"),
        "agent": (dataRoot + "/bin/kids-quota-agent", "com.kidsquota.agent"),
        "bridge": (dataRoot + "/bin/kids-quota-bridge", "com.kidsquota.bridge"),
        "parent": (appRoot + "/Contents/MacOS/Kids Quota", "com.kidsquota.app"),
        "safari": (appRoot + "/Contents/PlugIns/KidsQuotaSafari.appex/Contents/MacOS/KidsQuotaSafari", "com.kidsquota.app.safari")
    ]
    struct Entry: Codable {
        let role: String
        let path: String
        let identifier: String
        let cdhashes: [String]
    }
    private struct Manifest: Codable { let version: Int; let entries: [Entry] }
    private let entries: [Entry]

    init(data: Data) throws {
        guard data.count <= 65_536 else { throw TransportError.unauthorized }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.version == 1, manifest.entries.count == Self.expected.count,
              Set(manifest.entries.map(\.role)) == Set(Self.expected.keys) else { throw TransportError.unauthorized }
        for entry in manifest.entries {
            guard let expected = Self.expected[entry.role], entry.path == expected.path,
                  entry.identifier == expected.identifier, (1...4).contains(entry.cdhashes.count),
                  Set(entry.cdhashes.map { $0.lowercased() }).count == entry.cdhashes.count,
                  entry.cdhashes.allSatisfy({ hash in
                      hash.utf8.count == 40 && hash.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
                  }) else { throw TransportError.unauthorized }
        }
        entries = manifest.entries
    }

    public static func load() throws -> LocalInstallTrust {
        try validatePath(manifestPath)
        let attributes = try FileManager.default.attributesOfItem(atPath: manifestPath)
        guard let size = attributes[.size] as? NSNumber, size.int64Value <= 65_536 else { throw TransportError.unauthorized }
        return try LocalInstallTrust(data: Data(contentsOf: URL(fileURLWithPath: manifestPath)))
    }

    public func validateService() throws {
        guard getuid() == 0 else { throw TransportError.unauthorized }
        let path = try Self.executablePath(pid: getpid())
        guard try validate(pid: getpid(), path: path) == "service" else { throw TransportError.unauthorized }
    }

    func verifyPeer(pid: Int32, path: String) throws -> String {
        let role = try validate(pid: pid, path: path)
        // The dormant Network Extension is never accepted in local-install mode.
        guard ["agent", "bridge", "parent", "safari"].contains(role) else { throw TransportError.unauthorized }
        return role
    }

    func entry(path: String) throws -> Entry {
        guard let entry = entries.first(where: { $0.path == path }) else { throw TransportError.unauthorized }
        return entry
    }

    func requirement(path: String) throws -> String {
        let entry = try entry(path: path)
        let hashes = entry.cdhashes.map { "cdhash H\"\($0.lowercased())\"" }.joined(separator: " or ")
        return "identifier \"\(entry.identifier)\" and (\(hashes))"
    }

    private func validate(pid: Int32, path: String) throws -> String {
        let entry = try entry(path: path)
        try Self.validatePath(path)
        var code: SecCode?
        var requirement: SecRequirement?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary, [], &code) == errSecSuccess,
              let code, SecRequirementCreateWithString(try self.requirement(path: path) as CFString, [], &requirement) == errSecSuccess,
              let requirement, SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw TransportError.unauthorized
        }
        return entry.role
    }

    static func executablePath(pid: Int32) throws -> String {
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { throw TransportError.unauthorized }
        return String(cString: path)
    }

    struct FileIdentity {
        let uid: UInt32
        let gid: UInt32
        let mode: mode_t
        let hasACL: Bool
    }

    /// All controlled paths are immutable to standard accounts. Fixed platform
    /// parents may be writable by the macOS admin group (e.g. /Applications).
    static func validatePath(_ path: String, inspect: (String) throws -> FileIdentity = filesystemIdentity) throws {
        guard path == manifestPath || expected.values.contains(where: { $0.path == path }) else { throw TransportError.unauthorized }
        var components = ["/"]
        var current = ""
        for part in path.split(separator: "/") { current += "/" + part; components.append(current) }
        for component in components {
            let identity = try inspect(component)
            let isFile = component == path
            guard identity.uid == 0, identity.mode & S_IFMT == (isFile ? S_IFREG : S_IFDIR),
                  identity.mode & 0o002 == 0, !identity.hasACL else { throw TransportError.unauthorized }
            let controlled = component == dataRoot || component.hasPrefix(dataRoot + "/") || component == appRoot || component.hasPrefix(appRoot + "/")
            if controlled {
                guard identity.mode & 0o020 == 0 else { throw TransportError.unauthorized }
            } else {
                guard identity.mode & 0o020 == 0 || identity.gid == 80 || identity.gid == 0 else { throw TransportError.unauthorized }
            }
        }
    }

    static func filesystemIdentity(_ path: String) throws -> FileIdentity {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw TransportError.unauthorized }
        // lstat identifies symlinks before asking for any target ACL information.
        guard info.st_mode & S_IFMT != S_IFLNK else { throw TransportError.unauthorized }
        // macOS returns ENOENT when the existing object has no extended ACL.
        // Other retrieval failures must not be interpreted as an empty ACL.
        guard let acl = acl_get_file(path, ACL_TYPE_EXTENDED) else {
            guard errno == ENOENT else { throw TransportError.unauthorized }
            return .init(uid: info.st_uid, gid: info.st_gid, mode: info.st_mode, hasACL: false)
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        let found = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
        guard found == 0 || errno == EINVAL else { throw TransportError.unauthorized }
        return .init(uid: info.st_uid, gid: info.st_gid, mode: info.st_mode, hasACL: found == 0)
    }
}
