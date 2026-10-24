import Foundation
import Security

/// A bearer credential alone must never authorize parental controls. The native
/// server supplies the authenticated peer UID; Authorization Services validates
/// the right obtained by the parent UI. No prompts are allowed in the daemon.
public enum ParentAuthorization {
    public static func validate(uid: UInt32, externalForm: String) -> Bool {
        guard NativeIdentity.isAdministrator(uid: uid),
              externalForm.utf8.count <= 64,
              let bytes = Data(base64Encoded: externalForm),
              bytes.count == MemoryLayout<AuthorizationExternalForm>.size else { return false }
        var form = AuthorizationExternalForm()
        withUnsafeMutableBytes(of: &form) { $0.copyBytes(from: bytes) }
        var reference: AuthorizationRef?
        guard AuthorizationCreateFromExternalForm(&form, &reference) == errAuthorizationSuccess,
              let reference else { return false }
        defer { AuthorizationFree(reference, []) }
        return "system.privilege.admin".withCString { name in
            var right = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &right) { item in
                var rights = AuthorizationRights(count: 1, items: item)
                // Check the existing grant, without interaction or extending rights.
                return AuthorizationCopyRights(reference, &rights, nil, [], nil) == errAuthorizationSuccess
            }
        }
    }
}
