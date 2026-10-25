import XCTest
import Darwin
import Security
@testable import KidsQuotaService

final class LocalInstallTrustTests: XCTestCase {
    private func manifest(change: (inout [[String: Any]]) -> Void = { _ in }) throws -> Data {
        var entries: [[String: Any]] = LocalInstallTrust.expected.sorted { $0.key < $1.key }.map { role, value in
            ["role": role, "path": value.path, "identifier": value.identifier,
             "cdhashes": [String(repeating: "a", count: 40), String(repeating: "b", count: 40)]]
        }
        change(&entries)
        return try JSONSerialization.data(withJSONObject: ["version": 1, "entries": entries])
    }
    func testAcceptsOnlyFiveExplicitRolesAndBothArchitectureHashes() throws {
        let trust = try LocalInstallTrust(data: manifest())
        let path = try XCTUnwrap(LocalInstallTrust.expected["agent"]?.path)
        let requirement = try trust.requirement(path: path)
        XCTAssertTrue(requirement.contains("identifier \"com.kidsquota.agent\""))
        XCTAssertTrue(requirement.contains("cdhash H\"" + String(repeating: "a", count: 40)))
        XCTAssertTrue(requirement.contains(" or cdhash H\"" + String(repeating: "b", count: 40)))
        var parsed: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(requirement as CFString, [], &parsed), errSecSuccess)
        XCTAssertNotNil(parsed)
        XCTAssertThrowsError(try trust.entry(path: "/tmp/kids-quota-agent"))
        XCTAssertThrowsError(try trust.entry(path: LocalInstallTrust.appRoot + "/Contents/Library/SystemExtensions/filter"))
    }
    func testRejectsMalformedOrAmbiguousManifest() throws {
        let mutations: [(inout [[String: Any]]) -> Void] = [
            { $0.removeLast() },
            { $0.append($0[0]) },
            { $0[0]["role"] = "filter" },
            { $0[0]["path"] = "/tmp/kids-quota-agent" },
            { $0[0]["identifier"] = "com.attacker.app" },
            { $0[0]["cdhashes"] = [] },
            { $0[0]["cdhashes"] = [String(repeating: "x", count: 40)] },
            { $0[0]["cdhashes"] = [String(repeating: "a", count: 39)] },
            { $0[0]["cdhashes"] = [String(repeating: "a", count: 40), String(repeating: "A", count: 40)] },
            { $0[0]["cdhashes"] = ["\" or anchor apple generic"] }
        ]
        for mutate in mutations { XCTAssertThrowsError(try LocalInstallTrust(data: manifest(change: mutate))) }
        XCTAssertThrowsError(try LocalInstallTrust(data: Data(repeating: 32, count: 65_537)))
        XCTAssertThrowsError(try LocalInstallTrust(data: Data("{\"version\":2,\"entries\":[]}".utf8)))
    }
    private func identity(_ component: String, target: String) -> LocalInstallTrust.FileIdentity {
        .init(uid: 0, gid: component == "/Applications" ? 80 : 0,
              mode: mode_t(component == target ? S_IFREG | 0o750 : S_IFDIR | (component == "/Applications" ? 0o775 : 0o755)), hasACL: false)
    }
    func testAllowsProtectedTreesAndAdminWritableApplicationsDirectory() throws {
        for path in LocalInstallTrust.expected.values.map(\.path) + [LocalInstallTrust.manifestPath] {
            try LocalInstallTrust.validatePath(path) { self.identity($0, target: path) }
        }
    }
    func testRejectsWritableSymlinkUnownedOrACLProtectedTreeNodes() throws {
        let path = try XCTUnwrap(LocalInstallTrust.expected["parent"]?.path)
        let bad: [LocalInstallTrust.FileIdentity] = [
            .init(uid: 501, gid: 80, mode: mode_t(S_IFDIR | 0o755), hasACL: false),
            .init(uid: 0, gid: 0, mode: mode_t(S_IFLNK | 0o755), hasACL: false),
            .init(uid: 0, gid: 0, mode: mode_t(S_IFDIR | 0o757), hasACL: false),
            .init(uid: 0, gid: 80, mode: mode_t(S_IFDIR | 0o775), hasACL: false),
            .init(uid: 0, gid: 0, mode: mode_t(S_IFDIR | 0o755), hasACL: true)
        ]
        for invalid in bad {
            XCTAssertThrowsError(try LocalInstallTrust.validatePath(path) { $0 == LocalInstallTrust.appRoot ? invalid : self.identity($0, target: path) })
        }
        XCTAssertThrowsError(try LocalInstallTrust.validatePath(path) { component in
            component == "/Applications" ? .init(uid: 0, gid: 20, mode: mode_t(S_IFDIR | 0o775), hasACL: false) : self.identity(component, target: path)
        })
    }
    func testReadsRealRootDirectoryMetadataAndRejectsRealSymlink() throws {
        let root = try LocalInstallTrust.filesystemIdentity("/")
        XCTAssertEqual(root.uid, 0); XCTAssertEqual(root.mode & S_IFMT, S_IFDIR)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: temporary, withDestinationURL: URL(fileURLWithPath: "/"))
        defer { try? FileManager.default.removeItem(at: temporary) }
        XCTAssertThrowsError(try LocalInstallTrust.filesystemIdentity(temporary.path))
    }
    func testDetectsRealExtendedAccessControlEntries() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("fixture".utf8).write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        _ = try run("/bin/chmod", ["+a", "everyone allow read", temporary.path])
        XCTAssertTrue(try LocalInstallTrust.filesystemIdentity(temporary.path).hasACL)
    }
    func testPinnedRequirementChecksActualAdHocCodeAndRejectsDifferentBuild() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kids-quota-signature-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("agent")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
        _ = try run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", "com.kidsquota.agent", "--options", "runtime", executable.path])
        let output = try run("/usr/bin/codesign", ["--display", "--verbose=4", executable.path])
        let hash = try XCTUnwrap(output.split(separator: "\n").first { $0.hasPrefix("CDHash=") }.map { String($0.dropFirst(7)) })
        let good = try LocalInstallTrust(data: manifest { entries in
            let index = entries.firstIndex { $0["role"] as? String == "agent" }!
            entries[index]["cdhashes"] = [hash]
        })
        let path = try XCTUnwrap(LocalInstallTrust.expected["agent"]?.path)
        let process = Process()
        process.executableURL = executable; process.arguments = ["30"]
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        var live: SecCode?
        XCTAssertEqual(SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: NSNumber(value: process.processIdentifier)] as CFDictionary, [], &live), errSecSuccess)
        let liveCode = try XCTUnwrap(live)
        var code: SecStaticCode?
        XCTAssertEqual(SecStaticCodeCreateWithPath(executable as CFURL, [], &code), errSecSuccess)
        let staticCode = try XCTUnwrap(code)
        for (trust, expected) in [(good, true), (try LocalInstallTrust(data: manifest()), false)] {
            var requirement: SecRequirement?
            XCTAssertEqual(SecRequirementCreateWithString(try trust.requirement(path: path) as CFString, [], &requirement), errSecSuccess)
            XCTAssertEqual(SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSStrictValidate), try XCTUnwrap(requirement)) == errSecSuccess, expected)
            XCTAssertEqual(SecCodeCheckValidity(liveCode, SecCSFlags(rawValue: kSecCSStrictValidate), try XCTUnwrap(requirement)) == errSecSuccess, expected)
        }
    }
    private func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw NSError(domain: "LocalTrustTest", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: output]) }
        return output
    }
}
