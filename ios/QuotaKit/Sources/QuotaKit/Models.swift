import Foundation

public enum QuotaDataError: Error, LocalizedError {
    case invalidPairing, invalidSnapshot, unsupportedVersion
    public var errorDescription: String? {
        switch self {
        case .invalidPairing: return "This connection code is not valid. Use an iPhone connection code from your parent setup."
        case .invalidSnapshot: return "The dashboard returned data this app could not verify. Your last known balances are preserved."
        case .unsupportedVersion: return "This connection uses a newer format. Update Kids Quota and try again."
        }
    }
}

public struct PhoneConnection: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let endpoint: String
    public let familyName: String
    public let readToken: String
    public var origin: URL { URL(string: endpoint)! } // Validated before storage/use.
    public static func parse(_ text: String) throws -> PhoneConnection {
        guard text.utf8.count <= 16_384 else { throw QuotaDataError.invalidPairing }
        var data: Data?
        if let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), components.scheme == "kidsquota" {
            guard components.host == "pair", components.path.isEmpty, components.user == nil, components.password == nil,
                  components.fragment == nil, let query = components.queryItems, query.count == 1,
                  query[0].name == "data", let payload = query[0].value else { throw QuotaDataError.invalidPairing }
            var value = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            value += String(repeating: "=", count: (4 - value.count % 4) % 4)
            data = Data(base64Encoded: value)
        } else { data = text.data(using: .utf8) }
        guard let data, let value = try? JSONDecoder().decode(PhoneConnection.self, from: data) else { throw QuotaDataError.invalidPairing }
        try value.validate()
        return value
    }
    public func validate() throws {
        guard schemaVersion == 1 else { throw QuotaDataError.unsupportedVersion }
        guard let parts = URLComponents(string: endpoint), parts.scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/", Self.validPort(parts), parts.url != nil,
              endpoint.utf8.count <= 2048, !host.contains("%"),
              (32...512).contains(readToken.utf8.count), readToken.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0) }),
              !familyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, familyName.count <= 100 else { throw QuotaDataError.invalidPairing }
    }
    private static func validPort(_ components: URLComponents) -> Bool {
        guard let representation = components.string else { return false }
        if let range = components.rangeOfPort {
            let raw = representation[range]
            return !raw.isEmpty && raw.utf8.allSatisfy { (48...57).contains($0) }
                && Int(raw).map { (1...65535).contains($0) } == true
        }
        // Foundation reports nil both for absent and overflowing numeric ports.
        // Check the raw range above, and reject an explicitly empty port here.
        return !representation.trimmingCharacters(in: CharacterSet(charactersIn: "/")).hasSuffix(":")
    }
}

public struct FamilySnapshot: Codable, Sendable {
    public let schemaVersion: Int
    public let familyName: String
    public let servedAt: Date
    public let devices: [DeviceSnapshot]
    public var children: [ChildDashboard] {
        devices.flatMap { device in
            (device.snapshot?.children ?? []).map { child in
                ChildDashboard(deviceId: device.deviceId, deviceName: device.deviceName, child: child,
                               capturedAt: device.snapshot!.capturedAt, resetTimeZone: device.snapshot!.resetTimeZone)
            }
        }
    }
    public static func decode(_ data: Data, now: Date = Date()) throws -> FamilySnapshot {
        guard data.count <= 4_194_304 else { throw QuotaDataError.invalidSnapshot }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: raw) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: raw) else { throw QuotaDataError.invalidSnapshot }
            return date
        }
        let value: FamilySnapshot
        do { value = try decoder.decode(FamilySnapshot.self, from: data) } catch { throw QuotaDataError.invalidSnapshot }
        try value.validate(now: now)
        return value
    }
    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
    public func preservingNewerReports(from previous: FamilySnapshot?) -> FamilySnapshot {
        guard let previous else { return self }
        guard servedAt >= previous.servedAt else { return previous }
        let old = Dictionary(uniqueKeysWithValues: previous.devices.map { ($0.deviceId, $0) })
        let merged = devices.map { device -> DeviceSnapshot in
            guard let incoming = device.snapshot, let prior = old[device.deviceId], let snapshot = prior.snapshot,
                  snapshot.capturedAt > incoming.capturedAt else { return device }
            return prior
        }
        return FamilySnapshot(schemaVersion: schemaVersion, familyName: familyName, servedAt: servedAt, devices: merged)
    }
    public func freshnessTransitions(after date: Date, childId: String? = nil) -> [Date] {
        let selected = children.filter { childId == nil || $0.id == childId }
        return Array(Set(selected.flatMap { child in
            [child.capturedAt.addingTimeInterval(901)] + child.child.balances.map(\.periodEnd)
        }.filter { $0 > date && $0 <= date.addingTimeInterval(86_400) })).sorted()
    }
    public func validate(now: Date = Date()) throws {
        guard schemaVersion == 1, !familyName.isEmpty, familyName.count <= 100, devices.count <= 20,
              servedAt <= now.addingTimeInterval(300), Set(devices.map(\.deviceId)).count == devices.count else { throw QuotaDataError.invalidSnapshot }
        for device in devices {
            guard Self.validID(device.deviceId), !device.deviceName.isEmpty, device.deviceName.count <= 100 else { throw QuotaDataError.invalidSnapshot }
            guard let snapshot = device.snapshot else {
                guard device.receivedAt == nil else { throw QuotaDataError.invalidSnapshot }
                continue
            }
            guard let receivedAt = device.receivedAt, receivedAt <= now.addingTimeInterval(300),
                  snapshot.schemaVersion == 1, snapshot.deviceId == device.deviceId,
                  snapshot.capturedAt <= now.addingTimeInterval(300), snapshot.capturedAt <= receivedAt.addingTimeInterval(300),
                  TimeZone(identifier: snapshot.resetTimeZone) != nil, snapshot.children.count <= 20,
                  Set(snapshot.children.map(\.id)).count == snapshot.children.count else { throw QuotaDataError.invalidSnapshot }
            for child in snapshot.children {
                guard Self.validID(child.id), !child.name.isEmpty, child.name.count <= 100, child.balances.count <= 50,
                      Set(child.balances.map(\.quotaId)).count == child.balances.count else { throw QuotaDataError.invalidSnapshot }
                for balance in child.balances {
                    guard Self.validID(balance.quotaId), Self.validID(balance.serviceId), !balance.serviceName.isEmpty, balance.serviceName.count <= 100,
                          (0...604_800_000).contains(balance.limitSeconds), (0...9_007_199_254_740_991).contains(balance.usedSeconds),
                          balance.remainingSeconds == max(0, balance.limitSeconds - balance.usedSeconds),
                          balance.periodStart < balance.periodEnd, balance.periodStart <= snapshot.capturedAt,
                          snapshot.capturedAt < balance.periodEnd,
                          balance.quotaState == (balance.remainingSeconds == 0 ? "exhausted" : "available"),
                          ["complete", "incomplete"].contains(balance.coverage),
                          balance.blockingReason == nil || ["available", "exhausted", "collector_unavailable"].contains(balance.blockingReason!),
                          balance.domains.count <= 100, balance.domains.allSatisfy({ !$0.isEmpty && $0.count <= 253 }) else { throw QuotaDataError.invalidSnapshot }
                }
            }
        }
    }
    private static func validID(_ id: String) -> Bool {
        (1...100).contains(id.utf8.count) && id.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0) }
    }
}

