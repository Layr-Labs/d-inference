import Darwin
import Foundation
import DarkbloomClusterRuntime

@main struct Main {
    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count == 2, args[0] == "--metadata" else {
                throw Failure.arguments
            }
            let result = try Gemma4ExpertMetadataChecks.run(directory: args[1])
            FileHandle.standardOutput.write(result + Data([10]))
        } catch {
            FileHandle.standardError.write(Data("gemma-expert-model-check: \(error)\n".utf8))
            exit(1)
        }
    }
    enum Failure: Error { case arguments }
}
