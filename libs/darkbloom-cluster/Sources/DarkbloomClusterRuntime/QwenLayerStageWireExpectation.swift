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

/// Allocation geometry is derived exclusively from local admission. A decoded
/// header must agree with these values before any payload receive is posted.
struct QwenLayerStageBoundaryWireExpectation {
    let requestFingerprint: String
    let sourceIdentity: QwenLayerStageWireSourceIdentity
    let frame: QwenLayerStageFrame
    let tokenIDsSHA256: String
    let shape: [Int]
    let dtype: String
    let byteCount: Int

    init(request: QwenLayerStageRequestSpec, frame: QwenLayerStageFrame, tokenIDs: [Int],
         sourceIdentity: QwenLayerStageWireSourceIdentity, hiddenSize: Int,
         nativeDType: String) throws {
        try Self.requireFrame(frame, request: request)
        guard tokenIDs.count == frame.tokenCount,
              tokenIDs.allSatisfy({ $0 >= 0 && $0 <= Int(Int32.max) }),
              (1...8192).contains(hiddenSize) else {
            throw ProbeError("Stage wire expectation requires locally admitted token IDs and hidden width")
        }
        let elementBytes = try qwenStageWireElementBytes(nativeDType)
        self.requestFingerprint = request.fingerprint; self.sourceIdentity = sourceIdentity
        self.frame = frame
        // Exact convention of QwenLayerStageBoundary.tokenHash, without importing MLX.
        self.tokenIDsSHA256 = sha256(Data(tokenIDs.map(String.init).joined(separator: ",").utf8))
        self.shape = [1, frame.tokenCount, hiddenSize]; self.dtype = nativeDType
        self.byteCount = frame.tokenCount * hiddenSize * elementBytes
    }

    /// Reuse the existing pure schedule to prove that even the locally supplied
    /// expected frame is a complete frame of this bounded request. Admission does
    /// not advance a live request; its owner chooses the currently expected frame.
    private static func requireFrame(_ frame: QwenLayerStageFrame,
                                     request: QwenLayerStageRequestSpec) throws {
        var schedule = QwenLayerStageSchedule(request: request)
        for offset in stride(from: 0, to: request.promptCount, by: request.chunkSize) {
            let count = min(request.chunkSize, request.promptCount - offset)
            let expected = try schedule.admitPrefill(count: count, offset: offset,
                final: offset + count == request.promptCount)
            if expected == frame { return }
            try schedule.commit(expected)
        }
        for _ in 0..<(request.outputCount - 1) {
            let expected = try schedule.admitDecode(offset: schedule.committedTokens)
            if expected == frame { return }
            try schedule.commit(expected)
        }
        throw ProbeError("Stage wire expected frame does not belong to the agreed request schedule")
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
