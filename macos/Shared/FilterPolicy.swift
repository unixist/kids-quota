import Foundation

struct FilterRule: Decodable, Equatable {
    let uid: UInt32
    let requirement: String
    let blocked: Bool
    let serviceId: String
}
struct FilterPolicy: Decodable {
    let rules: [FilterRule]
    let revision: Int
    let childUIDs: [UInt32]
    enum CodingKeys: String, CodingKey { case rules, revision, childUIDs }
    init(rules: [FilterRule] = [], revision: Int = 0, childUIDs: [UInt32] = []) { self.rules = rules; self.revision = revision; self.childUIDs = childUIDs }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rules = try c.decode([FilterRule].self, forKey: .rules); revision = try c.decode(Int.self, forKey: .revision)
        childUIDs = try c.decodeIfPresent([UInt32].self, forKey: .childUIDs) ?? Array(Set(rules.map(\.uid)))
    }
    func monitors(_ uid: UInt32) -> Bool { childUIDs.contains(uid) || rules.contains { $0.uid == uid } }
    func blocks(uid: UInt32, isStale: Bool, matches: (String) -> Bool) -> Bool {
        rules.contains { $0.uid == uid && ($0.blocked || isStale) && matches($0.requirement) }
    }
}

/// Darwin audit_token_t is eight UInt32 words; euid is word 1 (not auid or pid).
enum AuditIdentity {
    static func effectiveUID(_ data: Data?) -> UInt32? {
        guard let data, data.count == 32 else { return nil }
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
    }
}
