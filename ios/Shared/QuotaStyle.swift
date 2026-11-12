import SwiftUI
import QuotaKit

enum QuotaStyle {
    static let blue = Color(red: 0.16, green: 0.38, blue: 0.88)
    static let teal = Color(red: 0.06, green: 0.52, blue: 0.48)
    static func color(_ balance: QuotaBalance) -> Color {
        if balance.isPaused || balance.coverage == "incomplete" { return .orange }
        if balance.isExhausted { return .red }
        if balance.fractionUsed >= 0.8 { return .orange }
        return teal
    }
    static func symbol(_ balance: QuotaBalance) -> String {
        if balance.serviceName.lowercased().contains("chess") { return "checkerboard.rectangle" }
        if balance.serviceName.lowercased().contains("chatgpt") { return "bubble.left.and.bubble.right" }
        return "globe"
    }
}
struct UpdatedLabel: View {
    let child: ChildDashboard
    var lastKnown = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(spacing: 4) {
                Image(systemName: lastKnown || child.isStale(at: context.date) ? "clock.badge.exclamationmark" : "clock")
                Text(lastKnown || child.isStale(at: context.date) ? "Last known ·" : "Updated")
                Text(child.capturedAt, style: .relative)
                Text("ago")
            }
            .font(.caption).foregroundStyle(lastKnown || child.isStale(at: context.date) ? .orange : .secondary)
        }
    }
}
