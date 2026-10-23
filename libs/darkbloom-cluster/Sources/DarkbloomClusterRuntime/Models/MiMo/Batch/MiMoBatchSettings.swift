import DarkbloomClusterProtocol
import Foundation

/// Only plain text pipeline owners use independent-history batches. Every
/// other mode keeps its existing one-request stage and cache contracts.
public struct MiMoBatchSettings: Equatable, Sendable {
    public let lanes: Int
    public let usesPagedHistory: Bool
    public static func fromEnvironment(_ values: [String: String], mode: ClusterGenerationMode,
                                       images: Bool = false) throws -> Self {
        let requested = try QwenBatchSettings.fromEnvironment(values)
        return .init(lanes: mode == .pipeline && !images ? requested.lanes : 1,
            usesPagedHistory: mode == .pipeline && !images)
    }
    var fields: [String] { !usesPagedHistory ? [] : ["mimo-independent-history-v1", "lanes=\(lanes)",
        "bf16-independent-paged-history-v1", "cache-page-tokens=64", "affine8-broadcast-m1-v1",
        "singleton-rope-attention-mxfp4-finish-v1", "prefill=original-grid-serial-v1", "prefix=off"] }
    func binding(_ single: String) throws -> String {
        fields.isEmpty ? single : sha256(try canonicalJSONData([single] + fields))
    }
}

struct MiMoBatchReservation: IndependentHistoryBatchReservation {
    let request: QwenLayerStageGenerationRequest
    let allowance: MiMoResidentRequestAllowance
    let deadline: UInt64
    let pageBytes: Int
    let nativeBytes: Int
    let hostBytes: Int
    let laneStateBytes: Int

    init(request: QwenLayerStageGenerationRequest, allowance: MiMoResidentRequestAllowance,
         deadline: UInt64, pageBytes: Int) throws {
        guard pageBytes > 0, pageBytes == allowance.pagedBytes else { throw ProbeError("MiMo batch has no page allowance") }
        self.request = request; self.allowance = allowance; self.deadline = deadline; self.pageBytes = pageBytes
        nativeBytes = allowance.reservedBytes
        // Per-request prompt plus selected-token history; no token content is logged.
        hostBytes = try MiMoBatchMemory.historyBytes(maximumTokens: request.maximumTokens)
        laneStateBytes = try QwenLongPrefillCheckedBytes.sum([nativeBytes, hostBytes])
    }
}
