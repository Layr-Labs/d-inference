import Darwin
import Foundation

// Calls the exact phase host-budget code; no MLX import, model, or GPU.
@main struct PhaseBudgetMetadata {
    static func main() throws {
        guard CommandLine.arguments.count == 1, getpagesize() == 16384 else {
            throw ProbeError("Expected the fixed Apple Silicon page geometry")
        }
        let budget = try QwenGenerationPhaseBudget.derive(promptCount: 8192, chunkSize: 256,
            hostAllocationBound: QwenGenerationPhaseHostAllocation.bound)
        let data = try JSONEncoder().encode(budget)
        FileHandle.standardOutput.write(data + Data([10]))
    }
}
