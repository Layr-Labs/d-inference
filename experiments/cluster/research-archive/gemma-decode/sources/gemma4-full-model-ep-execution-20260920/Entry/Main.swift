import Darwin
import Foundation
@_spi(ClusterTesting) import DarkbloomClusterRuntime

@main struct Main {
    static func main() {
        do {
            let data = try GemmaExpertFullCorrectness.run(arguments: Array(CommandLine.arguments.dropFirst()))
            FileHandle.standardOutput.write(data + Data([10]))
        } catch {
            FileHandle.standardError.write(Data("gemma-expert-full-correctness: \(error)\n".utf8))
            exit(1)
        }
    }
}
