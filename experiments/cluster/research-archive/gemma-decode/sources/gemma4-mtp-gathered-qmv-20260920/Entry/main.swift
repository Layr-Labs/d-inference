import Darwin
import Foundation
@_spi(ClusterTesting) import DarkbloomClusterRuntime

@main struct GemmaSmallGatherQMVMain {
    static func main() {
        signal(SIGALRM) { _ in Darwin._exit(124) }; alarm(300)
        do {
            let data = try GemmaSmallQMVCheck.run(arguments:Array(CommandLine.arguments.dropFirst()))
            guard data.count <= 1_048_576,
                  let result = try JSONSerialization.jsonObject(with:data) as? [String:Any],
                  let passed = result["passed"] as? Bool else { throw NSError(domain:"SmallQMV",code:1) }
            try FileHandle.standardOutput.write(contentsOf:data+Data([10]))
            if !passed { Darwin.exit(2) }
            alarm(0)
        } catch {
            try? FileHandle.standardError.write(contentsOf:Data((String(describing:error).prefix(8192)+"\n").utf8))
            Darwin.exit(1)
        }
    }
}
