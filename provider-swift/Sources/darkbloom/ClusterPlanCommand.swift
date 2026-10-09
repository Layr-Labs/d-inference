import Foundation
import ArgumentParser
import ProviderCore

extension Cluster {
    /// `darkbloom cluster plan`: which Mac leads and where the model is cut,
    /// from what each Mac detects.
    struct Plan: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "plan",
            abstract: "Choose which Mac leads and where the model is cut, from what each Mac detects. Writes a setup for each Mac; saves and starts nothing.",
            discussion: """
                Detects this Mac's memory and hardware, reads the model's layout from its own files, asks the \
                other Mac for its profile over the pinned SSH route the session itself uses (that Mac's \
                `darkbloom-cluster-plan device --json`; system counters only, no model), and places the model. \
                It prints what it detected and what it chose in plain words, and writes one setup per Mac. The \
                Mac that holds the first range leads, whichever Mac this is run on. Each Mac then approves its \
                own setup with `darkbloom cluster configure`, as before. Where this Mac cannot reach the other \
                one, pass the profile that Mac printed with --peer-profile.
                """)
        @Option(help: "Absolute path to the pair description JSON: the two members and their installations, with no rank and no plan.")
        var pair: String
        @Option(help: "Absolute path to the worker's capability record.")
        var capability: String
        @Option(name: .customLong("capability-sha256"), help: "Expected SHA-256 of the exact capability bytes.")
        var capabilitySHA256: String
        @Option(help: "This Mac's member ID in the pair description.")
        var member: String
        @Option(name: .customLong("peer-profile"), help: "Absolute path to the other Mac's device profile, as that Mac printed it. Without it the other Mac is asked over the pinned SSH route.")
        var peerProfile: String?
        @Option(help: "Absolute path of a speed measurement; may be repeated.")
        var speed: [String] = []
        @Option(name: .customLong("prompt-tokens"), help: "Prompt length of the request to optimise; default the model's largest.")
        var promptTokens: Int?
        @Option(name: .customLong("output-tokens"), help: "Output length of the request to optimise; default the model's largest.")
        var outputTokens: Int?
        @Flag(help: "Optimise each Mac's settled rate instead of its rested one. A settled rate measured alone understates what a Mac sustains inside a placement, so the default is rested.")
        var sustained = false
        @Option(help: "Absolute path of a directory to create for the two setups.")
        var output: String

        func validate() throws {
            for path in [pair, capability, output] + speed + [peerProfile].compactMap({ $0 }) {
                guard path.hasPrefix("/"), !path.contains("\0") else { throw ValidationError("Cluster plan inputs require absolute local paths.") }
            }
        }

        mutating func run() async throws {
            Darkbloom.ensureLogging()
            var inputs = ClusterPlacementFlow.Inputs(pairDescription: URL(fileURLWithPath: pair), capability: URL(fileURLWithPath: capability),
                capabilitySHA256: capabilitySHA256, localMemberID: member, peerProfile: peerProfile.map { URL(fileURLWithPath: $0) },
                output: URL(fileURLWithPath: output, isDirectory: true))
            inputs.speedMeasurements = speed.map { URL(fileURLWithPath: $0) }
            inputs.promptTokens = promptTokens; inputs.outputTokens = outputTokens
            inputs.regime = sustained ? .sustained : .rested
            let outcome = try ClusterPlacementFlow.run(inputs, deadline: DispatchTime.now().uptimeNanoseconds + 30_000_000_000)
            for line in outcome.lines { print(line) }
            if outcome.setup == nil { throw ExitCode(2) }
        }
    }
}
