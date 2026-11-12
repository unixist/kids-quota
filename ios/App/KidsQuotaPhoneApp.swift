import SwiftUI

@main struct KidsQuotaPhoneApp: App {
    @StateObject private var store = FamilyStore()
    @Environment(\.scenePhase) private var scenePhase
    @State private var incomingPairing: String?
    var body: some Scene {
        WindowGroup {
            FamilyDashboard(store: store, incomingPairing: $incomingPairing)
                .onOpenURL { url in if url.scheme == "kidsquota", url.host == "pair" { incomingPairing = url.absoluteString } }
                .task { await store.refresh() }
                .onChange(of: scenePhase) { _, value in if value == .active { Task { await store.refresh() } } }
        }
    }
}
