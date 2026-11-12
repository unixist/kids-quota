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
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text("Time left this week").font(.largeTitle.bold()).fixedSize(horizontal: false, vertical: true)
                                    Text("Weekly time left for your family").font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "hourglass").font(.title).foregroundStyle(QuotaStyle.blue).padding(15).background(QuotaStyle.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 20))
                            }
                            if store.isDemo {
                                Label("Sample family · not your children's data", systemImage: "sparkles")
                                    .font(.footnote.weight(.medium)).foregroundStyle(QuotaStyle.blue)
                            }
                            if let error = store.errorMessage {
                                Label(error, systemImage: "wifi.exclamationmark").font(.subheadline).foregroundStyle(.orange)
                            }
                            ForEach(snapshot.children) { child in ChildCard(child: child) }
                            ForEach(snapshot.devices.filter { $0.snapshot == nil }) { device in
                                Label("\(device.deviceName) hasn't reported yet. Open parent settings on that Mac to connect it.", systemImage: "desktopcomputer")
                                    .font(.subheadline).foregroundStyle(.secondary).padding().frame(maxWidth: .infinity, alignment: .leading).background(.background, in: RoundedRectangle(cornerRadius: 20))
                            }
                            if snapshot.devices.allSatisfy({ $0.snapshot?.children.isEmpty != false }) && snapshot.devices.allSatisfy({ $0.snapshot != nil }) {
                                ContentUnavailableView("No children yet", systemImage: "person.2", description: Text("Choose the accounts to manage in the Kids Quota Mac app."))
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Your Mac keeps the time").font(.subheadline.weight(.semibold))
                                Text("Macs report about every 5 minutes while awake. Widgets refresh when iOS allows. Time shown is the last reported balance; opening this app checks for a newer report.").font(.footnote).foregroundStyle(.secondary)
                            }.padding(.horizontal, 4)
                        }.padding(20)
                    }.refreshable { await store.refresh() }
                } else if store.connection != nil {
                    VStack(spacing: 18) {
                        ContentUnavailableView("Waiting for your dashboard", systemImage: "icloud", description: Text(store.errorMessage ?? "Connecting to your family's latest quota balances."))
                        Button("Try again") { Task { await store.refresh() } }.buttonStyle(.borderedProminent)
                    }
                } else {
                    VStack(spacing: 24) {
                        Image(systemName: "hourglass.circle.fill").font(.system(size: 76)).foregroundStyle(QuotaStyle.blue)
                        Text("Their time.\nAt a glance.").font(.largeTitle.bold()).multilineTextAlignment(.center)
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
}

private struct ChildCard: View {
    let child: ChildDashboard
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
            UpdatedLabel(child: child)
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
                    Text("Your widget requests a refresh about every 15 minutes. iOS chooses the actual timing. Sleeping or disconnected Macs keep their last reported balance, labeled as old after 15 minutes.")
                }
            }.navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { dismiss() } }
                .confirmationDialog("Disconnect this iPhone?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                    Button("Disconnect", role: .destructive) { do { try store.disconnect(); dismiss() } catch { self.error = error.localizedDescription } }
                } message: { Text("Your Mac allowances and your other parent's phone will keep working.") }
        }
    }
}
