import Foundation
import Darwin
import KidsQuotaService

let args=CommandLine.arguments
func argument(_ name:String,_ fallback:String)->String {if let index=args.firstIndex(of:name),index+1<args.count{return args[index+1]};return fallback}
let development=args.contains("--development")
let localInstall=args.contains("--local-install")
let directory=URL(fileURLWithPath:argument("--data-dir","/Library/Application Support/KidsQuota"))
let socketPath=argument("--socket","/var/run/kids-quota.sock")
let port=Int(argument("--port","48123")) ?? 0
do {
    guard (1024...65535).contains(port) else {throw TransportError.system("Invalid port.")}
    guard !(development && localInstall) else {throw TransportError.system("Local installation cannot use development-mode authentication.")}
    let localTrust: LocalInstallTrust?
    if localInstall {
        guard getuid() == 0, !args.contains("--data-dir"), !args.contains("--socket"), !args.contains("--port") else {throw TransportError.system("Local installation requires root and the fixed installed data/socket locations.")}
        localTrust = try LocalInstallTrust.load()
        try localTrust?.validateService()
    } else {
        localTrust = nil
        guard development || (getuid()==0 && NativeIdentity.ownTeam() != nil) else {throw TransportError.system("Production service requires an administrator installation. Use --local-install for pinned local builds, or --development with explicit --data-dir / --socket paths for isolated testing.")}
    }
    guard !development || (args.contains("--data-dir") && args.contains("--socket")) else {throw TransportError.system("Development mode requires --data-dir and --socket.")}
    umask(0o077)
    let controller=try ServiceController(directory:directory,port:port)
    if args.contains("--init") {print("Initialized Kids Quota data directory. The parent token is saved to admin.token.");exit(0)}
    let servers=LocalServers(controller:controller,socketPath:socketPath,development:development,localTrust:localTrust)
    try servers.start()
    let timer=DispatchSource.makeTimerSource(queue:DispatchQueue.global(qos:.utility))
    timer.schedule(deadline:.now(),repeating:1)
    timer.setEventHandler {do {try controller.tick()} catch {fputs("Quota storage update failed; coverage is incomplete.\n",stderr)}}
    timer.resume()
    signal(SIGTERM,SIG_IGN);signal(SIGINT,SIG_IGN)
    let termination=DispatchSource.makeSignalSource(signal:SIGTERM,queue:.main)
    let interrupt=DispatchSource.makeSignalSource(signal:SIGINT,queue:.main)
    let stop:()->Void={timer.cancel();try? controller.stop();servers.stop();exit(0)}
    termination.setEventHandler(handler:stop);interrupt.setEventHandler(handler:stop);termination.resume();interrupt.resume()
    print("Kids Quota listening on http://127.0.0.1:\(port)/v1 (\(development ? "development" : localInstall ? "protected local installation; app network filter disabled" : "protected") mode).")
    dispatchMain()
} catch {fputs("Kids Quota: \(error)\n",stderr);exit(1)}
