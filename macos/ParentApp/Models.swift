import Foundation

struct ChildItem: Identifiable, Decodable { let id: String; let displayName: String }
struct DomainItem: Codable, Hashable { let hostname: String; let includeSubdomains: Bool }
struct ServiceItem: Identifiable, Decodable { let id: String; let name: String; let domains: [DomainItem]; let applicationIds: [String] }
struct AppItem: Identifiable, Decodable { let id: String; let displayName: String; let status: String }
struct QuotaItem: Identifiable, Decodable { let id: String; let childId: String; let serviceId: String; let weeklyLimitSeconds: Int }
struct BalanceItem: Decodable {
    let quotaId: String; let serviceId: String; let limitSeconds: Int; let usedSeconds: Int; let remainingSeconds: Int
    let quotaState: String; let coverage: String; let periodEnd: String
}
struct ResetItem: Decodable { var weekday: String; var localTime: String; var timeZone: String }
struct PendingResetItem: Decodable { let schedule: ResetItem; let effectiveAt: String }
struct ClientItem: Decodable, Identifiable { let id: String; let name: String; let scopes: [String]; let childIds: [String]; let administrator: Bool? }
struct AdminState: Decodable {
    let policyRevision: Int
    let policy: HouseholdPolicy
    let clients: [ClientItem]
    let filterConnected: Bool?
    let unattributedFlows: Int?
}
struct HouseholdPolicy: Decodable {
    let children: [ChildItem]; let services: [ServiceItem]; let applicationBindings: [AppItem]; let quotas: [QuotaItem]; let reset: ResetItem; let pendingReset: PendingResetItem?
}
struct BalanceList: Decodable { let items: [BalanceItem] }

enum Presentation {
    static func duration(_ seconds: Int) -> String {
        let minutes = max(0, seconds) / 60
        if seconds > 0 && minutes == 0 { return "Less than a minute" }
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
    static func host(_ input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let url = URLComponents(string: text.contains("://") ? text : "https://" + text),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil, let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasSuffix(".") ? String(host.dropLast()) : host
    }
}
