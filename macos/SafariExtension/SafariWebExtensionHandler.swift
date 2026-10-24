import Foundation
import SafariServices

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        guard let item = context.inputItems.first as? NSExtensionItem,
              let message = item.userInfo?[SFExtensionMessageKey] as? [String: Any] else {
            context.cancelRequest(withError: NSError(domain: "KidsQuota", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing browser request."]))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let response: [String: Any]
            do { response = try DaemonSocket.request(["op": "browser", "payload": message]) }
            catch { response = ["type": "error", "error": "Kids Quota service is unavailable.", "requestSequence": message["sequence"] ?? 0] }
            let reply = NSExtensionItem(); reply.userInfo = [SFExtensionMessageKey: response]
            context.completeRequest(returningItems: [reply])
        }
    }
}
