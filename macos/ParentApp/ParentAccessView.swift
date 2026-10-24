import SwiftUI
import AppKit

struct ParentAccessGate<Content: View>: View {
    @EnvironmentObject private var store: ParentStore
    @ViewBuilder var content: () -> Content
    var body: some View {
        Group {
            if store.isUnlocked { content() }
            else {
                VStack(spacing: 18) {
                    Image(systemName: "lock.shield").font(.system(size: 50)).foregroundStyle(.tint)
                    Text("Parent settings are locked").font(.title.bold())
                    Text(store.isAdministrator ? "Unlock with macOS administrator authorization to manage weekly limits." : "Sign in to a Mac administrator account to open parent settings.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                    if store.isAdministrator {
                        Button { Task { await store.unlock() } } label: {
                            HStack { if store.busy { ProgressView().controlSize(.small) }; Text(store.busy ? "Authorizing…" : "Unlock parent settings") }
                        }.buttonStyle(.borderedProminent).controlSize(.large).disabled(store.busy)
                    }
                    if let error = store.error { Text(error).foregroundStyle(.orange).multilineTextAlignment(.center).frame(maxWidth: 440) }
                    Text("Limits keep running while this window is locked or closed.").font(.caption).foregroundStyle(.secondary)
                }.padding(35).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct ParentWindowRoot: View {
    @EnvironmentObject private var store: ParentStore
    var body: some View {
        ParentAccessGate { HouseholdView() }
            .background(WindowCloseHandler { store.lock() }.frame(width: 0, height: 0))
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in store.lock() }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)) { _ in store.lock() }
    }
}

/// SwiftUI may retain a closed Window's view. Observe that specific NSWindow rather
/// than relying on onDisappear, and do not end the session when a sheet closes.
private struct WindowCloseHandler: NSViewRepresentable {
    var onClose: () -> Void
    func makeNSView(context: Context) -> CloseObservingView { CloseObservingView(onClose: onClose) }
    func updateNSView(_ nsView: CloseObservingView, context: Context) { nsView.onClose = onClose }
    final class CloseObservingView: NSView {
        var onClose: () -> Void
        private var observer: NSObjectProtocol?
        init(onClose: @escaping () -> Void) { self.onClose = onClose; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            if let window {
                observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onClose() }
                }
            }
        }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}
