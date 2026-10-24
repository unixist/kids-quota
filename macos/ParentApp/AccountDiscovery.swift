import Foundation
import OpenDirectory

struct LocalAccount: Identifiable {
    let name: String; let displayName: String; let uid: UInt32; let generatedUID: String
    var id: String { generatedUID }
}
enum AccountDiscovery {
    static func children() throws -> [LocalAccount] {
        let node = try ODNode(session: ODSession.default(), type: UInt32(kODNodeTypeLocalNodes))
        let query = try ODQuery(node: node, forRecordTypes: kODRecordTypeUsers, attribute: kODAttributeTypeRecordName,
                                matchType: UInt32(kODMatchAny), queryValues: nil,
                                returnAttributes: [kODAttributeTypeRecordName, kODAttributeTypeFullName, kODAttributeTypeUniqueID, kODAttributeTypeGUID], maximumResults: 0)
        let administrators = try node.record(withRecordType: kODRecordTypeGroups, name: "admin", attributes: nil)
        return try (query.resultsAllowingPartial(false) as? [ODRecord] ?? []).compactMap { record in
            func first(_ key: String) -> String? { (try? record.values(forAttribute: key))?.first as? String }
            var isAdministrator = false
            do { try administrators.isMemberRecord(record); isAdministrator = true } catch { /* Not a member. */ }
            guard let uidText = first(kODAttributeTypeUniqueID), let uid = UInt32(uidText), uid >= 501,
                  let guid = first(kODAttributeTypeGUID), let name = first(kODAttributeTypeRecordName),
                  !name.hasPrefix("_"), !isAdministrator else { return nil }
            return LocalAccount(name: name, displayName: first(kODAttributeTypeFullName) ?? name, uid: uid, generatedUID: guid)
        }.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}
