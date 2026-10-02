import Darwin
import Foundation
@_spi(ClusterTesting) import DarkbloomClusterRuntime

@main struct GemmaResidentBenchmarkMain {
    static func main() {
        do {
            let result = try GemmaResidentBenchmark.run(arguments: Array(CommandLine.arguments.dropFirst()))
            guard result.count <= 8_388_608 else { throw NSError(domain: "GemmaBenchmark", code: 1) }
            try FileHandle.standardOutput.write(contentsOf: result + Data([10]))
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data((String(describing: error).prefix(8192) + "\n").utf8))
            Darwin.exit(1)
        }
    }
}