/// Invalidates late asynchronous results when pairing, disconnecting, or refreshing.
public struct RequestGeneration: Sendable {
    private var current = UUID()
    public init() {}
    @discardableResult public mutating func advance() -> UUID { current = UUID(); return current }
    public var token: UUID { current }
    public func accepts(_ token: UUID) -> Bool { current == token }
}

public struct DeviceSnapshot: Codable, Sendable, Identifiable {
    public var id: String { deviceId }
    public let deviceId: String
    public let deviceName: String
    public let receivedAt: Date?
    public let snapshot: MacSnapshot?
}
public struct MacSnapshot: Codable, Sendable {
    public let schemaVersion: Int
    public let deviceId: String
    public let deviceName: String
    public let capturedAt: Date
    public let resetTimeZone: String
    public let children: [QuotaChild]
}
public struct QuotaChild: Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let balances: [QuotaBalance]
}
public struct QuotaBalance: Codable, Sendable, Identifiable {
    public var id: String { quotaId }
    public let quotaId: String
    public let serviceId: String
    public let serviceName: String
    public let domains: [String]
    public let limitSeconds: Int
    public let usedSeconds: Int
    public let remainingSeconds: Int
    public let periodStart: Date
    public let periodEnd: Date
    public let quotaState: String
    public let coverage: String
    public let blockingReason: String?
    public var fractionUsed: Double { limitSeconds == 0 ? 1 : min(1, Double(usedSeconds) / Double(limitSeconds)) }
    public var isPaused: Bool { blockingReason == "collector_unavailable" }
    public var isExhausted: Bool { remainingSeconds == 0 }
    public var status: String {
        if isPaused { return "Tracking paused" }
        if isExhausted { return "Weekly limit reached" }
        if coverage == "incomplete" { return "Check tracking" }
        return "Time available"
    }
}
public struct ChildDashboard: Sendable, Identifiable {
    public var id: String { deviceId + ":" + child.id }
    public let deviceId: String
    public let deviceName: String
    public let child: QuotaChild
    public let capturedAt: Date
    public let resetTimeZone: String
    public func isStale(at now: Date = Date()) -> Bool { now.timeIntervalSince(capturedAt) > 900 || child.balances.contains { now >= $0.periodEnd } }
}

public enum QuotaFormat {
    public static func duration(_ seconds: Int) -> String {
        let minutes = max(0, seconds) / 60
        if seconds > 0 && minutes == 0 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
    public static func reset(_ date: Date, timeZone: String) -> String {
        let formatter = DateFormatter(); formatter.timeZone = TimeZone(identifier: timeZone) ?? TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, h:mm a z"
        return formatter.string(from: date)
    }
}
