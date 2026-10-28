import DarkbloomClusterProtocol
import Foundation

public struct GPTOSSBatchSettings: Equatable, Sendable {
    public let lanes: Int
    public static let single = Self(lanes: 1)
    public static func fromEnvironment(_ values: [String: String], mode: ClusterGenerationMode) throws -> Self {
        let requested = try QwenBatchSettings.fromEnvironment(values)
        // Other modes retain their existing single-request owner. The caller
        // must use this same effective width for its admission/worker contract.
        return .init(lanes: mode == .pipeline ? requested.lanes : 1)
    }
    var fields: [String] { lanes == 1 ? [] : ["gptoss-batch-v1", "lanes=\(lanes)", "bf16-independent-history-v1", "affine8-m1-singleton-moe-rope-norm-v2", "prefill=original-grid-serial-v1"] }
    func binding(_ single: String) throws -> String {
        fields.isEmpty ? single : sha256(try canonicalJSONData([single] + fields))
    }
}
