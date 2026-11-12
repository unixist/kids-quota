import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PhoneDashboardSettingsView: View {
    @EnvironmentObject var store: ParentStore
    @State private var document = ""
    @State private var importing = false
    @State private var replacing = false
    @State private var busy = false
    @State private var message: String?
    private var status: PhoneDashboardStatus? { store.phoneStatus }
    private let guide = URL(string: "https://github.com/unixist/kids-quota/blob/main/docs/phone-dashboard.md")!

    var body: some View {
        Form {
            Section("See allowances on your iPhone") {
                Text("Share remaining time with your phone. This Mac sends updates every five minutes while awake, even when this app is closed. Phones cannot change limits or reset time.")
            }
            if store.phoneServiceUnavailable {
                Section("Mac service unavailable") {
                    Text("Kids Quota couldn't read this Mac's sharing status. Sharing may still be running. Reopen Kids Quota or restart this Mac if the problem continues.")
                    Button("Try again") { run { await store.refreshPhoneDashboard() } }.disabled(busy)
                }
            } else if let status {
                if status.configured || status.needsAttention {
                    Section(status.title) {
                        if let date = status.lastSuccessDate {
                            LabeledContent("Last sent") { Text(date, style: .relative) }
                        }
                        if status.uploading { Label("Sending latest balances…", systemImage: "arrow.triangle.2.circlepath") }
                        else if !status.needsAttention && status.lastSuccessDate == nil {
                            Text("Waiting for the first update to reach your dashboard.").foregroundStyle(.secondary)
                        }
                        if let error = status.lastError { Text(error).foregroundStyle(.orange) }
                        if !replacing, let recovery = status.recovery {
                            switch recovery {
                            case .retry:
                                Button("Try again") { run { try await store.publishPhoneDashboard() } }.disabled(busy || status.uploading)
                            case .reconnect:
                                Button("Reconnect") { replacing = true; message = nil }.disabled(busy)
                            case .checkSetup:
                                Link("Check setup", destination: guide)
                            }
                        }
                        if status.configured {
                            Button("Stop sharing", role: .destructive) { run {
                                try await store.disconnectPhoneDashboard()
                                replacing = false; document = ""
                                message = "Sharing stopped. Previously sent balances remain on your phone dashboard."
                            } }.disabled(busy)
                            DisclosureGroup("Connection details") {
                                LabeledContent("Mac", value: status.deviceName ?? "This Mac")
                                LabeledContent("Server", value: status.endpoint ?? "")
                                Button("Replace connection…") { replacing = true; message = nil }.disabled(busy)
                            }
                        }
                    }
                }
                if replacing || (!status.configured && !status.needsAttention) { connectionForm }
            } else { ProgressView("Reading this Mac's status…") }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
        .task(id: store.isUnlocked) {
            while store.isUnlocked && !Task.isCancelled {
                await store.refreshPhoneDashboard()
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: 16_385) ?? Data()
                guard data.count <= 16_384, let text = String(data: data, encoding: .utf8) else {
                    throw ParentError.message("Choose a valid Mac connection file.")
                }
                try load(text)
            } catch let error as CocoaError where error.code == .userCancelled { }
            catch { document = ""; message = "Could not read that connection file. Choose the Mac connection file from your phone setup." }
        }
        .onDisappear { document = ""; replacing = false; message = nil }
    }
    private var connectionForm: some View {
        Section(replacing ? "Reconnect this Mac" : "Connect this Mac") {
            Text("Choose this Mac's connection file from your phone setup.")
            if !document.isEmpty { Label("Connection file ready", systemImage: "checkmark.circle") }
            HStack {
                if document.isEmpty {
                    Button("Choose connection file…") { importing = true }.buttonStyle(.borderedProminent)
                } else {
                    Button("Connect and share balances") {
                        let submitted = document
                        run {
                            try await store.connectPhoneDashboard(submitted)
                            document = ""; replacing = false
                            // A saved connection is not yet a successful upload.
                            // Live status provides the result without a success banner.
                        }
                    }.buttonStyle(.borderedProminent)
                }
                Menu("Other options") {
                    if !document.isEmpty { Button("Choose another file…") { importing = true } }
                    Button("Paste connection") {
                        do { try load(NSPasteboard.general.string(forType: .string) ?? "") }
                        catch { document = ""; message = error.localizedDescription }
                    }
                    if replacing { Button("Cancel") { replacing = false; document = ""; message = nil } }
                }
            }.disabled(busy)
            Text("Only children's names, configured services, usage, and balances are shared. Browsing history is never included.").font(.caption).foregroundStyle(.secondary)
            Link("Phone setup guide", destination: guide)
        }
    }
    private func load(_ text: String) throws {
        _ = try PhoneConnectionDocument.body(text)
        document = text; message = nil
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; message = nil
        Task { do { try await action() } catch { message = error.localizedDescription }; busy = false }
    }
}
