import SwiftUI

@main struct KidsQuotaApp: App {
    @StateObject private var store = ParentStore()
    var body: some Scene {
        WindowGroup("Kids Quota") { HouseholdView().environmentObject(store).frame(minWidth: 820, minHeight: 580) }
        Settings { SettingsView().environmentObject(store).frame(width: 650, height: 570) }
    }
}
