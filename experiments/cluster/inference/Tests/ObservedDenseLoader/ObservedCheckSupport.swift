import Foundation

struct QwenObservedFixtureInput: Decodable {
    let configuration: Data, manifest: Data
    let canonicalTensors: [QwenDenseCanonicalTensor]
}
struct QwenObservedFixtureInputs: Decodable {
    let nine: QwenObservedFixtureInput, twentySeven: QwenObservedFixtureInput
}
struct QwenObservedCheckResult: Encodable {
    let kind = "qwen_dense_observed_descriptor_check", schemaVersion = 1
    let accepted: [String], rejected: [String]
    let acceptedChecks: Int, rejectedChecks: Int
    let observationsAreSynthetic = true, metadataOnly = true, runtimeExecutionAuthorized = false
    let modelConstructed = false, modelPayloadRead = false, currentResourceAdmissionPerformed = false
    let syntheticCheckpointIOPerformed = true
    init(accepted: [String], rejected: [String]) {
        self.accepted = accepted; self.rejected = rejected
        self.acceptedChecks = accepted.count; self.rejectedChecks = rejected.count
    }
}
struct QwenObservedFixtureChecks {
    var accepted: [String] = [], rejected: [String] = []
    mutating func require(_ label: String, _ value: Bool) throws {
        guard value else { throw ProbeError("Observed fixture failed: " + label) }
        accepted.append(label)
    }
    mutating func reject(_ label: String, _ body: () throws -> Void) throws {
        do { try body() } catch { rejected.append(label); return }
        throw ProbeError("Observed fixture accepted invalid case: " + label)
    }
}

/// Synthetic constructor observations, not an actual model inventory.
func fixtureObserved(_ tensor: QwenDenseCanonicalTensor, parts: Int = 1,
    expectedShape: [Int]? = nil, packed: Bool? = nil) -> QwenDenseObservedSourceTensor {
    .init(canonical: tensor, sourcePartCount: parts,
        preparedExpectedShape: expectedShape ?? tensor.shape,
        constructorParameterIsPacked: packed ?? (tensor.sourceDType == "U32"))
}
func fixtureIdentity(_ profile: QwenRegisteredDenseModelProfile) -> QwenDenseObservedSourceIdentity {
    .init(aggregateSHA256: profile.artifactAggregateSHA256, configurationSHA256: profile.configurationSHA256,
        verifiedManifestSHA256: profile.manifestSHA256, retainedSourceCount: profile.canonicalTensors.count,
        bf16ConversionEnabled: profile.requiredBF16ConversionPolicy)
}
func fixtureProfile(_ input: QwenObservedFixtureInput, large: Bool) throws -> QwenRegisteredDenseModelProfile {
    try .admit(configuration: input.configuration, manifest: input.manifest,
        expectedArtifactAggregateSHA256: large
            ? "bbd0e0adcfe74e095073fefd0b9e116e4311d606ad9989cf81f8175e8ac18463"
            : "127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b",
        canonicalTensors: input.canonicalTensors)
}

/// Preserve every untouched Codable field when producing a coherent mutation.
func fixtureChanging<T: Codable>(_ input: T, _ change: (inout [String: Any]) -> Void) throws -> T {
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as! [String: Any]
    change(&object)
    return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
}
