import SwiftUI
import QuotaKit

struct FamilyDashboard: View {
    @ObservedObject var store: FamilyStore
    @Binding var incomingPairing: String?
    @State private var showPairing = false
    @State private var showSettings = false
    var body: some View {
        NavigationStack {
            Group {
                if let snapshot = store.snapshot {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            Text("Time left this week").font(.largeTitle.bold()).fixedSize(horizontal: false, vertical: true)
                            if store.isDemo {
                                Label("Sample family · not your children's data", systemImage: "sparkles")
                                    .font(.footnote.weight(.medium)).foregroundStyle(QuotaStyle.blue)
                            }
                            if let issue = store.issue { issueNotice(issue) }
                            ForEach(snapshot.children) { child in ChildCard(child: child, lastKnown: store.issue?.usesLastKnownBalance == true) }
                            ForEach(snapshot.devices.filter { $0.snapshot == nil }) { device in
                                Label("Waiting for an update from \(device.deviceName). Open Kids Quota parent settings on that Mac to check its phone connection.", systemImage: "desktopcomputer")
                                    .font(.subheadline).foregroundStyle(.secondary).padding().frame(maxWidth: .infinity, alignment: .leading).background(.background, in: RoundedRectangle(cornerRadius: 20))
                            }
                            if snapshot.children.isEmpty && snapshot.unreportedMacCount == 0 {
                                ContentUnavailableView(snapshot.emptyState().title, systemImage: "person.2", description: Text(snapshot.emptyState().message))
                            }
                        }.padding(20)
                    }.refreshable { await store.refresh() }
                } else if store.connection != nil || (store.issue != nil && store.issue != .notConnected) {
                    VStack(spacing: 18) {
                        if store.isRefreshing {
                            ProgressView("Loading balances")
                        } else {
                            let issue = store.issue ?? .cannotRefresh
                            ContentUnavailableView(issue.title, systemImage: "exclamationmark.circle", description: Text(issue.message))
                            Button(issue.actionTitle) { resolve(issue) }.buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    VStack(spacing: 24) {
                        Image(systemName: "hourglass.circle.fill").font(.system(size: 76)).foregroundStyle(QuotaStyle.blue)
                        Text("See your children's time left").font(.largeTitle.bold()).multilineTextAlignment(.center)
                        Text("See each child's weekly time left on your iPhone and Home Screen.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Connect your family") { showPairing = true }.buttonStyle(.borderedProminent).controlSize(.large)
                        Button("See a sample") { store.showDemo() }.font(.subheadline)
                    }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(store.snapshot?.familyName ?? "Kids Quota").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        if store.isRefreshing { ProgressView().controlSize(.small) }
                        Button("Settings", systemImage: "gearshape") { showSettings = true }.labelStyle(.iconOnly)
                    }
                }
            }
            .sheet(isPresented: $showPairing, onDismiss: { incomingPairing = nil }) { PairingView(store: store, initialCode: incomingPairing ?? "") }
            .sheet(isPresented: $showSettings) { PhoneSettings(store: store, connect: { showSettings = false; showPairing = true }) }
            .onChange(of: incomingPairing) { _, value in if value != nil { showPairing = true } }
        }.tint(QuotaStyle.blue)
    }
    private func resolve(_ issue: DashboardIssue) {
        if issue.needsConnectionCode { showPairing = true }
        else { Task { await store.refresh() } }
    }
    private func issueNotice(_ issue: DashboardIssue) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(issue.title, systemImage: "exclamationmark.circle").font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
            Text(issue.message).font(.footnote).foregroundStyle(.secondary)
            Button(issue.actionTitle) { resolve(issue) }.font(.subheadline).disabled(store.isRefreshing)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ChildCard: View {
    let child: ChildDashboard
    let lastKnown: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(String(child.child.name.prefix(1))).font(.title3.bold()).foregroundStyle(QuotaStyle.blue)
                    .frame(width: 44, height: 44).background(QuotaStyle.blue.opacity(0.1), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(child.child.name).font(.title2.bold())
                    Text(child.deviceName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if child.child.balances.isEmpty { Text("No allowances configured").font(.subheadline).foregroundStyle(.secondary) }
            ForEach(child.child.balances) { balance in
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .firstTextBaseline) {
                        Label(balance.serviceName, systemImage: QuotaStyle.symbol(balance)).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(QuotaFormat.duration(balance.remainingSeconds)).font(.title2.bold().monospacedDigit()).foregroundStyle(QuotaStyle.color(balance))
                        Text("left").font(.caption).foregroundStyle(.secondary)
                    }
                    ProgressView(value: balance.fractionUsed).tint(QuotaStyle.color(balance))
                        .accessibilityLabel("\(balance.serviceName) usage").accessibilityValue("\(QuotaFormat.duration(balance.usedSeconds)) used of \(QuotaFormat.duration(balance.limitSeconds))")
                    HStack(alignment: .top) {
                        Text("\(QuotaFormat.duration(balance.usedSeconds)) of \(QuotaFormat.duration(balance.limitSeconds)) used").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if balance.status != "Time available" { Text(balance.status).font(.caption.weight(.medium)).foregroundStyle(balance.isPaused ? .orange : balance.isExhausted ? .red : .orange) }
                    }
                    Text("Resets \(QuotaFormat.reset(balance.periodEnd, timeZone: child.resetTimeZone))").font(.caption2).foregroundStyle(.secondary)
                }
                if balance.id != child.child.balances.last?.id { Divider() }
            }
            UpdatedLabel(child: child, lastKnown: lastKnown)
        }.padding(20).background(.background, in: RoundedRectangle(cornerRadius: 24)).privacySensitive()
    }
}

private struct PhoneSettings: View {
    @ObservedObject var store: FamilyStore
    let connect: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDisconnect = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Family connection") {
                    if store.isDemo { Button("Leave sample family") { store.endDemo(); dismiss() } }
                    if let connection = store.connection {
                        LabeledContent("Family", value: connection.familyName)
                        LabeledContent("Dashboard", value: connection.origin.host ?? "")
                        Button("Disconnect this iPhone", role: .destructive) { confirmDisconnect = true }
                    } else { Button("Connect your family", action: connect) }
                    if let error { Text(error).foregroundStyle(.red) }
                }
                Section("Add a Home Screen widget") {
                    Text("Touch and hold your Home Screen, tap Edit → Add Widget, then search for Kids Quota. Choose an overview size. Touch and hold the widget and choose Edit Widget to select one child.")
                }
                Section("Privacy and updates") {
                    Text("This phone can only read quota summaries. Allowances and resets are controlled in the parent Mac app.")
                    Text("Each parent's connection can be revoked independently in your cloud setup. Disconnecting here removes the connection and cached balances from this phone.")
                    Text("Macs report about every 5 minutes while awake. Your widget requests updates about every 15 minutes, but iOS chooses the timing. Open or pull to refresh the app to check for a newer report; this does not wake a sleeping Mac.")
                    Text("Balances are labeled Last known after 15 minutes, at a weekly reset without a new report, or when a refresh fails. The app never guesses how much time remains.")
                }
            }.navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { dismiss() } }
                .confirmationDialog("Disconnect this iPhone?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                    Button("Disconnect", role: .destructive) { do { try store.disconnect(); dismiss() } catch { self.error = error.localizedDescription } }
                } message: { Text("Your Mac allowances and your other parent's phone will keep working.") }
        }
    }
}
