import Foundation
import Security

protocol ParentAuthorizationSession: Sendable {
    var externalForm: String { get }
    func invalidate()
}

/// The GUI remains an ordinary user process. The external form lets the root
/// daemon independently verify the right acquired by the system authorization UI.
final class ParentAuthorization: ParentAuthorizationSession, @unchecked Sendable {
    let externalForm: String
    private let lock = NSLock()
    private var reference: AuthorizationRef?

    private init(reference: AuthorizationRef, externalForm: String) {
        self.reference = reference; self.externalForm = externalForm
    }
    static func request() throws -> ParentAuthorization {
        var reference: AuthorizationRef?
        let created = AuthorizationCreate(nil, nil, [], &reference)
        guard created == errAuthorizationSuccess, let reference else { throw failure(created) }
        var handedOff = false
        defer { if !handedOff { AuthorizationFree(reference, .destroyRights) } }
        let result = "system.privilege.admin".withCString { rightName in
            var item = AuthorizationItem(name: rightName, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { itemPointer in
                var rights = AuthorizationRights(count: 1, items: itemPointer)
                // Obtain the right now. Preauthorization alone is not an unlock.
                return AuthorizationCopyRights(reference, &rights, nil, [.interactionAllowed, .extendRights], nil)
            }
        }
        guard result == errAuthorizationSuccess else { throw failure(result) }
        var external = AuthorizationExternalForm()
        let exported = AuthorizationMakeExternalForm(reference, &external)
        guard exported == errAuthorizationSuccess else { throw failure(exported) }
        let encoded = withUnsafeBytes(of: &external) { Data($0).base64EncodedString() }
        handedOff = true
        return ParentAuthorization(reference: reference, externalForm: encoded)
    }
    func invalidate() {
        lock.lock(); let old = reference; reference = nil; lock.unlock()
        if let old { AuthorizationFree(old, .destroyRights) }
    }
    deinit { invalidate() }
    private static func failure(_ status: OSStatus) -> ParentError {
        status == errAuthorizationCanceled ? .message("Unlock canceled.") : .message("macOS did not authorize administrator access. Try unlocking again.")
    }
}
