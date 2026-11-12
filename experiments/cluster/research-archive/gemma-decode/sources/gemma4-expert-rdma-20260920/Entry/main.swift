import Darwin
import Foundation
@_spi(ClusterTesting) import DarkbloomClusterRuntime

@main struct GemmaExpertRDMAMain {
    static func main() {
        signal(SIGALRM) { _ in Darwin._exit(124) }; alarm(300)
        do {
            let bytes = try GemmaExpertRDMACheck.run(arguments: Array(CommandLine.arguments.dropFirst()))
            guard bytes.count <= 2_097_152, let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                throw NSError(domain: "ExpertRDMA", code: 1)
            }
            try FileHandle.standardOutput.write(contentsOf: bytes + Data([10]))
            if value["nativeExecuted"] as? Bool == true, value["passed"] as? Bool != true {
                try FileHandle.standardError.write(contentsOf: Data("Expert RDMA numerical comparison differs; retain report\n".utf8))
                Darwin.exit(2)
            }
            alarm(0)
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data((String(describing: error).prefix(8192)+"\n").utf8))
            Darwin.exit(1)
        }
    }
}
