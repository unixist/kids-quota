import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import QuotaKit

struct PairingView: View {
    @ObservedObject var store: FamilyStore
    let initialCode: String
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var error: String?
    @State private var connecting = false
    @State private var importer = false
    @State private var scanner = false
    @State private var manualEntry = false
    private var loadedConnection: PhoneConnection? { try? PhoneConnection.parse(code) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Connect your family", systemImage: "person.2.badge.key.fill").font(.title3.bold())
                    Text("Use the iPhone connection file or QR code created during parent setup. Each parent should use their own code.").foregroundStyle(.secondary)
                }
                Section {
                    Button("Scan QR code", systemImage: "qrcode.viewfinder") { scanner = true }
                    DisclosureGroup("Other ways") {
                        Button("Import connection file", systemImage: "doc.badge.plus") { importer = true }
                        PasteButton(payloadType: String.self) { strings in if let first = strings.first { code = first; error = nil } }
                        Button("Enter code manually") { manualEntry.toggle() }
                        if manualEntry {
                            TextEditor(text: $code).font(.system(.caption, design: .monospaced)).frame(minHeight: 100)
                                .autocorrectionDisabled().textInputAutocapitalization(.never).privacySensitive()
                                .accessibilityLabel("Private connection code")
                        }
                    }
                }.disabled(connecting)
                if let loadedConnection {
                    Section("Ready to connect") {
                        Label(loadedConnection.familyName, systemImage: "checkmark.circle").foregroundStyle(.green)
                        Text("Your private code is loaded. Tap Connect to confirm.").font(.subheadline)
                    }
                } else if !code.isEmpty {
                    Section { Text("This code couldn't be read. Scan the QR code or choose the iPhone connection file from parent setup.").foregroundStyle(.red) }
                }
                Section {
                    Text("Keep this code private. It gives read-only access to your family's quota summaries.").font(.caption).foregroundStyle(.secondary)
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    Button {
                        connecting = true; error = nil
                        let submitted = code
                        Task {
                            do { try await store.connect(submitted); code = ""; dismiss() }
                            catch is CancellationError {}
                            catch { self.error = (error as? QuotaDataError)?.errorDescription ?? DashboardIssue.reporting(error).message }
                            connecting = false
                        }
                    } label: { HStack { Text("Connect"); Spacer(); if connecting { ProgressView() } } }
                        .disabled(loadedConnection == nil || connecting)
                }
            }.navigationTitle("Connect").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Cancel") { store.cancelPairing(); dismiss() } }
                .onAppear { if code.isEmpty { code = initialCode } }
                .onDisappear { store.cancelPairing() }
                .fileImporter(isPresented: $importer, allowedContentTypes: [.json, .plainText], allowsMultipleSelection: false) { result in
                    do {
                        guard let url = try result.get().first else { return }
                        let granted = url.startAccessingSecurityScopedResource(); defer { if granted { url.stopAccessingSecurityScopedResource() } }
                        let values = try url.resourceValues(forKeys: [.fileSizeKey])
                        guard (values.fileSize ?? 0) <= 16_384 else { throw ImportFailure.tooLarge }
                        let data = try Data(contentsOf: url)
                        guard data.count <= 16_384, let text = String(data: data, encoding: .utf8) else { throw ImportFailure.tooLarge }
                        code = text; error = nil
                    } catch { self.error = (error as? ImportFailure)?.errorDescription ?? "Couldn't open that file. Choose the iPhone connection file from parent setup and try again." }
                }
                .sheet(isPresented: $scanner) {
                    QRScannerScreen { result in
                        scanner = false
                        switch result { case .success(let text): code = text; error = nil; case .failure(let problem): error = problem.localizedDescription }
                    }
                }
        }
    }
    enum ImportFailure: LocalizedError { case tooLarge; var errorDescription: String? { "Choose the small iPhone connection JSON file from your parent setup." } }
}

private struct QRScannerScreen: View {
    let completion: (Result<String, Error>) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var authorized = false
    @State private var denied = false
    var body: some View {
        NavigationStack {
            Group {
                if authorized { QRScanner(completion: completion).ignoresSafeArea(edges: .bottom).overlay(alignment: .bottom) { Text("Point the camera at your iPhone connection QR code.").padding().background(.regularMaterial, in: Capsule()).padding() } }
                else if denied { ContentUnavailableView("Camera access needed", systemImage: "camera", description: Text("Allow camera access in Settings, or import/paste your connection code instead.")) }
                else { ProgressView() }
            }.navigationTitle("Scan connection").navigationBarTitleDisplayMode(.inline).toolbar { Button("Cancel") { dismiss() } }
                .task { authorized = await AVCaptureDevice.requestAccess(for: .video); denied = !authorized }
        }
    }
}
private struct QRScanner: UIViewControllerRepresentable {
    let completion: (Result<String, Error>) -> Void
    func makeUIViewController(context: Context) -> ScannerController { ScannerController(completion: completion) }
    func updateUIViewController(_ controller: ScannerController, context: Context) {}
    static func dismantleUIViewController(_ controller: ScannerController, coordinator: ()) { controller.stop() }
}
private final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "kidsquota.qr-camera")
    private var preview: AVCaptureVideoPreviewLayer?
    private var delivered = false
    private let completion: (Result<String, Error>) -> Void
    init(completion: @escaping (Result<String, Error>) -> Void) { self.completion = completion; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        guard let camera = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else { finish(.failure(CameraFailure.unavailable)); return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { finish(.failure(CameraFailure.unavailable)); return }
        session.addOutput(output); output.setMetadataObjectsDelegate(self, queue: .main); output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session); preview.videoGravity = .resizeAspectFill; view.layer.addSublayer(preview); self.preview = preview
        queue.async { [session] in session.startRunning() }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    func stop() { queue.async { [session] in if session.isRunning { session.stopRunning() } } }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let value = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        finish(.success(value))
    }
    private func finish(_ result: Result<String, Error>) { guard !delivered else { return }; delivered = true; stop(); completion(result) }
    enum CameraFailure: LocalizedError { case unavailable; var errorDescription: String? { "Camera unavailable. Import or paste the connection code instead." } }
}
