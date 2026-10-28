import Foundation

/// The collector's read-only response. The daemon selects the child from the
/// authenticated macOS user, so this request never accepts a child identifier.
public struct ChildStatusSnapshot: Decodable, Equatable {
    public let configured: Bool
    public let childName: String?
    public let resetTimeZone: String?
    public let items: [ChildStatusItem]

    private enum CodingKeys: String, CodingKey { case type, configured, childName, resetTimeZone, items }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(String.self, forKey: .type) == "childStatus" else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: values, debugDescription: "Not a child status response.")
        }
        configured = try values.decode(Bool.self, forKey: .configured)
        if configured {
            let name = try values.decode(String.self, forKey: .childName)
            let zone = try values.decode(String.self, forKey: .resetTimeZone)
            let balances = try values.decode([ChildStatusItem].self, forKey: .items)
            guard !name.isEmpty, TimeZone(identifier: zone) != nil,
                  Set(balances.map(\.serviceId)).count == balances.count else {
                throw DecodingError.dataCorruptedError(forKey: .items, in: values, debugDescription: "Invalid child status.")
            }
            childName = name; resetTimeZone = zone; items = balances
        } else {
            // A removed or unlinked account must never retain old balances.
            childName = nil; resetTimeZone = nil; items = []
        }
    }

    public static func decode(_ object: [String: Any]) throws -> Self {
        try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

public struct ChildStatusItem: Decodable, Equatable, Identifiable {
    public struct Domain: Decodable, Equatable {
        public let hostname: String
        public let includeSubdomains: Bool
    }
    public let serviceId: String
    public let name: String
    public let domains: [Domain]
    public let weeklyLimitSeconds: Int
    public let usedSeconds: Int
    public let remainingSeconds: Int
    public let resetAt: Date
    public let coverage: String
    public var id: String { serviceId }
    public var fractionRemaining: Double {
        guard weeklyLimitSeconds > 0 else { return 0 }
        return min(1, max(0, Double(remainingSeconds) / Double(weeklyLimitSeconds)))
    }

    private enum CodingKeys: String, CodingKey { case serviceId, name, domains, weeklyLimitSeconds, usedSeconds, remainingSeconds, resetAt, coverage }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        serviceId = try values.decode(String.self, forKey: .serviceId)
        name = try values.decode(String.self, forKey: .name)
        domains = try values.decode([Domain].self, forKey: .domains)
        weeklyLimitSeconds = try values.decode(Int.self, forKey: .weeklyLimitSeconds)
        usedSeconds = try values.decode(Int.self, forKey: .usedSeconds)
        remainingSeconds = try values.decode(Int.self, forKey: .remainingSeconds)
        coverage = try values.decode(String.self, forKey: .coverage)
        let reset = try values.decode(String.self, forKey: .resetAt)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsed = formatter.date(from: reset) ?? ISO8601DateFormatter().date(from: reset)
        guard let parsed, !serviceId.isEmpty, !name.isEmpty,
              weeklyLimitSeconds >= 0, usedSeconds >= 0,
              remainingSeconds >= 0, remainingSeconds <= weeklyLimitSeconds else {
            throw DecodingError.dataCorruptedError(forKey: .remainingSeconds, in: values, debugDescription: "Invalid time balance.")
        }
        resetAt = parsed
    }
}

/// No local countdown: balances are always authoritative daemon snapshots.
public enum ChildStatusDisplayState: Equatable {
    case loading
    case notConfigured
    case unavailable
    case ready(ChildStatusSnapshot)

    public mutating func accept(_ response: [String: Any]?) {
        guard let response, let status = try? ChildStatusSnapshot.decode(response) else { self = .unavailable; return }
        self = status.configured ? .ready(status) : .notConfigured
    }
}

public enum ChildStatusPresentation {
    public static func duration(_ seconds: Int) -> String {
        let seconds = max(0, seconds)
        if seconds > 0 && seconds < 60 { return "<1m" }
        let minutes = seconds / 60
        if minutes >= 60 { return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }

    public static func accessibleDuration(_ seconds: Int) -> String {
        let seconds = max(0, seconds)
        if seconds > 0 && seconds < 60 { return "Less than a minute" }
        let minutes = seconds / 60, hours = seconds / 3600
        let hourText = "\(hours) \(hours == 1 ? "hour" : "hours")"
        let minuteText = "\(minutes % 60) \(minutes % 60 == 1 ? "minute" : "minutes")"
        if hours == 0 { return minuteText }
        return minutes % 60 == 0 ? hourText : hourText + " " + minuteText
    }

    public static func resetLabel(_ date: Date, timeZone: String, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = TimeZone(identifier: timeZone) ?? .current
        formatter.setLocalizedDateFormatFromTemplate("EEE MMM d h mm a z")
        return formatter.string(from: date)
    }
}
