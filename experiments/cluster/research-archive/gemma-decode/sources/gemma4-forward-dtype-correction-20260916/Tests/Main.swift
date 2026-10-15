import Darwin
import Foundation

@main struct GemmaShortResourceCheck {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { Darwin.exit(64) }
        signal(SIGALRM) { _ in Darwin._exit(124) }; alarm(10)
        let inputs = try FixtureInputs(root: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
        let checks = FixtureChecks()
        try checkGemmaStagePlan(inputs, checks)
        try checkLayerStageRefusals(inputs, checks)
        try checkGemmaMetadataRefusals(inputs, checks)
        try checkQwenPreservation(inputs, checks)
        try checkGemmaForwardDTypes(inputs, checks)
        try checkGemmaForwardSelection(inputs, checks)
        try checkShortBudget(inputs, checks, ledgerURL: URL(fileURLWithPath: CommandLine.arguments[2]))
        try checkOrderedLoad(inputs, checks)
        let result: [String: Any] = ["accepted": checks.accepted, "refused": checks.rejected,
            "acceptedCount": checks.accepted.count, "refusedCount": checks.rejected.count,
            "modelConstructed": false, "payloadRead": false, "actualAllocatorBoundsObserved": false,
            "runtimeExecutionAuthorized": false, "wholeProcessPeakBoundEstablished": false]
        let bytes = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        guard bytes.count <= 131072 else { throw ProbeError("Fixture output exceeds bound") }
        try FileHandle.standardOutput.write(contentsOf: bytes + Data([10])); alarm(0)
    }
}
