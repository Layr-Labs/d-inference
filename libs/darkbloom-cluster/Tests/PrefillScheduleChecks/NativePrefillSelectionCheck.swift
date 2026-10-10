import DarkbloomClusterProtocol
import Foundation

@main enum NativePrefillSelectionCheck {
    enum Failure: Error { case assertion(String) }
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure.assertion(message) }
    }
    static func refuse(_ body: () throws -> Void) throws {
        do { try body() } catch is Failure { throw Failure.assertion("Assertion failed inside refusal") }
        catch { return }
        throw Failure.assertion("Expected refusal")
    }
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw Failure.assertion("Expected retained legacy capability") }
        let legacyBytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let legacy = try ClusterRuntimeCapabilityCodec.decode(legacyBytes)
        try require(try DistributedInstalledPrefillSelection.workerArguments(capability: legacy, schedule: .serial).isEmpty,
                    "Old serial worker received an unsupported optional CLI flag")
        try refuse { _ = try DistributedInstalledPrefillSelection.workerArguments(capability: legacy, schedule: .oneChunkLookahead) }
        var advertisedObject = try JSONSerialization.jsonObject(with: legacyBytes) as! [String: Any]
        advertisedObject["supportedPrefillSchedules"] = ["serial_v1", "one_chunk_lookahead_v1"]
        var advertisedBytes = try JSONSerialization.data(withJSONObject: advertisedObject, options: [.sortedKeys, .withoutEscapingSlashes])
        advertisedBytes.append(10)
        let advertised = try ClusterRuntimeCapabilityCodec.decode(advertisedBytes)
        try require(try DistributedInstalledPrefillSelection.workerArguments(capability: advertised, schedule: .serial).isEmpty,
                    "New serial worker arguments changed unnecessarily")
        try require(try DistributedInstalledPrefillSelection.workerArguments(capability: advertised, schedule: .oneChunkLookahead)
            == ["--prefill-schedule", "one_chunk_lookahead_v1"], "Advertised lookahead flag missing")
        var allocatorCalls = 0
        let serial = try QwenResidentPrefillSelection.allowance(.serial, rank: 0,
            promptCount: 8192, chunkSize: 512, hiddenSize: 4096, elementBytes: 2,
            bound: { allocatorCalls += 1; return $0 })
        try require(serial == nil && allocatorCalls == 0, "Serial added a reservation")
        try require(QwenResidentPrefillSelection.policy(.serial) == .serial
            && QwenResidentPrefillSelection.policy(.oneChunkLookahead) == .oneChunkLookahead, "Product mapping differs")
        let oldFields = ["fixture-load-domain", "epoch", "source", "plan", "peers"]
        let serialFields = oldFields + QwenResidentPrefillSelection.loadAgreementFields(.serial)
        let left = oldFields + QwenResidentPrefillSelection.loadAgreementFields(.oneChunkLookahead)
        let right = oldFields + QwenResidentPrefillSelection.loadAgreementFields(.oneChunkLookahead)
        try require(serialFields == oldFields && left == right && serialFields != right,
                    "Pre-weight schedule binding lost serial bytes or peer disagreement")

        func allowance(rank: Int, prompt: Int = 8192,
                       bound: (Int) throws -> Int = { $0 + 4096 }) throws -> QwenGenerationPrefillAllowance {
            guard let value = try QwenResidentPrefillSelection.allowance(.oneChunkLookahead, rank: rank,
                promptCount: prompt, chunkSize: 512, hiddenSize: 4096, elementBytes: 2, bound: bound) else {
                throw Failure.assertion("Missing lookahead charge")
            }
            return value
        }
        let rank0 = try allowance(rank: 0), rank1 = try allowance(rank: 1)
        let boundaryBytes = 512 * 4096 * 2
        try require(rank0.extraNativeBytes == boundaryBytes + 4096
            && rank0.extraHostBytes == boundaryBytes + 65_536,
            "Producer must retain its rounded boundary plus independent host copy/bookkeeping")
        try require(rank1.extraNativeBytes == 0 && rank1.extraHostBytes == 65_536,
                    "Consumer unexpectedly prefetched or lost bookkeeping charge")
        for rank in 0...1 {
            let single = try allowance(rank: rank, prompt: 512)
            try require(single.extraNativeBytes == 0 && single.extraHostBytes == 65_536,
                        "A single chunk has no prepared-ahead boundary")
        }
        let base = 1_000_000, total = try base + rank0.reservedBytes
        try rank0.requireCapacity(baseBytes: base, ownerLimit: total, readinessLimit: total)
        try refuse { try rank0.requireCapacity(baseBytes: base, ownerLimit: total - 1, readinessLimit: total) }
        try refuse { try rank0.requireCapacity(baseBytes: base, ownerLimit: total, readinessLimit: total - 1) }
        try refuse { _ = try allowance(rank: 0, bound: { $0 - 1 }) }
        let huge = try allowance(rank: 0, bound: { _ in Int.max })
        try refuse { _ = try huge.reservedBytes }
        try refuse { try rank0.requireCapacity(baseBytes: Int.max, ownerLimit: Int.max, readinessLimit: Int.max) }

        // Actual pure window: at most one prepared future boundary, committed
        // frontier captured before prefetch, no decode accepted as prompt work.
        var window = try QwenGenerationPrefillWindow(promptCount: 6, chunkSize: 3)
        try window.beginPreparation(sequence: 0, nativeCommittedTokens: 0)
        try window.commitPreparation(sequence: 0, nativeCommittedTokens: 3)
        let first = try window.beginSend(sequence: 0, nativeCommittedTokens: 3)
        try window.completeSend(first)
        try window.beginPreparation(sequence: 1, nativeCommittedTokens: 3)
        try window.commitPreparation(sequence: 1, nativeCommittedTokens: 6)
        try window.consume(first)
        let second = try window.beginSend(sequence: 1, nativeCommittedTokens: 6)
        try window.completeSend(second); try window.consume(second)
        try require(window.complete && window.maximumPreparedBoundaries == 1 && window.preparedAheadFrames == 1,
                    "Prompt window did not drain its single prepared slot")
        try refuse { try window.beginPreparation(sequence: 2, nativeCommittedTokens: 6) }
        print("PASS prefill product mapping, bilateral binding material, rank charges, capacity edges and prompt-only frontier")
    }
}
