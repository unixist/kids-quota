import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct FormFooter: View {
    let busy: Bool; let title: String; let cancel: () -> Void; let save: () -> Void
    var body: some View { HStack { Spacer(); Button("Cancel", action: cancel).keyboardShortcut(.cancelAction); Button(title, action: save).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(busy) }.padding(.top, 12) }
}
struct AddChildView: View {
    @EnvironmentObject var store: ParentStore
    @Environment(\.dismiss) var dismiss
    @State private var accounts: [LocalAccount] = []
    @State private var accountID = ""
    @State private var name = ""
    @State private var error: String?
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add a child").font(.title2.bold())
            Text("Link a standard macOS login account. The child keeps a separate allowance when switching accounts.").foregroundStyle(.secondary)
            Picker("Mac login", selection: $accountID) { Text("Choose account").tag(""); ForEach(accounts) { account in Text("\(account.displayName) (\(account.name))").tag(account.id) } }
            if accounts.isEmpty { Text("No standard accounts found. Add one in System Settings → Users & Groups.").font(.callout) }
            TextField("Child's name", text: $name)
            if let error { Text(error).foregroundStyle(.red) }
            FormFooter(busy: busy || accountID.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title: "Add child", cancel: { dismiss() }, save: save)
        }.padding(25).frame(width: 480)
        .task { do { accounts = try AccountDiscovery.children() } catch { self.error = error.localizedDescription } }
        .onChange(of: accountID) { _, id in if let account = accounts.first(where: { $0.id == id }) { name = account.displayName } }
    }
    private func save() {
        guard let account = accounts.first(where: { $0.id == accountID }) else { return }
        busy = true
        Task { do { let response = try await store.mutate("POST", "/admin/children", ["displayName": name, "generatedUid": account.generatedUID, "uid": account.uid]); if let child = response["child"] as? [String: Any], let id = child["id"] as? String { store.selectedChild = id }; dismiss() } catch { self.error = error.localizedDescription; busy = false } }
    }
}
struct EditHoursView: View {
    @EnvironmentObject var store: ParentStore; @Environment(\.dismiss) var dismiss
    let quota: QuotaItem
    @State private var hours: Double
    @State private var openedRevision: Int?
    @State private var error: String?; @State private var busy = false
    init(quota: QuotaItem) { self.quota = quota; _hours = State(initialValue: Double(quota.weeklyLimitSeconds) / 3600) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Edit \(store.childName)'s weekly allowance").font(.title2.bold())
            HoursField(hours: $hours)
            Text("Time already used stays counted. Setting zero hours blocks access until the allowance is raised.").foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            FormFooter(busy: busy, title: "Save", cancel: { dismiss() }) {
                guard hours.isFinite, hours >= 0, hours <= 168 else { error = "Enter 0 to 168 hours."; return }; busy = true; Task { do { _ = try await store.mutate("PATCH", "/children/\(quota.childId)/quotas/\(quota.id)", ["weeklyLimitSeconds": Int(hours * 3600)], expectedRevision: openedRevision); dismiss() } catch { self.error = error.localizedDescription; busy = false } }
            }
        }.padding(25).frame(width: 480).onAppear { openedRevision = store.state?.policyRevision }
    }
}
struct HoursField: View {
    @Binding var hours: Double
    var body: some View { HStack { Text("Hours per week"); Spacer(); TextField("Hours", value: $hours, format: .number.precision(.fractionLength(0...2))).frame(width: 75); Stepper("", value: $hours, in: 0...168, step: 0.5).labelsHidden() } }
}
struct AddServiceView: View {
    @EnvironmentObject var store: ParentStore; @Environment(\.dismiss) var dismiss
    @State private var selection = ""
    @State private var name = ""; @State private var websites = ""; @State private var subdomains = true
    @State private var hours = 6.0; @State private var appURL: URL?
    @State private var error: String?; @State private var busy = false
    private var available: [ServiceItem] { store.services.filter { service in !store.quotas.contains { $0.serviceId == service.id } } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add a service for \(store.childName)").font(.title2.bold())
            Picker("Service", selection: $selection) { Text("Custom website").tag(""); ForEach(available) { Text($0.name).tag($0.id) } }
            if let service = available.first(where: { $0.id == selection }) {
                Text("Includes: " + service.domains.map(\.hostname).joined(separator: ", ")).foregroundStyle(.secondary)
                Text(service.applicationIds.isEmpty ? "Website only. Use Manage service after adding to include a Mac app." : "Includes the household's verified apps for this service.").font(.callout).foregroundStyle(.secondary)
            } else {
                TextField("Friendly name", text: $name)
                WebsiteFields(websites: $websites, subdomains: $subdomains)
                AppChoice(url: $appURL)
            }
            HoursField(hours: $hours)
            if let error { Text(error).foregroundStyle(.red) }
            FormFooter(busy: busy, title: "Add to \(store.childName)", cancel: { dismiss() }, save: save)
        }.padding(25).frame(width: 510)
        .onAppear { selection = available.first?.id ?? "" }
    }
    private func save() {
        guard hours.isFinite, hours >= 0, hours <= 168 else { error = "Enter 0 to 168 hours."; return }
        busy = true
        Task {
            do {
                var serviceID = selection
                if serviceID.isEmpty {
                    let domains = try parseWebsites(websites, includeSubdomains: subdomains)
                    var appIDs: [String] = []
                    if let url = appURL { appIDs = [try await registerApp(url, store: store)] }
                    let result = try await store.mutate("POST", "/services", ["name": name, "domains": domains, "applicationIds": appIDs])
                    guard let service = result["service"] as? [String: Any], let id = service["id"] as? String else { throw ParentError.message("The service response was incomplete.") }; serviceID = id
                }
                _ = try await store.mutate("POST", "/children/\(store.selectedChild)/quotas", ["serviceId": serviceID, "weeklyLimitSeconds": Int(hours * 3600)])
                dismiss()
            } catch { self.error = error.localizedDescription; busy = false }
        }
    }
}
struct ManageServiceView: View {
    @EnvironmentObject var store: ParentStore; @Environment(\.dismiss) var dismiss
    let service: ServiceItem
    @State private var openedRevision: Int?
    @State private var websites: String; @State private var subdomains: Bool
    @State private var subdomainsChanged = false
    @State private var appIDs: Set<String>; @State private var appURL: URL?
    @State private var error: String?; @State private var busy = false
    init(service: ServiceItem) { self.service = service; _websites = State(initialValue: service.domains.map(\.hostname).joined(separator: "\n")); _subdomains = State(initialValue: service.domains.allSatisfy(\.includeSubdomains)); _appIDs = State(initialValue: Set(service.applicationIds)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Manage \(service.name)").font(.title2.bold())
            Text("These included websites and apps are shared by: " + affectedNames).foregroundStyle(.secondary)
            WebsiteFields(websites: $websites, subdomains: $subdomains)
            if Set(service.domains.map(\.includeSubdomains)).count > 1 && !subdomainsChanged { Text("Existing subdomain settings are preserved until you change the checkbox.").font(.caption).foregroundStyle(.secondary) }
            ForEach(store.state?.policy.applicationBindings.filter { service.applicationIds.contains($0.id) } ?? []) { app in
                Toggle(app.displayName, isOn: Binding(get: { appIDs.contains(app.id) }, set: { if $0 { appIDs.insert(app.id) } else { appIDs.remove(app.id) } }))
            }
            AppChoice(url: $appURL)
            Text("The service verifies the selected app's signature. Shared browser launchers cannot be assigned to a single website.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            FormFooter(busy: busy, title: "Save for all listed children", cancel: { dismiss() }) {
                busy = true; Task { do {
                    var domains = try parseWebsites(websites, includeSubdomains: subdomains, allowEmpty: !appIDs.isEmpty || appURL != nil)
                    if !subdomainsChanged {
                        domains = domains.map { entry in
                            var preserved = entry
                            if let hostname = entry["hostname"] as? String, let original = service.domains.first(where: { $0.hostname == hostname }) { preserved["includeSubdomains"] = original.includeSubdomains }
                            return preserved
                        }
                    }
                    if let url = appURL {
                        let response = try await store.mutate("POST", "/admin/applications", ["path": url.path], expectedRevision: openedRevision)
                        guard let app = response["application"] as? [String: Any], let id = app["id"] as? String else { throw ParentError.message("The app could not be verified.") }
                        appIDs.insert(id); openedRevision = response["policyRevision"] as? Int
                    }
                    _ = try await store.mutate("PATCH", "/services/\(service.id)", ["domains": domains, "applicationIds": Array(appIDs).sorted()], expectedRevision: openedRevision); dismiss()
                } catch { self.error = error.localizedDescription; busy = false } }
            }
        }.padding(25).frame(width: 540).onAppear { openedRevision = store.state?.policyRevision }.onChange(of: subdomains) { _, _ in subdomainsChanged = true }
    }
    private var affectedNames: String {
        let ids = Set(store.state?.policy.quotas.filter { $0.serviceId == service.id }.map(\.childId) ?? [])
        return store.children.filter { ids.contains($0.id) }.map(\.displayName).joined(separator: ", ")
    }
}
struct WebsiteFields: View {
    @Binding var websites: String; @Binding var subdomains: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Websites · one address per line").font(.callout)
            TextEditor(text: $websites).font(.body).frame(height: 65).border(.quaternary)
            Toggle("Include subdomains", isOn: $subdomains)
            let hosts = websites.split(whereSeparator: { $0.isNewline || $0 == "," }).compactMap { Presentation.host(String($0)) }
            if !hosts.isEmpty { Text("Will include: " + hosts.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
struct AppChoice: View {
    @Binding var url: URL?
    var body: some View {
        HStack {
            Button(url == nil ? "Choose a Mac app…" : "Change app…") { let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]; panel.allowsMultipleSelection = false; panel.directoryURL = URL(fileURLWithPath: "/Applications"); if panel.runModal() == .OK { url = panel.url } }
            if let url { Text(url.deletingPathExtension().lastPathComponent); Button { self.url = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
            else { Text("Optional").foregroundStyle(.secondary) }
        }
    }
}
private func parseWebsites(_ text: String, includeSubdomains: Bool, allowEmpty: Bool = false) throws -> [[String: Any]] {
    let entries = text.split(whereSeparator: { $0.isNewline || $0 == "," })
    let hosts = entries.compactMap { Presentation.host(String($0)) }
    guard entries.count == hosts.count, allowEmpty || !hosts.isEmpty else { throw ParentError.message("Enter a valid website address on each line.") }
    return Array(Set(hosts)).sorted().map { ["hostname": $0, "includeSubdomains": includeSubdomains] }
}
@MainActor private func registerApp(_ url: URL, store: ParentStore) async throws -> String {
    let result = try await store.mutate("POST", "/admin/applications", ["path": url.path])
    guard let app = result["application"] as? [String: Any], let id = app["id"] as? String else { throw ParentError.message("The app could not be verified.") }; return id
}
