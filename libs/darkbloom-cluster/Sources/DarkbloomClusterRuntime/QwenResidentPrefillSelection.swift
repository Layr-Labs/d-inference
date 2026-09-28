import DarkbloomClusterProtocol
import Foundation

/// Maps the public product choice into the already bounded native scheduler.
/// No environment lookup, diagnostic capture, or caller-supplied byte budget.
enum QwenResidentPrefillSelection {
    static func policy(_ schedule: ClusterPrefillSchedule) -> QwenResidentPrefillPolicy {
        switch schedule {
        case .serial: .serial
        case .oneChunkLookahead: .oneChunkLookahead
        }
    }

    static func loadAgreementFields(_ schedule: ClusterPrefillSchedule) -> [String] {
        // Existing serial load agreement bytes remain unchanged.
        schedule == .serial ? [] : ["qwen-resident-prefill-schedule-v1", schedule.rawValue]
    }

    static func allowance(_ policy: QwenResidentPrefillPolicy, rank: Int,
                          promptCount: Int, chunkSize: Int, hiddenSize: Int,
                          elementBytes: Int, bound: (Int) throws -> Int) throws -> QwenGenerationPrefillAllowance? {
        guard policy == .oneChunkLookahead else { return nil }
        return try .derive(rank: rank, promptCount: promptCount, chunkSize: chunkSize,
            hiddenSize: hiddenSize, elementBytes: elementBytes, bound: bound)
    }
}
