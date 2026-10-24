import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var store: ParentStore
    @StateObject private var filter = FilterActivation()
    @State private var weekday = "monday"; @State private var localTime = "00:00"; @State private var timeZone = TimeZone.current.identifier
    @State private var openedRevision: Int?
    @State private var token = ""; @State private var clientName = ""; @State private var childIDs: Set<String> = []
    @State private var issuedToken: String?; @State private var message: String?; @State private var busy = false
    private let weekdays = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
    var body: some View {
        TabView {
            Form {
                Section("Weekly reset") {
                    Picker("Day", selection: $weekday) { ForEach(weekdays, id: \.self) { Text($0.capitalized).tag($0) } }
                    TextField("Time (24-hour HH:mm)", text: $localTime)
                    Picker("Time zone", selection: $timeZone) { ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0).tag($0) } }
                    Text("Reset changes take effect after the current week. Existing usage is preserved.").font(.caption).foregroundStyle(.secondary)
                    Button("Save reset schedule") { run { _ = try await store.mutate("PUT", "/admin/settings", ["reset": ["weekday": weekday, "localTime": localTime, "timeZone": timeZone]], expectedRevision: openedRevision); openedRevision = store.state?.policyRevision; message = "Reset schedule saved." } }.disabled(busy)
                }
                Section("Parent connection") {
                    Text(store.connected ? "Connected to this Mac's Kids Quota service." : "Service not connected.").foregroundStyle(store.connected ? .green : .orange)
                    SecureField("Parent access token", text: $token)
                    Button("Connect and save in Keychain") { run { try await store.connect(token); token = ""; message = "Connected. The token is saved in your Keychain." } }.disabled(token.isEmpty || busy)
                    Text("An administrator can use the token created by the installer. The parent token is sent only over a verified connection to the system service.").font(.caption).foregroundStyle(.secondary)
                }
                if let message { Text(message).foregroundStyle(.secondary) }
            }.formStyle(.grouped).tabItem { Label("General", systemImage: "gearshape") }
            Form {
                Section("Mac apps") {
                    Text("Enable the network filter after installing a signed Kids Quota app in Applications.")
                    Button("Enable app network filter") { filter.enable() }.disabled(filter.working)
                    Text(filter.status).foregroundStyle(.secondary)
                    Label(store.state?.filterConnected == true ? "Filter is responding to the service" : "Service has no live filter connection", systemImage: store.state?.filterConnected == true ? "checkmark.circle" : "exclamationmark.circle").foregroundStyle(store.state?.filterConnected == true ? .green : .orange)
                    if let gaps = store.state?.unattributedFlows, gaps > 0 { Text("Some connections could not be attributed to a signed app. Review app coverage before relying on its limit.").font(.caption).foregroundStyle(.orange) }
                    Text("macOS will request administrator approval. The filter blocks the selected apps' network traffic after the allowance runs out. Offline content can remain available.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Browser setup") {
                    Text("Enable Kids Quota in Chrome and Safari for each child's login. Allow it on all websites so it can identify the active site and show the time-limit page.")
                    Button("Open Safari extension settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Safari.ExtensionsPreferences")!) }
                    Text("The developer Chrome extension can be removed by that login. For stronger enforcement, deploy the signed release through managed browser policies; see the repository's installation guide.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Verify coverage") {
                    Text("Sign in as each child, open a limited website and selected app, and check that time decreases. Set a short test allowance to verify new and already-open network connections stop at exhaustion.")
                }
            }.formStyle(.grouped).tabItem { Label("Protection", systemImage: "shield") }
            Form {
                Section("Create read-only client") {
                    Text("Give a widget or website publisher its own token. It can read only the selected children's balances and service names.").font(.callout)
                    TextField("Client name", text: $clientName)
                    ForEach(store.children) { child in Toggle(child.displayName, isOn: Binding(get: { childIDs.contains(child.id) }, set: { if $0 { childIDs.insert(child.id) } else { childIDs.remove(child.id) } })) }
                    Button("Create token") { run {
                        let data = try await store.raw("POST", "/admin/clients", body: ["name": clientName, "scopes": ["children:read", "services:read", "quotas:read", "balances:read"], "childIds": Array(childIDs).sorted()])
                        let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                        issuedToken = result?["token"] as? String; clientName = ""; await store.refresh()
                    } }.disabled(clientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || childIDs.isEmpty || busy)
                    if let issuedToken {
                        Text("Copy this token now. It is shown only once.").font(.callout.bold())
                        Text(issuedToken).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        HStack { Button("Copy token") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(issuedToken, forType: .string) }; Button("Done") { self.issuedToken = nil } }
                    }
                }
                Section("Connected clients") {
                    ForEach(store.state?.clients.filter { $0.administrator != true } ?? []) { client in HStack { VStack(alignment: .leading) { Text(client.name); Text(client.scopes.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Revoke", role: .destructive) { run { _ = try await store.raw("DELETE", "/admin/clients/\(client.id)"); await store.refresh() } }.disabled(busy) } }
                }
                if let message { Text(message).foregroundStyle(.secondary) }
            }.formStyle(.grouped).tabItem { Label("API clients", systemImage: "key") }
        }.padding(12)
        .onAppear { openedRevision = store.state?.policyRevision; if let reset = store.state?.policy.pendingReset?.schedule ?? store.state?.policy.reset { weekday = reset.weekday; localTime = reset.localTime; timeZone = reset.timeZone } }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true; message = nil
        Task { do { try await action() } catch { message = error.localizedDescription }; busy = false }
    }
}
