import Foundation
import NetworkExtension
import SystemExtensions

@MainActor final class FilterActivation: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    @Published var status = "App network filter has not been enabled from this app."
    @Published var working = false
    private let identifier = "com.kidsquota.app.networkfilter"
    func enable() {
        working = true; status = "Requesting macOS approval…"
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: identifier, queue: .main)
        request.delegate = self; OSSystemExtensionManager.shared.submitRequest(request)
    }
    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) { Task { @MainActor in status = "Approve Kids Quota in System Settings → General → Login Items & Extensions." } }
    nonisolated func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction { .replace }
    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) { Task { @MainActor in status = error.localizedDescription; working = false } }
    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            if result == .willCompleteAfterReboot { status = "Restart this Mac to finish enabling the extension."; working = false; return }
            do {
                let manager = NEFilterManager.shared()
                try await manager.loadFromPreferences()
                let configuration = manager.providerConfiguration ?? NEFilterProviderConfiguration()
                configuration.filterSockets = true; configuration.filterPackets = false
                configuration.filterDataProviderBundleIdentifier = identifier
                manager.providerConfiguration = configuration; manager.localizedDescription = "Kids Quota app limits"; manager.isEnabled = true
                try await manager.saveToPreferences()
                status = "Filter requested. Restart limited apps, then check live coverage on each child's account."; working = false
            } catch { status = error.localizedDescription; working = false }
        }
    }
}
