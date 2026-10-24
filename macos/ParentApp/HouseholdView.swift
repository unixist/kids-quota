import SwiftUI
import AppKit

struct HouseholdView: View {
    @EnvironmentObject private var store: ParentStore
    @State private var sheet: HouseholdSheet?
    var body: some View {
        NavigationSplitView {
            List(selection: $store.selectedChild) {
                Section("Children") { ForEach(store.children) { child in Label(child.displayName, systemImage: "person.crop.circle").tag(child.id) } }
            }
            .safeAreaInset(edge: .bottom) {
                Button { sheet = .child } label: { Label("Add child", systemImage: "plus") }.padding().frame(maxWidth: .infinity)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 190)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(store.selectedChild.isEmpty ? "Welcome to Kids Quota" : "\(store.childName)'s week").font(.largeTitle.bold())
                            Text("One weekly allowance for each service's websites and selected apps.").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { sheet = .settings } label: { Image(systemName: "gearshape") }.help("Settings")
                    }
                    if let error = store.error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).padding().frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12)) }
                    if store.children.isEmpty {
                        ContentUnavailableView { Label("Start with a child account", systemImage: "person.badge.plus") } description: {
                            Text("Create a standard macOS login for each child in System Settings, then link it here.")
                        } actions: { Button("Add child") { sheet = .child }.buttonStyle(.borderedProminent) }
                    } else {
                        HStack {
                            Text("Weekly allowances").font(.title2.bold()); Spacer()
                            Button { sheet = .service } label: { Label("Add service", systemImage: "plus") }.buttonStyle(.borderedProminent)
                        }
                        if store.quotas.isEmpty { Text("Add Chess.com, ChatGPT, or any other website. Each service starts with six hours per week.").foregroundStyle(.secondary).padding(.vertical, 30) }
                        ForEach(store.quotas) { quota in
                            if let service = store.services.first(where: { $0.id == quota.serviceId }) {
                                ServiceCard(service: service, quota: quota, balance: store.balances.first { $0.quotaId == quota.id }, editHours: { sheet = .hours(quota) }, manage: { sheet = .manage(service) })
                            }
                        }
                        if let reset = store.state?.policy.reset {
                            Label("Resets \(reset.weekday.capitalized) at \(reset.localTime) · \(reset.timeZone)", systemImage: "arrow.clockwise").font(.callout).foregroundStyle(.secondary)
                        }
                        if let pending = store.state?.policy.pendingReset { Text("Next schedule: \(pending.schedule.weekday.capitalized) at \(pending.schedule.localTime) · starts after this week").font(.caption).foregroundStyle(.secondary) }
                        Text("Websites require the browser extension. App limits block internet access; cached and offline features can still work.").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(28)
            }
        }
        .sheet(item: $sheet) { value in
            switch value {
            case .child: AddChildView()
            case .service: AddServiceView()
            case .hours(let quota): EditHoursView(quota: quota)
            case .manage(let service): ManageServiceView(service: service)
            case .settings: SettingsView().frame(width: 650, height: 570)
            }
        }
        .task { while !Task.isCancelled { await store.refresh(); try? await Task.sleep(for: .seconds(3)) } }
        .onChange(of: store.selectedChild) { _, _ in Task { await store.refresh() } }
        .toolbar { Button { Task { await store.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") } }
    }
}
private enum HouseholdSheet: Identifiable {
    case child, service, settings, hours(QuotaItem), manage(ServiceItem)
    var id: String { switch self { case .child: return "child"; case .service: return "service"; case .settings: return "settings"; case .hours(let quota): return quota.id; case .manage(let service): return service.id } }
}
private struct ServiceCard: View {
    @EnvironmentObject var store: ParentStore
    let service: ServiceItem; let quota: QuotaItem; let balance: BalanceItem?
    let editHours: () -> Void; let manage: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Image(systemName: service.id == "chesscom" ? "checkerboard.rectangle" : service.id == "chatgpt" ? "bubble.left.and.bubble.right" : "globe").font(.title2).frame(width: 36)
                VStack(alignment: .leading, spacing: 3) { Text(service.name).font(.title3.bold()); Text("\(Presentation.duration(quota.weeklyLimitSeconds)) per week").font(.callout).foregroundStyle(.secondary) }
                Spacer(); Button("Edit hours", action: editHours)
            }
            if let balance {
                HStack(alignment: .firstTextBaseline) {
                    Text(Presentation.duration(balance.remainingSeconds)).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(balance.quotaState == "exhausted" ? "weekly limit reached" : "remaining").foregroundStyle(.secondary)
                    Spacer()
                    Label(!store.connected ? "Connection lost" : balance.coverage == "complete" ? "Covered" : "Check coverage", systemImage: balance.coverage == "complete" && store.connected ? "checkmark.shield" : "exclamationmark.shield")
                        .font(.caption).foregroundStyle(balance.coverage == "complete" && store.connected ? .green : .orange)
                }
                ProgressView(value: Double(max(0, balance.limitSeconds - balance.remainingSeconds)), total: Double(max(1, balance.limitSeconds))).tint(balance.quotaState == "exhausted" ? .orange : .accentColor)
            } else { Text("Waiting for the service…").foregroundStyle(.secondary) }
            DisclosureGroup("Includes") {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(service.domains, id: \.self) { domain in Label(domain.hostname + (domain.includeSubdomains ? " and subdomains" : ""), systemImage: "globe") }
                    ForEach(service.applicationIds, id: \.self) { id in Label(store.state?.policy.applicationBindings.first { $0.id == id }?.displayName ?? "App needs review", systemImage: "app") }
                    if service.applicationIds.isEmpty { Text("Website only · Choose an app to share this allowance with its Mac app.").foregroundStyle(.secondary) }
                    if balance?.coverage != "complete" { Text("Open both browsers in the child's account to check coverage. Also check website permissions, the login agent, and app filter in Settings.").foregroundStyle(.orange) }
                    Button("Manage included websites and apps", action: manage)
                }.font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            }
        }.padding(20).background(.background, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary))
    }
}
