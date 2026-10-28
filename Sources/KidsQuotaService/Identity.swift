import Foundation
import Darwin
import AppKit
import OpenDirectory
import Security
import SystemConfiguration
import KidsQuotaCore

public enum NativeIdentity {
    public static func isAdministrator(uid: UInt32) -> Bool {
        administratorMembership(uid:uid) == true
    }
    private static func administratorMembership(uid: UInt32) -> Bool? {
        if uid == 0 { return true }
        guard let user = getpwuid(uid) else { return nil }
        let name = String(cString:user.pointee.pw_name), primary = Int32(bitPattern:user.pointee.pw_gid)
        guard let administrators = getgrnam("admin") else { return nil }
        let administratorGroup = Int32(bitPattern:administrators.pointee.gr_gid)
        var count: Int32 = 16, groups = [Int32](repeating:0,count:16)
        if getgrouplist(name,primary,&groups,&count) < 0 {
            guard count > 0, count <= 65_536 else { return nil }
            groups = [Int32](repeating:0,count:Int(count))
            guard getgrouplist(name,primary,&groups,&count) >= 0 else { return nil }
        }
        return groups.prefix(Int(count)).contains(administratorGroup)
    }
    public static func consoleUID() -> UInt32? {
        var uid: uid_t = 0, gid: gid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String?, name != "loginwindow", uid >= 500 else { return nil }
        return uid
    }
    public static func account(generatedUid: String) throws -> MacOSAccountBinding {
        let node = try ODNode(session: ODSession.default(), type: UInt32(kODNodeTypeLocalNodes))
        let query = try ODQuery(node: node, forRecordTypes: kODRecordTypeUsers, attribute: kODAttributeTypeGUID, matchType: UInt32(kODMatchEqualTo), queryValues: generatedUid, returnAttributes: [kODAttributeTypeGUID, kODAttributeTypeUniqueID], maximumResults: 2)
        let records = try query.resultsAllowingPartial(false) as? [ODRecord] ?? []
        let entries = try records.map { record in
            (uid: try record.values(forAttribute: kODAttributeTypeUniqueID).first as? String,
             guid: try record.values(forAttribute: kODAttributeTypeGUID).first as? String)
        }
        return try verifiedLocalAccount(generatedUid: generatedUid, entries: entries)
    }
    /// The query is restricted to the local directory node; a normal local login
    /// is eligible regardless of administrator membership. Keep GUID and UID bound
    /// together so an account replaced with a reused UID cannot inherit a quota.
    static func verifiedLocalAccount(generatedUid: String, entries: [(uid: String?, guid: String?)]) throws -> MacOSAccountBinding {
        guard !generatedUid.isEmpty, entries.count == 1, let id = entries[0].uid,
              let uid = UInt32(id), uid >= 500, let stable = entries[0].guid,
              !stable.isEmpty, stable.caseInsensitiveCompare(generatedUid) == .orderedSame else {
            throw APIError(422,"invalid_policy","Choose an existing local user account.")
        }
        return .init(status: "ready", generatedUid: stable, uid: uid)
    }
    public static func application(path: String) throws -> ApplicationBinding {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard url.pathExtension == "app", let bundle = Bundle(url: url), let executable = bundle.executableURL else {
            throw APIError(422,"invalid_policy","Choose a macOS application bundle.")
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
            throw APIError(422,"invalid_policy","The application signature could not be verified.")
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let details = info as? [String: Any], let identifier = details[kSecCodeInfoIdentifier as String] as? String else {
            throw APIError(422,"invalid_policy","The application has no verified signing identity.")
        }
        let team = details[kSecCodeInfoTeamIdentifier as String] as? String
        guard let certificates = details[kSecCodeInfoCertificates as String] as? [SecCertificate], !certificates.isEmpty else { throw APIError(422,"invalid_policy","Ad-hoc signed apps need a stronger supported identity.") }
        // Generic browser executables and generic web-app wrappers cannot identify one service.
        let excluded = ["com.apple.Safari", "com.google.Chrome", "com.brave.Browser", "org.mozilla.firefox", "com.apple.Safari.WebApp", "com.google.Chrome.app"]
        guard !excluded.contains(identifier), !identifier.hasPrefix("com.apple.Safari.WebApp."), !identifier.hasPrefix("com.google.Chrome.app.") else {
            throw APIError(422,"invalid_policy","Use the browser extension for browser apps; a site-specific app identity is required.")
        }
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else {
            throw APIError(422,"invalid_policy","The app signing requirement could not be read.")
        }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent
        return .init(displayName: name, status: "ready", identity: .init(signingIdentifier: identifier, teamIdentifier: team, designatedRequirement: text as String, executablePath: executable.path))
    }
    public static func processMatches(pid: Int32, requirement: String) -> Bool {
        var code: SecCode?; var req: SecRequirement?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary, [], &code) == errSecSuccess,
              let code, SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req else { return false }
        return SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), req) == errSecSuccess
    }
    public static func ownTeam() -> String? {
        var code: SecCode?; var info: CFDictionary?; var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code,[],&staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
