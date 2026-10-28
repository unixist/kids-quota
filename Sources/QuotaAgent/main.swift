import Foundation
import AppKit
import CoreGraphics
import CoreServices
import Security
import Darwin
import KidsQuotaService

/// Register discovery for this login without launching the administrator-only
/// parent UI. Registration never enables an extension or changes Safari settings.
private enum SafariDiscovery {
    static let agentPath = "/Library/Application Support/KidsQuota/bin/kids-quota-agent"
    static let appPath = "/Applications/Kids Quota.app"
    static let extensionPath = appPath + "/Contents/PlugIns/KidsQuotaSafari.appex"
    static let helperArgument = "--register-safari"

    static func installedAgent() -> Bool {
        guard getuid() >= 500, getuid() == geteuid() else { return false }
        var executable = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(getpid(), &executable, UInt32(executable.count)) > 0,
              String(cString: executable) == agentPath else { return false }
        return protectedPath(agentPath, below: "/Library/Application Support/KidsQuota")
    }
    private static func protectedPath(_ path: String, below root: String) -> Bool {
        var item = URL(fileURLWithPath: path)
        while item.path.hasPrefix(root + "/") || item.path == root {
            var info = stat()
            guard lstat(item.path, &info) == 0, info.st_uid == 0,
                  info.st_mode & 0o022 == 0, info.st_mode & S_IFMT != S_IFLNK else { return false }
            if item.path == root { return true }
            item.deleteLastPathComponent()
        }
        return false
    }
    static func start() {
        guard installedAgent() else { return }
        // Running Launch Services in a short-lived helper gives even an unresponsive
        // registration service a deadline. The collector starts reporting immediately.
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: agentPath)
            process.arguments = [helperArgument]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { child in
                if child.terminationStatus != 0 { fputs("Kids Quota could not register Safari for this login. Check browser setup.\n", stderr) }
            }
            do { try process.run() }
            catch { fputs("Kids Quota could not start Safari registration for this login.\n", stderr); return }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 6) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
    static func register() -> Int32 {
        guard installedAgent(),
              protectedPath(appPath + "/Contents/Info.plist", below: appPath),
              protectedPath(extensionPath + "/Contents/MacOS/KidsQuotaSafari", below: appPath),
              Bundle(path: appPath)?.bundleIdentifier == "com.kidsquota.app",
              Bundle(path: extensionPath)?.bundleIdentifier == "com.kidsquota.app.safari" else { return 1 }
        // Validate the embedded extension directly. The parent UI is not launched
        // during background Safari registration.
        var code: SecStaticCode?, requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: extensionPath) as CFURL, [], &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString("identifier \"com.kidsquota.app.safari\"" as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else { return 1 }
        // App registration is best effort: an error must not skip the explicit
        // per-login registration of the independently readable Safari extension.
        _ = LSRegisterURL(URL(fileURLWithPath: appPath) as CFURL, true)
        // exec preserves this helper's PID so the parent's deadline also covers
        // PlugInKit. -a only adds discovery; never use -e use or alter preferences.
        let arguments = ["/usr/bin/pluginkit", "-a", extensionPath].map { strdup($0) } + [nil]
        defer { arguments.forEach { if let value = $0 { free(value) } } }
        return arguments.withUnsafeBufferPointer { execv("/usr/bin/pluginkit", $0.baseAddress!) }
    }
}

/// Installed as a LaunchAgent, so NSWorkspace observes only this login session.
final class Collector {
    var awake=true,activeSession=true,inFlight=false
    let queue=DispatchQueue(label:"com.kidsquota.agent")
    #if DEBUG
    let socket=ProcessInfo.processInfo.environment["KIDS_QUOTA_SOCKET"] ?? "/var/run/kids-quota.sock"
    let development=ProcessInfo.processInfo.environment["KIDS_QUOTA_DEVELOPMENT"] == "1"
    #else
    let socket="/var/run/kids-quota.sock"
    let development=false
    #endif
    var observers:[NSObjectProtocol]=[]
    func start() {
        SafariDiscovery.start()
        let center=NSWorkspace.shared.notificationCenter
        for (name,action) in [(NSWorkspace.willSleepNotification,0),(NSWorkspace.didWakeNotification,1),(NSWorkspace.sessionDidResignActiveNotification,2),(NSWorkspace.sessionDidBecomeActiveNotification,3)] {
            observers.append(center.addObserver(forName:name,object:nil,queue:.main){[self] _ in
                switch action {case 0:awake=false;case 1:awake=true;case 2:activeSession=false;default:activeSession=true};report()
            })
        }
        for name in ["com.apple.screenIsLocked","com.apple.screenIsUnlocked"] {
            // Unauthenticated notifications are wake-up hints, never state authority.
            observers.append(DistributedNotificationCenter.default().addObserver(forName:NSNotification.Name(name),object:nil,queue:.main){[self] _ in report()})
        }
        observers.append(center.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main){[self] _ in report()})
        Timer.scheduledTimer(withTimeInterval:1,repeats:true){[self] _ in report()};report()
    }
    func report() {
        guard !inFlight else {return}
        inFlight=true
        let app=NSWorkspace.shared.frontmostApplication
        let session=CGSessionCopyCurrentDictionary() as? [String:Any]
        // This WindowServer lock-state field is not a documented stable key;
        // validate it on every supported macOS release (see validation.md).
        let locked=session?["CGSSessionScreenIsLocked"] as? Bool == true
        let onConsole=session?[kCGSessionOnConsoleKey as String] as? Bool == true
        let payload:[String:Any]=["op":"foreground","pid":app?.processIdentifier ?? 0,"bundleIdentifier":app?.bundleIdentifier ?? "","healthy":session != nil,"active":awake && !locked && activeSession && onConsole && NativeIdentity.consoleUID()==getuid()]
        queue.async {[self] in
            _ = try? SocketIO.request(payload,path:socket,development:development)
            DispatchQueue.main.async {[self] in inFlight=false}
        }
    }
}
if CommandLine.arguments == [CommandLine.arguments[0], SafariDiscovery.helperArgument] {
    exit(SafariDiscovery.register())
}
// A launchd Aqua agent starts on the process main thread; all AppKit/SwiftUI
// lifecycle work remains there while collection and socket reads run separately.
MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let collector = Collector()
    let childStatusMenu = ChildStatusMenu(socket: collector.socket, development: collector.development)
    let previewWindow: NSWindow?
    #if DEBUG
    if CommandLine.arguments.contains("--preview-child-status") {
        // Visual QA only: no Safari registration, foreground collection or service
        // connection is started in this explicit debug-only mode.
        previewWindow = childStatusMenu.previewWindow()
    } else {
        previewWindow = nil
        collector.start()
    }
    #else
    previewWindow = nil
    collector.start()
    #endif
    withExtendedLifetime((collector, childStatusMenu, previewWindow)) { application.run() }
}
