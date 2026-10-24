import Foundation
import AppKit
import CoreGraphics
import KidsQuotaService

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
let collector=Collector();collector.start();RunLoop.main.run()
