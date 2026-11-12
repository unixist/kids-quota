import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PhoneDashboardSettingsView: View {
    @EnvironmentObject var store: ParentStore
    @State private var document = ""
    @State private var importing = false
    @State private var busy = false
    @State private var message: String?
    private var status: PhoneDashboardStatus? { store.state?.phoneDashboard }

    var body: some View {
        Form {
            Section("See allowances on your iPhone") {
                Text("Share this Mac's children's names, configured services, weekly usage, and time remaining with your private phone dashboard. Updates continue every five minutes while this Mac is awake, even when this app is closed.")
                Text("Your phone can view balances. Quota changes and resets still require administrator approval on this Mac.").font(.callout).foregroundStyle(.secondary)
                Link("Phone setup guide", destination: URL(string: "https://github.com/unixist/kids-quota/blob/main/docs/phone-dashboard.md")!)
            }
            if let status, status.configured {
                Section("Connected") {
                    LabeledContent("Mac", value: status.deviceName ?? "This Mac")
                    LabeledContent("Server", value: status.endpoint ?? "")
                    if status.uploading { Label("Sending latest balances…", systemImage: "arrow.triangle.2.circlepath") }
                    if let date = status.lastSuccessDate {
                        LabeledContent("Last sent") { Text(date, format: .dateTime.month().day().hour().minute()) }
                    } else { Text("Waiting for the first successful update.").foregroundStyle(.secondary) }
                    if let lastAttempt = status.lastAttempt, let date = ISO8601DateFormatter().date(from: lastAttempt) {
                        LabeledContent("Last attempt") { Text(date, format: .dateTime.month().day().hour().minute()) }
                    }
                    if let error = status.lastError { Text(error).font(.callout).foregroundStyle(.orange) }
                    HStack {
                        Button("Send update now") { run { try await store.publishPhoneDashboard(); message = "Update requested. Refresh status to see the result." } }
                        Button("Refresh status") { run { await store.refresh() } }
                        Button("Disconnect", role: .destructive) { run { try await store.disconnectPhoneDashboard(); message = "This Mac has stopped sharing. Previously sent balances remain on your private dashboard." } }
                    }.disabled(busy)
                }
            } else if let error = status?.lastError {
                Section("Connection status") { Text(error).foregroundStyle(.orange) }
            }
            Section(status?.configured == true ? "Replace connection" : "Connect this Mac") {
                Text("Import the Mac connection file from your dashboard setup, or paste its contents below. It contains a private device credential.").font(.callout)
                if !document.isEmpty { Label("Mac connection document loaded", systemImage: "checkmark.circle").foregroundStyle(.green) }
                HStack {
                    Button("Import connection file…") { importing = true }.disabled(busy)
                    Button("Paste connection document") {
                        do {
                            let text = NSPasteboard.general.string(forType: .string) ?? ""
                            _ = try PhoneConnectionDocument.body(text)
                            document = text; message = "Connection loaded. Choose Connect and share balances to enable sharing."
                        } catch { document = ""; message = error.localizedDescription }
                    }.disabled(busy)
                }
                HStack {
                    Button("Connect and share balances") {
                        let submitted = document
                        document = ""
                        run { try await store.connectPhoneDashboard(submitted); message = "Connected. The service will send the first update now." }
                    }.disabled(busy || document.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("No browsing history, account identifiers, app paths, or signing identities are shared. A sleeping or offline Mac keeps enforcing its local quotas when it resumes; phones show the last received update with its age.").font(.caption).foregroundStyle(.secondary)
            }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: 16_385) ?? Data()
                guard data.count <= 16_384, let text = String(data: data, encoding: .utf8) else {
                    throw ParentError.message("Choose a valid Mac connection JSON file.")
                }
                _ = try PhoneConnectionDocument.body(text)
                document = text; message = "Connection file loaded. Choose Connect and share balances to enable sharing."
            } catch { document = ""; message = "Could not import the Mac connection document. Check the file and try again." }
        }
        .onDisappear { document = "" }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true; message = nil
        Task { do { try await action() } catch { message = error.localizedDescription }; busy = false }
    }
}
