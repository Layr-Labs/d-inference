import Darwin
import Foundation

@main struct GemmaForwardSelectionCheck {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { Darwin.exit(64) }
        signal(SIGALRM) { _ in Darwin._exit(124) }; alarm(10)
        let inputs = try FixtureInputs(root: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
        let checks = FixtureChecks()
        try checkGemmaStagePlan(inputs, checks)
        try checkLayerStageRefusals(inputs, checks)
        try checkGemmaMetadataRefusals(inputs, checks)
        try checkQwenPreservation(inputs, checks)
        try checkGemmaForwardSelection(inputs, checks)
        let output: [String: Any] = ["scope": "Swift metadata and real loader selection only",
            "accepted": checks.accepted, "refused": checks.rejected,
            "acceptedCount": checks.accepted.count, "refusedCount": checks.rejected.count,
            "nativeModelConstructed": false, "payloadRead": false,
            "payloadVerificationEstablished": false, "runtimeExecutionAuthorized": false]
        let bytes = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        guard bytes.count <= 131_072 else { throw ProbeError("Fixture result exceeds output bound") }
        try FileHandle.standardOutput.write(contentsOf: bytes + Data([10]))
        alarm(0)
    }
}
