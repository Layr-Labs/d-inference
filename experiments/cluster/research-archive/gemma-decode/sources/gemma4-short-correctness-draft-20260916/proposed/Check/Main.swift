import Darwin
import Foundation
@_spi(ClusterTesting) import DarkbloomClusterRuntime

@main struct GemmaShortCorrectnessMain {
    static func main() {
        do {
            let result = try GemmaShortCorrectnessCheck.run(arguments: Array(CommandLine.arguments.dropFirst()))
            guard result.count <= 1_048_576 else { throw NSError(domain: "GemmaCheck", code: 1) }
            try FileHandle.standardOutput.write(contentsOf: result + Data([10]))
        } catch {
            let message = Data((String(describing: error).prefix(8192) + "\n").utf8)
            try? FileHandle.standardError.write(contentsOf: message)
            Darwin.exit(1)
        }
    }
}
