import Foundation

/// This value carries no array, pointer, receive allocation or transport state.
/// The supported receive entry is decode(_:expected:), which scans bounded raw
/// JSON before Codable can discard duplicate keys or accept fractional integers.
struct QwenLayerStageBoundaryWireHeader: Codable, Equatable {
    static let maximumEncodedBytes = 16 * 1024
    let version: Int
    let requestFingerprint: String
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

    /// Native sender adapters can pass the actual boundary fields here, then
    /// validate(expected:) before encoding. Do not replace actual metadata with
    /// the expected metadata to hide a producer discrepancy.
    init(requestFingerprint: String, sourceIdentity: QwenLayerStageWireSourceIdentity,
         frame: QwenLayerStageFrame, tokenIDsSHA256: String, payloadSHA256: String,
         shape: [Int], dtype: String, byteCount: Int) throws {
        self.version = 1; self.requestFingerprint = requestFingerprint
        self.sourceConfigurationSHA256 = sourceIdentity.sourceConfigurationSHA256
        self.artifactAggregateSHA256 = sourceIdentity.artifactAggregateSHA256
        self.storageCommitmentSHA256 = sourceIdentity.storageCommitmentSHA256
        self.planFingerprint = sourceIdentity.planFingerprint
        self.producerStageFingerprint = sourceIdentity.producerStageFingerprint
        self.frame = frame; self.tokenIDsSHA256 = tokenIDsSHA256; self.payloadSHA256 = payloadSHA256
        self.shape = shape; self.dtype = dtype; self.byteCount = byteCount
        try validateIntrinsic()
    }

    init(expected: QwenLayerStageBoundaryWireExpectation, payloadSHA256: String) throws {
        try self.init(requestFingerprint: expected.requestFingerprint, sourceIdentity: expected.sourceIdentity,
            frame: expected.frame, tokenIDsSHA256: expected.tokenIDsSHA256, payloadSHA256: payloadSHA256,
            shape: expected.shape, dtype: expected.dtype, byteCount: expected.byteCount)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, requestFingerprint, sourceConfigurationSHA256, artifactAggregateSHA256
        case storageCommitmentSHA256, planFingerprint, producerStageFingerprint, frame
        case tokenIDsSHA256, payloadSHA256, shape, dtype, byteCount
    }
    private enum DecodePermit: Equatable { case boundedStrictJSON }
    private static let permitKey = CodingUserInfoKey(rawValue: "qwen-layer-stage-bounded-header-v1")!
    private static let frameFields: Set<String> = [
        "sequence", "phase", "tokenOffset", "tokenCount", "finalPromptChunk",
    ]

    init(from decoder: Decoder) throws {
        guard decoder.userInfo[Self.permitKey] as? DecodePermit == .boundedStrictJSON else {
            throw ProbeError("Stage wire JSON must enter through bounded strict decode(_:expected:)")
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        requestFingerprint = try values.decode(String.self, forKey: .requestFingerprint)
        sourceConfigurationSHA256 = try values.decode(String.self, forKey: .sourceConfigurationSHA256)
        artifactAggregateSHA256 = try values.decode(String.self, forKey: .artifactAggregateSHA256)
        storageCommitmentSHA256 = try values.decode(String.self, forKey: .storageCommitmentSHA256)
        planFingerprint = try values.decode(String.self, forKey: .planFingerprint)
        producerStageFingerprint = try values.decode(String.self, forKey: .producerStageFingerprint)
        frame = try values.decode(QwenLayerStageFrame.self, forKey: .frame)
        tokenIDsSHA256 = try values.decode(String.self, forKey: .tokenIDsSHA256)
        payloadSHA256 = try values.decode(String.self, forKey: .payloadSHA256)
        shape = try values.decode([Int].self, forKey: .shape)
        dtype = try values.decode(String.self, forKey: .dtype)
        byteCount = try values.decode(Int.self, forKey: .byteCount)
        try validateIntrinsic()
    }

    static func decode(_ data: Data, expected: QwenLayerStageBoundaryWireExpectation) throws -> Self {
        guard !data.isEmpty, data.count <= maximumEncodedBytes else {
            throw ProbeError("Stage wire header is empty or exceeds 16 KiB")
        }
        try validateWorkerJSON(data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(CodingKeys.allCases.map(\.stringValue)),
              let frame = object["frame"] as? [String: Any], Set(frame.keys) == frameFields,
              ["version", "byteCount"].allSatisfy({ BoundedProbeInput.integer(object[$0]) != nil }),
              ["sequence", "tokenOffset", "tokenCount"].allSatisfy({ BoundedProbeInput.integer(frame[$0]) != nil }),
              let shape = object["shape"] as? [Any], shape.count == 3,
              shape.allSatisfy({ BoundedProbeInput.integer($0) != nil }) else {
            throw ProbeError("Stage wire header/frame fields must be exact and dimensions/counts must be integer JSON values")
        }
        let decoder = JSONDecoder()
        decoder.userInfo[permitKey] = DecodePermit.boundedStrictJSON
        let header = try decoder.decode(Self.self, from: data)
        try header.validate(expected: expected)
        return header
    }

    func encoded() throws -> Data {
        try validateIntrinsic()
        let data = try canonicalJSONData(self)
        guard data.count <= Self.maximumEncodedBytes else { throw ProbeError("Encoded stage wire header exceeds its bound") }
        return data
    }

    func validate(expected: QwenLayerStageBoundaryWireExpectation) throws {
        try validateIntrinsic()
        let source = expected.sourceIdentity
        guard requestFingerprint == expected.requestFingerprint,
              sourceConfigurationSHA256 == source.sourceConfigurationSHA256,
              artifactAggregateSHA256 == source.artifactAggregateSHA256,
              storageCommitmentSHA256 == source.storageCommitmentSHA256,
              planFingerprint == source.planFingerprint,
              producerStageFingerprint == source.producerStageFingerprint,
              frame == expected.frame, tokenIDsSHA256 == expected.tokenIDsSHA256,
              shape == expected.shape, dtype == expected.dtype, byteCount == expected.byteCount else {
            throw ProbeError("Stage wire header differs from local request/source/frame/token/layout expectations")
        }
    }

    /// Optional CPU payload check. A native adapter can instead reconstruct the
    /// existing boundary and invoke its actual owned-array/hash validation.
    func validatePayload(_ payload: Data) throws {
        guard payload.count == byteCount, sha256(payload) == payloadSHA256 else {
            throw ProbeError("Stage wire payload length or logical-byte digest differs")
        }
    }

    private func validateIntrinsic() throws {
        guard version == 1,
              [requestFingerprint, sourceConfigurationSHA256, artifactAggregateSHA256,
               storageCommitmentSHA256, planFingerprint, producerStageFingerprint,
               tokenIDsSHA256, payloadSHA256].allSatisfy(qwenStageWireIsSHA256),
              (0..<132).contains(frame.sequence), (0..<132).contains(frame.tokenOffset),
              (1...32).contains(frame.tokenCount), shape.count == 3,
              shape[0] == 1, shape[1] == frame.tokenCount, (1...8192).contains(shape[2]) else {
            throw ProbeError("Stage wire version, hashes, frame or native batch-one geometry is invalid")
        }
        if frame.phase == .decode, frame.tokenCount != 1 || frame.finalPromptChunk {
            throw ProbeError("Stage wire decode frame must consume one token without a prompt-final flag")
        }
        let elementBytes = try qwenStageWireElementBytes(dtype)
        guard byteCount == shape[1] * shape[2] * elementBytes else {
            throw ProbeError("Stage wire logical payload length differs from its bounded native layout")
        }
    }
}
