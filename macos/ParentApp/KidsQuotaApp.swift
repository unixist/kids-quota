import SwiftUI

@main struct KidsQuotaApp: App {
    @NSApplicationDelegateAdaptor(ParentAppLifecycle.self) private var lifecycle
    @StateObject private var store = ParentStore()
    var body: some Scene {
        Window("Kids Quota", id: "main") { ParentWindowRoot().environmentObject(store).frame(minWidth: 730, minHeight: 580).onAppear { lifecycle.store = store } }
        Settings { ParentAccessGate { SettingsView() }.environmentObject(store).frame(width: 650, height: 570).onAppear { lifecycle.store = store } }
    }
}

@MainActor final class ParentAppLifecycle: NSObject, NSApplicationDelegate {
    weak var store: ParentStore?
    private var sessionObserver: NSObjectProtocol?
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Observe independently of either window, including while the system
        // authorization prompt is open from the Settings scene.
        sessionObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.store?.lock() }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        store?.lock()
        if let sessionObserver { NSWorkspace.shared.notificationCenter.removeObserver(sessionObserver) }
        sessionObserver = nil
    }
    func applicationDidResignActive(_ notification: Notification) { store?.applicationDidResignActive() }
}
