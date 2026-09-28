import Foundation

/// Inner header version 2 has a separate type/decoder. It cannot widen the
/// legacy v1 header. This Encodable-only type has no unguarded Codable decoder.
struct QwenLayerStageProfiledBoundaryWireHeader: Encodable, Equatable {
    static let maximumEncodedBytes = 16 * 1024
    let version = 2
    let profile: QwenLayerStagePrefillProfile
    let profileFingerprint: String
    let requestFingerprint: String
    let recordedRequestFingerprint: String
    let sourceConfigurationSHA256: String
    let artifactAggregateSHA256: String
    let storageCommitmentSHA256: String
    let planFingerprint: String
    let producerStageFingerprint: String
    let frame: QwenLayerStageFrame
    let tokenIDsSHA256: String
    let payloadSHA256: String
    let shape: [Int]
    let dtype: String
    let byteCount: Int

    /// A future native adapter must supply its actual boundary metadata, then
    /// validate against the separate expectation. Never hide a producer error
    /// by replacing its observed shape/hash/identity with expected values.
    init(profile: QwenLayerStagePrefillProfile, requestFingerprint: String,
         recordedRequestFingerprint: String, sourceIdentity: QwenLayerStageWireSourceIdentity,
         frame: QwenLayerStageFrame, tokenIDsSHA256: String, payloadSHA256: String,
         shape: [Int], dtype: String, byteCount: Int) throws {
        self.profile = profile; self.profileFingerprint = profile.fingerprint
        self.requestFingerprint = requestFingerprint; self.recordedRequestFingerprint = recordedRequestFingerprint
        self.sourceConfigurationSHA256 = sourceIdentity.sourceConfigurationSHA256
        self.artifactAggregateSHA256 = sourceIdentity.artifactAggregateSHA256
        self.storageCommitmentSHA256 = sourceIdentity.storageCommitmentSHA256
        self.planFingerprint = sourceIdentity.planFingerprint
        self.producerStageFingerprint = sourceIdentity.producerStageFingerprint
        self.frame = frame; self.tokenIDsSHA256 = tokenIDsSHA256; self.payloadSHA256 = payloadSHA256
        self.shape = shape; self.dtype = dtype; self.byteCount = byteCount
        try validateIntrinsic()
    }

    /// CPU fixture/local-expectation convenience; not a substitute for observing
    /// the actual producer metadata in a native integration.
    init(expected: QwenLayerStageProfiledBoundaryWireExpectation, payloadSHA256: String) throws {
        try self.init(profile: expected.profile, requestFingerprint: expected.requestFingerprint,
            recordedRequestFingerprint: expected.recordedRequestFingerprint, sourceIdentity: expected.sourceIdentity,
            frame: expected.frame, tokenIDsSHA256: expected.tokenIDsSHA256, payloadSHA256: payloadSHA256,
            shape: expected.shape, dtype: expected.dtype, byteCount: expected.byteCount)
    }

    static func decode(_ data: Data, expected: QwenLayerStageProfiledBoundaryWireExpectation) throws -> Self {
        let object = try QwenLayerStagePrefillWireJSON.object(data, maximumBytes: maximumEncodedBytes)
        guard let payloadHash = object["payloadSHA256"] as? String, qwenStageWireIsSHA256(payloadHash) else {
            throw ProbeError("Profiled inner header requires an actual canonical payload digest")
        }
        let admitted = try Self(expected: expected, payloadSHA256: payloadHash)
        // Raw scanner already rejected duplicate/escaped keys and fractional or
        // exponent syntax. Exact closed local content also rejects booleans in
        // integer positions, missing/unknown fields, and every frame alteration.
        try QwenLayerStagePrefillWireJSON.requireExact(object, expected: admitted)
        return admitted
    }

    func encoded() throws -> Data {
        try validateIntrinsic()
        let data = try canonicalJSONData(self)
        guard data.count <= Self.maximumEncodedBytes else { throw ProbeError("Profiled inner header exceeds 16 KiB") }
        return data
    }

    func validate(expected: QwenLayerStageProfiledBoundaryWireExpectation) throws {
        guard self == (try Self(expected: expected, payloadSHA256: payloadSHA256)) else {
            throw ProbeError("Actual profiled boundary differs from local source/profile/request/frame/token/layout")
        }
    }

    func validatePayload(_ payload: Data) throws {
        guard payload.count == byteCount, sha256(payload) == payloadSHA256 else {
            throw ProbeError("Profiled payload logical bytes differ from the admitted header")
        }
    }

    private func validateIntrinsic() throws {
        guard profileFingerprint == profile.fingerprint,
              [requestFingerprint, recordedRequestFingerprint, sourceConfigurationSHA256, artifactAggregateSHA256,
               storageCommitmentSHA256, planFingerprint, producerStageFingerprint,
               tokenIDsSHA256, payloadSHA256].allSatisfy(qwenStageWireIsSHA256),
              frame.phase == .prefill, (0..<profile.maximumPrefillFrames).contains(frame.sequence),
              (0..<profile.maximumPromptCount).contains(frame.tokenOffset),
              (1...profile.maximumChunkSize).contains(frame.tokenCount), shape.count == 3,
              shape[0] == 1, shape[1] == frame.tokenCount,
              (1...profile.maximumHiddenSize).contains(shape[2]) else {
            throw ProbeError("Invalid profiled inner header identity or native batch-one geometry")
        }
        let (end, endOverflow) = frame.tokenOffset.addingReportingOverflow(frame.tokenCount)
        let (elements, elementOverflow) = shape[1].multipliedReportingOverflow(by: shape[2])
        let (bytes, byteOverflow) = elements.multipliedReportingOverflow(by: try qwenStageWireElementBytes(dtype))
        guard !endOverflow, end <= profile.maximumPromptCount, !elementOverflow, !byteOverflow,
              byteCount == bytes, (1...QwenLayerStageProfiledBoundaryWireExpectation.maximumPayloadBytes).contains(bytes) else {
            throw ProbeError("Profiled inner header exceeds checked end/byte bounds")
        }
    }
}
