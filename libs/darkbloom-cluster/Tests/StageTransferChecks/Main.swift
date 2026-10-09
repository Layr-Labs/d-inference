import Darwin
import Foundation

@main enum StageTransferCheck {
    static func main() {
        do {
            guard CommandLine.arguments.count == 2 else {
                throw ProbeError("usage: check /ABS/qwen-retained-inputs.json")
            }
            let inputs = try RetainedQwenInputs(file: URL(fileURLWithPath: CommandLine.arguments[1]))
            let checks = StageTransferChecks()
            try checkContentInventoryCodec(inputs, checks)
            try checkTransferPlan(inputs, checks)
            let artifact = try TinyStageArtifact()
            defer { artifact.remove() }
            try checkTransferControl(artifact, checks)
            try checkTransferMachines(artifact, checks)
            guard checks.failures.isEmpty else {
                for failure in checks.failures { fputs("FAIL: \(failure)\n", stderr) }
                exit(1)
            }
            let output: [String: Any] = ["passed": true, "accepted": checks.accepted, "refused": checks.refused,
                "acceptedCount": checks.accepted.count, "refusedCount": checks.refused.count,
                "modelExecution": false, "mlxUsed": false, "networkUsed": false]
            let bytes = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
            try FileHandle.standardOutput.write(contentsOf: bytes + Data([10]))
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
}
