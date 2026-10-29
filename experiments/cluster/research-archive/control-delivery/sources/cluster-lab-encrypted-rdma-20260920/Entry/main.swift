import Darwin
import Foundation
@_spi(ClusterTesting) import DarkbloomClusterRuntime

@main struct LabAuthenticatedRDMAMain {
    static func main() {
        signal(SIGALRM) { _ in Darwin._exit(124) }; alarm(120)
        do {
            let bytes = try LabAuthenticatedRDMABenchmark.run(arguments: Array(CommandLine.arguments.dropFirst()))
            guard bytes.count <= 1_048_576 else { throw NSError(domain: "LabRecordReport", code: 1) }
            try FileHandle.standardOutput.write(contentsOf: bytes + Data([10])); alarm(0)
        } catch {
            // A closed error avoids accidentally rendering any third-party
            // CryptoKit/native value containing private input bytes.
            try? FileHandle.standardError.write(contentsOf: Data("Lab authenticated RDMA component failed; retain owner receipts\n".utf8))
            Darwin.exit(1)
        }
    }
}
