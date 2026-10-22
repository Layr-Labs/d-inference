import Darwin
import Foundation

@main enum StageTransferCheck {
    static func main() {
        do {
            guard CommandLine.arguments.count == 4 else {
                throw ProbeError("usage: check /ABS/qwen-retained-inputs.json /ABS/registered-9b.configuration.json /ABS/SCRATCH")
            }
            let inputs = try RetainedQwenInputs(file: URL(fileURLWithPath: CommandLine.arguments[1]))
            let configuration = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
            let scratch = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
            let checks = StageTransferChecks()
            try checkContentInventoryCodec(inputs, checks)
            try checkTransferPlan(inputs, checks)
            // The artifact and its inventory stay in the scratch directory for the
            // runner's independent recomputation.
            let artifact = try TinyStageArtifact(directory: scratch.appendingPathComponent("tiny-artifact"))
            try artifact.inventory.encoded().write(to: scratch.appendingPathComponent("tiny-content-inventory.txt"),
                                                   options: .withoutOverwriting)
            try checkTransferControl(artifact, checks)
            try checkTransferMachines(artifact, checks)
            try checkRegisteredInventory(inputs, configuration: configuration, checks)
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
