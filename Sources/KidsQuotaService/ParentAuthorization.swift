import Foundation
import Security
import Darwin

/// The login owning the parent UI may be a standard account. Authorization
/// Services, not that login's group membership, authenticates an administrator.
public enum ParentAuthorization {
    public static let rightName = "com.kidsquota.manage"

    /// Called by the installed root daemon before it accepts connections, including
    /// installation's --init step. Development mode and unit tests never write the
    /// system authorization database. Replacing our own rule also repairs older
    /// definitions rather than trusting a pre-existing, potentially weaker rule.
    public static func registerAdministratorRight() throws {
        try registerAdministratorRight(uid: getuid()) { definition in
            var reference: AuthorizationRef?
            let created = AuthorizationCreate(nil, nil, [], &reference)
            guard created == errAuthorizationSuccess else { return created }
            guard let reference else { return errAuthorizationInternal }
            defer { AuthorizationFree(reference, []) }
            return rightName.withCString {
                AuthorizationRightSet(reference, $0, definition as CFDictionary,
                                      "Manage Kids Quota settings and allowances." as CFString, nil, nil)
            }
        }
    }

    // Keep OS database writes injectable so failure/privilege tests do not alter
    // the developer's Mac or require an administrator prompt.
    static func registerAdministratorRight(uid: UInt32, install: ([String: Any]) -> OSStatus) throws {
        guard uid == 0 else {
            throw TransportError.system("Installing the parent authorization right requires root.")
        }
        let definition: [String: Any] = [
            "class": "user", "group": "admin", "authenticate-user": true,
            // The child's session password must not satisfy this rule.
            "session-owner": false, "shared": false, "timeout": 300,
            "allow-root": true,
            "comment": "Authorize a parent to configure Kids Quota and reset allowances."
        ]
        let status = install(definition)
        guard status == errAuthorizationSuccess else {
            throw TransportError.system("Could not install parent authorization (\(status)).")
        }
    }

    public static func validate(uid: UInt32, externalForm: String) -> Bool {
        // uid is the verified IPC peer's login, not the administrator who unlocked
        // the UI. Never infer authorization or the authenticating parent's UID
        // from it. The imported OS reference carries the actual grant.
        guard externalForm.utf8.count <= 64,
              let bytes = Data(base64Encoded: externalForm),
              bytes.count == MemoryLayout<AuthorizationExternalForm>.size else { return false }
        var form = AuthorizationExternalForm()
        withUnsafeMutableBytes(of: &form) { $0.copyBytes(from: bytes) }
        var reference: AuthorizationRef?
        guard AuthorizationCreateFromExternalForm(&form, &reference) == errAuthorizationSuccess,
              let reference else { return false }
        defer { AuthorizationFree(reference, []) }
        return rightName.withCString { name in
            var right = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &right) { item in
                var rights = AuthorizationRights(count: 1, items: item)
                // Recheck the current grant and its expiry on every request. No
                // interaction or extension flags: this cannot prompt or acquire a
                // new grant using the daemon's root identity.
                return AuthorizationCopyRights(reference, &rights, nil, [], nil) == errAuthorizationSuccess
            }
        }
    }
}
