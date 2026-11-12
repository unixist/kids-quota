import Foundation
import CoreFoundation
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
            // A standard session's credentials cannot satisfy this rule. Any
            // administrator account, including a tracked login, can authorize.
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
        // An absent custom right falls back to machine policy, which may reuse
        // shared session credentials even without extendRights. Only our installed,
        // nonshared administrator rule is an acceptable basis for a parent grant.
        var definition: CFDictionary?
        let found = rightName.withCString { AuthorizationRightGet($0, &definition) }
        guard found == errAuthorizationSuccess else { return false }
        return validateInstalledRule(definition as? [String: Any]) {
            var form = AuthorizationExternalForm()
            withUnsafeMutableBytes(of: &form) { $0.copyBytes(from: bytes) }
            var reference: AuthorizationRef?
            guard AuthorizationCreateFromExternalForm(&form, &reference) == errAuthorizationSuccess,
                  let reference else { return false }
            defer { AuthorizationFree(reference, []) }
            return hasCurrentGrant(reference)
        }
    }

    // Separate the policy gate from grant inspection so tests can prove a weak
    // rule never reaches an otherwise successful OS authorization check.
    static func validateInstalledRule(_ definition: [String: Any]?, checkGrant: () -> Bool) -> Bool {
        func boolean(_ value: Any?, equals expected: Bool) -> Bool {
            guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
            return value.boolValue == expected
        }
        guard let definition, definition["class"] as? String == "user",
              definition["group"] as? String == "admin",
              boolean(definition["authenticate-user"], equals: true),
              boolean(definition["session-owner"], equals: false),
              boolean(definition["shared"], equals: false),
              boolean(definition["allow-root"], equals: true),
              let timeout = definition["timeout"] as? NSNumber,
              CFGetTypeID(timeout) == CFNumberGetTypeID(),
              ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: timeout.objCType)),
              timeout.int64Value == 300 else { return false }
        // authd evaluates these optional entitlement shortcuts before requiring
        // user authentication. They are never part of our installed rule.
        for key in ["entitled", "entitled-group", "vpn-entitled-group"] {
            if let value = definition[key], !boolean(value, equals: false) { return false }
        }
        return checkGrant()
    }

    private static func hasCurrentGrant(_ reference: AuthorizationRef) -> Bool {
        return rightName.withCString { name in
            var right = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &right) { item in
                var rights = AuthorizationRights(count: 1, items: item)
                // Recheck the current grant and its expiry on every request. No
                // interaction or extension flags: validation cannot prompt. The
                // installed nonshared rule prevents a fallback to session grants.
                return AuthorizationCopyRights(reference, &rights, nil, [], nil) == errAuthorizationSuccess
            }
        }
    }
}
