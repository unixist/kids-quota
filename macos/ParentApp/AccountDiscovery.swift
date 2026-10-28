import Foundation
import OpenDirectory
import Darwin

struct LocalAccount: Identifiable {
    let name: String; let displayName: String; let uid: UInt32; let generatedUID: String
    let isAdministrator: Bool?
    var id: String { generatedUID }
    var accountType: String {
        switch isAdministrator {
        case .some(true): return "Administrator"
        case .some(false): return "Standard"
        case .none: return "Account type unavailable"
        }
    }
}
enum AccountDiscovery {
    static func isCurrentUserAdministrator() -> Bool { administratorMembership(uid: getuid()) == true }
    private static func administratorMembership(uid: UInt32) -> Bool? {
        if uid == 0 { return true }
        guard let user = getpwuid(uid) else { return nil }
        let name = String(cString: user.pointee.pw_name), primary = Int32(bitPattern: user.pointee.pw_gid)
        guard let group = getgrnam("admin") else { return nil }
        let administratorGroup = Int32(bitPattern: group.pointee.gr_gid)
        var count: Int32 = 16, groups = [Int32](repeating: 0, count: 16)
        if getgrouplist(name, primary, &groups, &count) < 0 {
            guard count > 0, count <= 65_536 else { return nil }
            groups = [Int32](repeating: 0, count: Int(count))
            guard getgrouplist(name, primary, &groups, &count) >= 0 else { return nil }
        }
        guard count >= 0, count <= groups.count else { return nil }
        return groups.prefix(Int(count)).contains(administratorGroup)
    }
    // Keep selection consistent with the service's local-account UID boundary.
    // Membership is descriptive only: both account types can receive a quota.
    static func selectableAccount(name: String, displayName: String?, uid: UInt32,
                                  generatedUID: String, isAdministrator: Bool?) -> LocalAccount? {
        guard uid >= 500, !name.isEmpty, !name.hasPrefix("_"), !generatedUID.isEmpty else { return nil }
        return LocalAccount(name: name, displayName: displayName ?? name, uid: uid,
                            generatedUID: generatedUID, isAdministrator: isAdministrator)
    }
    static func children() throws -> [LocalAccount] {
        let node = try ODNode(session: ODSession.default(), type: UInt32(kODNodeTypeLocalNodes))
        let query = try ODQuery(node: node, forRecordTypes: kODRecordTypeUsers, attribute: kODAttributeTypeRecordName,
                                matchType: UInt32(kODMatchAny), queryValues: nil,
                                returnAttributes: [kODAttributeTypeRecordName, kODAttributeTypeFullName, kODAttributeTypeUniqueID, kODAttributeTypeGUID], maximumResults: 0)
        return try (query.resultsAllowingPartial(false) as? [ODRecord] ?? []).compactMap { record in
            func first(_ key: String) -> String? { (try? record.values(forAttribute: key))?.first as? String }
            guard let uidText = first(kODAttributeTypeUniqueID), let uid = UInt32(uidText),
                  let guid = first(kODAttributeTypeGUID), let name = first(kODAttributeTypeRecordName) else { return nil }
            return selectableAccount(name: name, displayName: first(kODAttributeTypeFullName), uid: uid,
                                     generatedUID: guid, isAdministrator: administratorMembership(uid: uid))
        }.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}
