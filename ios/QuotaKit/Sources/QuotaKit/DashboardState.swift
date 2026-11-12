import Foundation

/// A saved connection that cannot currently be read is not an unpaired phone.
public enum ConnectionLoad: Equatable, Sendable {
    case absent, unavailable, invalid
    case available(PhoneConnection)

    public var connection: PhoneConnection? {
        if case .available(let value) = self { return value }
        return nil
    }
    public var issue: DashboardIssue? {
        switch self {
        case .absent: return .notConnected
        case .unavailable: return .connectionUnavailable
        case .invalid: return .reconnect
        case .available: return nil
        }
    }
}

/// Short, shared explanations for the app and widget. No credentials or server
/// diagnostics are included in these user-facing messages.
public enum DashboardIssue: String, Error, LocalizedError, Equatable, Sendable {
    case notConnected, connectionUnavailable, reconnect, cannotRefresh
    case invalidReport, localStorage, waitingForMac, noChildren, chooseChild

    public var title: String {
        switch self {
        case .notConnected: return "Connect your family"
        case .connectionUnavailable: return "Saved connection unavailable"
        case .reconnect: return "Reconnect this iPhone"
        case .cannotRefresh: return "Can't refresh balances"
        case .invalidReport: return "Couldn't read the Mac report"
        case .localStorage: return "Can't save balances"
        case .waitingForMac: return "No saved Mac report"
        case .noChildren: return "No children configured"
        case .chooseChild: return "Choose a child"
        }
    }
    public var message: String {
        switch self {
        case .notConnected: return "Use your own iPhone connection code from parent setup."
        case .connectionUnavailable: return "Unlock this iPhone and try again. If the problem continues, reopen Kids Quota or install the latest app."
        case .reconnect: return "Get a new iPhone connection code from parent setup, then reconnect."
        case .cannotRefresh: return "Check your internet connection and try again. Any balances shown are the last known report."
        case .invalidReport: return "Try again. If this continues, update Kids Quota on your iPhone and Macs. Any balances shown are the last known report."
        case .localStorage: return "These balances were received, but couldn't be saved for your widget or offline use. Try again; if this continues, install the latest app."
        case .waitingForMac: return "Open Kids Quota parent settings on the Mac and check its phone connection."
        case .noChildren: return "Choose the accounts to manage in Kids Quota parent settings on the Mac."
        case .chooseChild: return "Touch and hold the widget, choose Edit Widget, and select a child."
        }
    }
    public var actionTitle: String {
        switch self {
        case .notConnected: return "Connect your family"
        case .reconnect: return "Reconnect"
        default: return "Try again"
        }
    }
    public var needsConnectionCode: Bool { self == .notConnected || self == .reconnect }
    public var usesLastKnownBalance: Bool {
        [.connectionUnavailable, .reconnect, .cannotRefresh, .invalidReport].contains(self)
    }
    public var errorDescription: String? { message }
}

public extension FamilySnapshot {
    var unreportedMacCount: Int { devices.filter { $0.snapshot == nil }.count }
    var unreportedMacSummary: String? {
        guard unreportedMacCount > 0 else { return nil }
        return unreportedMacCount == 1 ? "1 Mac has no saved report" : "\(unreportedMacCount) Macs have no saved report"
    }
    func emptyState(childID: String? = nil) -> DashboardIssue {
        if let childID, !children.contains(where: { $0.id == childID }) {
            let deviceID = childID.split(separator: ":", maxSplits: 1).first.map(String.init)
            if devices.contains(where: { $0.deviceId == deviceID && $0.snapshot == nil }) { return .waitingForMac }
            return .chooseChild
        }
        return devices.isEmpty || unreportedMacCount > 0 ? .waitingForMac : .noChildren
    }
}

public extension ChildDashboard {
    var trackingNotice: String? {
        if child.balances.contains(where: \.isPaused) { return "Tracking paused on Mac" }
        if child.balances.contains(where: { $0.coverage == "incomplete" }) { return "Check tracking on Mac" }
        return nil
    }
}
