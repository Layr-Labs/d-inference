#if NATIVE_PAIR_HARDWARE_EXPERIMENT
import Foundation
import CryptoKit
import Network
import Darwin

// Actual TLS and WebSocket handshakes against tls_server.go. No booleans stand
// in for evaluation. Timeout is failure even for a negative certificate case.
final class TLSOutcome: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: String?
    private var detail: String = ""
    func finish(_ result: String, diagnostic: String = "") {
        lock.lock(); defer { lock.unlock() }
        if value == nil { value = result; detail = String(diagnostic.prefix(2048)); semaphore.signal() }
    }
    func result() -> String? { lock.lock(); defer { lock.unlock() }; return value }
    func diagnostic() -> String { lock.lock(); defer { lock.unlock() }; return detail }
}

@main struct PrivateClusterTLSCheck {
    static func require(_ b: Bool, _ message: String) throws { if !b { throw NSError(domain: message, code: 1) } }
    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func main() throws {
        alarm(35); defer { alarm(0) }
        guard CommandLine.arguments.count == 2 else { throw PrivateClusterTLSError.configuration }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
        let ports = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: root.appendingPathComponent("ready.json")))
        func config(_ name: String, _ mode: String, _ caName: String = "ca.der") throws -> (URL, [String: String]) {
            guard let port = ports[mode] else { throw PrivateClusterTLSError.configuration }
            let url = URL(string: "wss://localhost:\(port)/ws")!
            let derFile = root.appendingPathComponent(caName)
            let data = try JSONSerialization.data(withJSONObject: ["schema":"private_cluster_tls_anchor_v1", "host":"localhost", "port":port, "caDERFile":derFile.path, "caDERSHA256":sha(Data(contentsOf:derFile))],options:[.sortedKeys])
            let file=root.appendingPathComponent(name+".json")
            try data.write(to:file,options:.withoutOverwriting)
            return (url,["DARKBLOOM_PRIVATE_CLUSTER_TLS_CONFIG":file.path,"DARKBLOOM_PRIVATE_CLUSTER_TLS_SHA256":sha(data)])
        }
        func handshake(_ name: String, _ url: URL, _ anchor: PrivateClusterTLSAnchor?) throws -> String {
            let parameters = try anchor?.parameters(for:url) ?? NWParameters.tls
            let ws = NWProtocolWebSocket.Options(); ws.autoReplyPing=true
            parameters.defaultProtocolStack.applicationProtocols.insert(ws,at:0)
            let connection=NWConnection(to:.url(url),using:parameters)
            let result=TLSOutcome(),queue=DispatchQueue(label:"private.tls.fixture.client")
            connection.stateUpdateHandler={ state in
                switch state {
                case .ready:result.finish("ready")
                case .failed(let error),.waiting(let error):
                    let diagnostic: String
                    switch error {
                    case .tls(let status): diagnostic = "tls OSStatus=\(status) " + String(reflecting:error)
                    case .posix(let status): diagnostic = "posix errno=\(status.rawValue) " + String(reflecting:error)
                    case .dns(let status): diagnostic = "dns code=\(status) " + String(reflecting:error)
                    default: diagnostic = String(reflecting:error)
                    }
                    if case .tls = error { result.finish("tls-refused",diagnostic:diagnostic) } else { result.finish("other-failure",diagnostic:diagnostic) }
                default:break
                }
            }
            connection.start(queue:queue)
            let waited=result.semaphore.wait(timeout:.now()+4)
            connection.cancel()
            // Fence this serial queue before releasing the actual connection.
            queue.sync {}
            let diagnostic = try JSONSerialization.data(withJSONObject:["case":name,"url":url.absoluteString,"outcome":result.result() ?? "missing","waitCompleted":waited == .success,"networkError":result.diagnostic()],options:[.sortedKeys])
            try require(diagnostic.count <= 8192,"TLS diagnostic bound")
            try diagnostic.write(to:root.appendingPathComponent(name+"-network.json"),options:.withoutOverwriting)
            try require(waited == .success,"TLS fixture timed out")
            return result.result() ?? "missing"
        }
        var observations:[String:String]=[:]
        for (name,mode,ca,expected) in [("valid","valid","ca.der","ready"),("untrusted","valid","ca.der","tls-refused"),("wrong-anchor","valid","wrong-ca.der","tls-refused"),("wrong-host","wrong-host","ca.der","tls-refused"),("expired","expired","ca.der","tls-refused")] {
            let (url,env)=try config(name,mode,ca)
            let anchor=try PrivateClusterTLSAnchor.load(environment:name == "untrusted" ? [:] : env,endpoint:url.absoluteString,member:true)
            let result=try handshake(name,url,anchor);observations[name]=result
            try require(result == expected,"unexpected actual TLS outcome: "+name+":"+result)
        }
        let (good,env)=try config("wrong-url","valid")
        let anchor=try PrivateClusterTLSAnchor.load(environment:env,endpoint:good.absoluteString,member:true)!
        for wrong in [URL(string:"wss://127.0.0.1:\(good.port!)/ws")!,URL(string:"wss://localhost:\(good.port! == 65535 ? 65534 : good.port! + 1)/ws")!,URL(string:"ws://localhost:\(good.port!)/ws")!] {
            do { _=try PrivateClusterTLSAnchor.load(environment:env,endpoint:wrong.absoluteString,member:true);throw NSError(domain:"wrong URL admitted",code:1) }
            catch PrivateClusterTLSError.endpoint {}
            do { _=try anchor.parameters(for:wrong);throw NSError(domain:"reconnect URL admitted",code:1) }
            catch PrivateClusterTLSError.endpoint {}
        }
        observations["wrong-url"]="refused-before-connect"
        let result=try JSONSerialization.data(withJSONObject:["schema":"private_cluster_tls_actual_check_v1","cases":observations,"systemTrustChanged":false],options:[.sortedKeys])
        try result.write(to:root.appendingPathComponent("client-result.json"),options:.withoutOverwriting)
        print("PASS 6 actual TLS/URL controls")
    }
}
#endif
