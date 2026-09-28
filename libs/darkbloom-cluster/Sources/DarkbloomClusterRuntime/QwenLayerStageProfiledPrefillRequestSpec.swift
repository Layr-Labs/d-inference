import Foundation

/// A separate request namespace. There is no default profile and no conversion
/// that asks the legacy request decoder to admit larger values.
struct QwenLayerStageProfiledPrefillRequestSpec: Codable, Equatable {
    static let maximumEncodedBytes = 2048
    let profile: QwenLayerStagePrefillProfile
    let requestID: UUID
    let batchSize: Int
    let promptCount: Int
    let chunkSize: Int
    let outputCount: Int
    let prefillFrameCount: Int
    let maximumTokens: Int

    init(profile: QwenLayerStagePrefillProfile, requestID: UUID, batchSize: Int,
         promptCount: Int, chunkSize: Int, outputCount: Int) throws {
        let admitted = try profile.admit(batchSize: batchSize, promptCount: promptCount,
                                         chunkSize: chunkSize, outputCount: outputCount)
        self.profile = profile; self.requestID = requestID; self.batchSize = batchSize
        self.promptCount = promptCount; self.chunkSize = chunkSize; self.outputCount = outputCount
        self.prefillFrameCount = admitted.prefillFrameCount; self.maximumTokens = admitted.maximumTokens
    }

    var fingerprint: String {
        sha256(Data([
            "qwen-stage-profiled-prefill-request-v1", profile.rawValue, profile.fingerprint,
            requestID.uuidString.lowercased(), "batch=\(batchSize)", "prompt=\(promptCount)",
            "chunk=\(chunkSize)", "output=\(outputCount)",
        ].joined(separator: "\n").utf8))
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case profile, requestID, batchSize, promptCount, chunkSize, outputCount
    }
    private enum DecodePermit: Equatable { case boundedStrictJSON }
    private static let permitKey = CodingUserInfoKey(rawValue: "qwen-stage-profiled-prefill-request-v1")!

    init(from decoder: Decoder) throws {
        guard decoder.userInfo[Self.permitKey] as? DecodePermit == .boundedStrictJSON else {
            throw ProbeError("Profiled request JSON must use its bounded strict decode(_:) entry")
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(profile: values.decode(QwenLayerStagePrefillProfile.self, forKey: .profile),
            requestID: values.decode(UUID.self, forKey: .requestID),
            batchSize: values.decode(Int.self, forKey: .batchSize),
            promptCount: values.decode(Int.self, forKey: .promptCount),
            chunkSize: values.decode(Int.self, forKey: .chunkSize),
            outputCount: values.decode(Int.self, forKey: .outputCount))
    }

    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumEncodedBytes else {
            throw ProbeError("Profiled request JSON is empty or exceeds 2 KiB")
        }
        try validateWorkerJSON(data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(CodingKeys.allCases.map(\.stringValue)),
              ["batchSize", "promptCount", "chunkSize", "outputCount"].allSatisfy({
                  BoundedProbeInput.integer(object[$0]) != nil
              }) else { throw ProbeError("Profiled request needs exact fields and strict integer geometry") }
        let decoder = JSONDecoder()
        decoder.userInfo[permitKey] = DecodePermit.boundedStrictJSON
        return try decoder.decode(Self.self, from: data)
    }

    func encoded() throws -> Data {
        let data = try canonicalJSONData(self)
        guard data.count <= Self.maximumEncodedBytes else { throw ProbeError("Encoded profiled request exceeds 2 KiB") }
        return data
    }
}
