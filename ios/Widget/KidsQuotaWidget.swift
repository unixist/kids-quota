import SwiftUI
import WidgetKit
import AppIntents
import QuotaKit

struct ChildChoice: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Child"
    static var defaultQuery = ChildQuery()
    var id: String
    var name: String
    var device: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)", subtitle: "\(device)") }
}
struct ChildQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ChildChoice] { choices().filter { identifiers.contains($0.id) } }
    func suggestedEntities() async throws -> [ChildChoice] { choices() }
    private func choices() -> [ChildChoice] {
        guard let connection = PhoneStorage.connection().connection, let family = PhoneStorage.cached(for: connection) else { return [] }
        return family.children.map { ChildChoice(id: $0.id, name: $0.child.name, device: $0.deviceName) }
    }
}
struct QuotaWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Quota overview"
    static var description = IntentDescription("See everyone, or focus on one child.")
    @Parameter(title: "Child") var child: ChildChoice?
}
struct QuotaEntry: TimelineEntry {
    let date: Date
    let family: FamilySnapshot?
    let childId: String?
    let issue: DashboardIssue?
}
struct QuotaProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> QuotaEntry { QuotaEntry(date: .now, family: DemoFamily.snapshot(), childId: nil, issue: nil) }
    func snapshot(for configuration: QuotaWidgetIntent, in context: Context) async -> QuotaEntry {
        if context.isPreview { return placeholder(in: context) }
        return await load(configuration)
    }
    func timeline(for configuration: QuotaWidgetIntent, in context: Context) async -> Timeline<QuotaEntry> {
        let entry = await load(configuration)
        // A second entry changes the freshness label even when iOS defers networking.
        let transitions = entry.family?.freshnessTransitions(after: entry.date, childId: entry.childId) ?? []
        var entries = [entry]
        for next in transitions.prefix(100) { entries.append(QuotaEntry(date: next, family: entry.family, childId: entry.childId, issue: entry.issue)) }
        return Timeline(entries: entries, policy: .after(Date().addingTimeInterval(900)))
    }
    private func load(_ configuration: QuotaWidgetIntent) async -> QuotaEntry {
        let result = await DashboardReader.load()
        return QuotaEntry(date: .now, family: result.family, childId: configuration.child?.id, issue: result.issue)
    }
}
struct QuotaWidgetView: View {
    let entry: QuotaEntry
    @Environment(\.widgetFamily) private var size
    private var children: [ChildDashboard] {
        let all = entry.family?.children ?? []
        return entry.childId.map { id in all.filter { $0.id == id } } ?? all
    }
    private var limit: Int { size == .systemSmall ? 1 : size == .systemMedium ? 2 : 4 }
    private var lastKnown: Bool { entry.issue?.usesLastKnownBalance == true || children.prefix(limit).contains { $0.isStale(at: entry.date) } }
    private var notice: String? { entry.issue?.title ?? entry.family?.unreportedMacSummary ?? children.prefix(limit).compactMap(\.trackingNotice).first }
    var body: some View {
        VStack(alignment: .leading, spacing: size == .systemMedium ? 4 : 6) {
            HStack(spacing: 5) {
                Image(systemName: "hourglass").foregroundStyle(QuotaStyle.blue)
                Text("Time left").font(.subheadline.bold())
                Spacer(minLength: 0)
            }
            if children.isEmpty {
                Spacer(minLength: 0)
                let issue = entry.issue ?? entry.family?.emptyState(childID: entry.childId) ?? .waitingForMac
                Text(issue.title).font(.headline)
                Text(issue == .chooseChild ? "Touch and hold, then Edit Widget." : "Open Kids Quota for the next step.").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                if let notice {
                    Text(notice).font(.system(size: 10, weight: .medium)).foregroundStyle(.orange).lineLimit(1).minimumScaleFactor(0.8)
                }
                ForEach(Array(children.prefix(limit))) { child in
                    if size == .systemSmall { smallChild(child) }
                    else { childRow(child) }
                }
                Spacer(minLength: 0)
                HStack(spacing: 3) {
                    if let oldest = children.prefix(limit).map(\.capturedAt).min() {
                        Image(systemName: lastKnown ? "clock.badge.exclamationmark" : "clock")
                        Text(lastKnown ? "Last known" : "Updated")
                        Text(oldest, style: .relative)
                        Text("ago")
                    }
                    Spacer(minLength: 0)
                    if children.count > limit { Text("+\(children.count - limit)") }
                }.font(.system(size: 10)).foregroundStyle(lastKnown ? .orange : .secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .containerBackground(for: .widget) { Color(uiColor: .systemBackground) }
        .widgetURL(URL(string: "kidsquota://dashboard"))
        .privacySensitive()
    }
    @ViewBuilder private func smallChild(_ child: ChildDashboard) -> some View {
        Text(child.child.name).font(.headline).lineLimit(1)
        Text(child.deviceName).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        if child.child.balances.isEmpty { Text("No allowances configured").font(.caption2).foregroundStyle(.secondary) }
        ForEach(Array(child.child.balances.prefix(2))) { balance in
            HStack {
                Text(balance.serviceName).font(.caption2).lineLimit(1)
                Spacer(minLength: 3)
                Text(QuotaFormat.duration(balance.remainingSeconds)).font(.caption.bold().monospacedDigit()).foregroundStyle(QuotaStyle.color(balance)).lineLimit(1)
            }
        }
        if child.child.balances.count > 2 { Text("+\(child.child.balances.count - 2) services in app").font(.system(size: 9)).foregroundStyle(.secondary) }
    }
    @ViewBuilder private func childRow(_ child: ChildDashboard) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(child.child.name).font(.subheadline.bold()).lineLimit(1)
                if child.child.balances.count > 2 { Text("+\(child.child.balances.count - 2) services").font(.system(size: 9)).foregroundStyle(.secondary) }
                Spacer()
                Text(child.deviceName).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 14) {
                ForEach(Array(child.child.balances.prefix(2))) { balance in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(balance.serviceName).font(.system(size: 10)).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(QuotaFormat.duration(balance.remainingSeconds)).font(.caption.bold().monospacedDigit()).foregroundStyle(QuotaStyle.color(balance)).lineLimit(1).minimumScaleFactor(0.85)
                        }
                    }.frame(maxWidth: .infinity).accessibilityElement(children: .combine)
                        .accessibilityLabel("\(balance.serviceName): \(QuotaFormat.duration(balance.remainingSeconds)) left. \(balance.status)")
                }
            }
            if child.child.balances.isEmpty { Text("No allowances configured").font(.system(size: 10)).foregroundStyle(.secondary) }
        }
    }
}
@main struct KidsQuotaWidget: Widget {
    let kind = "KidsQuotaOverview"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: QuotaWidgetIntent.self, provider: QuotaProvider()) { QuotaWidgetView(entry: $0) }
            .configurationDisplayName("Family time left").description("Your children's latest weekly quota balances.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
