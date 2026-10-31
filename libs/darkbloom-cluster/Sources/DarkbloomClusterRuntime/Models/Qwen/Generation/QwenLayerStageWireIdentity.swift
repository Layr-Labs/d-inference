import Foundation

/// Values must come from the locally verified stage receipt and source plan,
/// never from the received header. Producer is the source plan's stage zero.
struct QwenLayerStageWireSourceIdentity: Equatable {
    let sourceConfigurationSHA256: String
    let artifactAggregateSHA256: String
    let storageCommitmentSHA256: String
    let planFingerprint: String
    let producerStageFingerprint: String

    init(sourceConfigurationSHA256: String, artifactAggregateSHA256: String,
         storageCommitmentSHA256: String, planFingerprint: String,
         producerStageFingerprint: String) throws {
        guard [sourceConfigurationSHA256, artifactAggregateSHA256, storageCommitmentSHA256,
               planFingerprint, producerStageFingerprint].allSatisfy(qwenStageWireIsSHA256) else {
            throw ProbeError("Stage wire source identity requires canonical SHA-256 values")
        }
        self.sourceConfigurationSHA256 = sourceConfigurationSHA256
        self.artifactAggregateSHA256 = artifactAggregateSHA256
        self.storageCommitmentSHA256 = storageCommitmentSHA256
        self.planFingerprint = planFingerprint; self.producerStageFingerprint = producerStageFingerprint
    }
}

func qwenStageWireIsSHA256(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
}

func qwenStageWireElementBytes(_ dtype: String) throws -> Int {
    switch dtype {
    case "float16", "bfloat16": return 2
    case "float32": return 4
    default: throw ProbeError("Stage wire dtype must equal an admitted native floating-point dtype")
    }
}
