import Foundation
import KidsQuotaService

let env=ProcessInfo.processInfo.environment
#if DEBUG
let socket=env["KIDS_QUOTA_SOCKET"] ?? "/var/run/kids-quota.sock"
let development=env["KIDS_QUOTA_DEVELOPMENT"] == "1"
#else
let socket="/var/run/kids-quota.sock"
let development=false
#endif
do {
    while let bytes=try NativeFrame.read(from:.standardInput) {
        let reply:[String:Any]
        do {
            guard let payload=try JSONSerialization.jsonObject(with:bytes) as? [String:Any],payload["browser"] as? String == "chrome" else {throw TransportError.invalidRequest}
            reply=try SocketIO.request(["op":"browser","payload":payload],path:socket,development:development)
        } catch {reply=["error":"Kids Quota service is unavailable.","configured":false,"coverage":"incomplete"]}
        try FileHandle.standardOutput.write(contentsOf:NativeFrame.encode(JSONSerialization.data(withJSONObject:reply)))
    }
} catch {fputs("Kids Quota native messaging ended.\n",stderr);exit(1)}
