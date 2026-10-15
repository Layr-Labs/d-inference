import Foundation

/// Prospective pure check; synthetic token IDs exercise parsing/admission only
/// and are never submitted to inference. Root supplies retained configuration.
func checkQwenLongPrefillReferenceAdmission(configuration: Data) throws -> (accepted: Int, rejected: Int) {
    let arithmetic = try QwenLongPrefillArithmeticEnvironment.admit(
        QwenLongPrefillArithmeticEnvironment.requiredValues)
    let request = try QwenLayerStageProfiledPrefillRequestSpec(profile: .longPrefill8KV1,
        requestID: UUID(uuidString: "00000000-0000-4000-8000-000000000007")!, batchSize: 1,
        promptCount: 8192, chunkSize: 512, outputCount: 1)
    let prompt = try canonicalJSONData((0..<8192).map { 3 + ($0 % 248_317) })
    let artifact = QwenRegistered9BLongPrefillAdmission.expectedArtifactAggregateSHA256
    func admit(config: Data? = nil, bytes: Data? = nil, pin: String? = nil,
               spec: QwenLayerStageProfiledPrefillRequestSpec? = nil, source: String? = nil,
               environment: QwenLongPrefillArithmeticEnvironment.Receipt? = nil)
        throws -> QwenRegistered9BLongPrefillReferenceAdmission {
        let data = bytes ?? prompt
        return try .init(configuration: config ?? configuration,
            expectedArtifactAggregateSHA256: source ?? artifact, promptData: data,
            expectedPromptSHA256: pin ?? sha256(data), request: spec ?? request,
            arithmetic: environment ?? arithmetic)
    }
    let actual = try admit()
    guard actual.request.steps.count == 16, actual.request.promptTokenIDs.count == 8192,
          actual.request.steps.last?.frame.tokenOffset == 7680,
          actual.request.steps.last?.committedTokens == 8192,
          actual.resource.budget.conservativeStateAndBoundaryBytes == 745_345_056,
          actual.arithmeticEnvironmentSHA256 == sha256(try canonicalJSONData(arithmetic)) else {
        throw ProbeError("Long reference pure admission failed its positive exact timeline")
    }
    var rejected = 0
    func reject(_ body: () throws -> Void) throws {
        do { try body() } catch { rejected += 1; return }
        throw ProbeError("Long reference pure admission accepted an invalid case")
    }
    try reject { _ = try admit(config: configuration + Data([0x20])) }
    try reject { _ = try admit(source: String(repeating: "0", count: 64)) }
    try reject { _ = try admit(pin: String(repeating: "0", count: 64)) }
    try reject { _ = try admit(pin: sha256(prompt).uppercased()) }
    try reject { _ = try admit(bytes: prompt + Data([0x20]), pin: sha256(prompt)) }
    try reject { _ = try admit(bytes: Data()) }
    try reject { _ = try admit(bytes: Data(repeating: 0x20, count: 65_537)) }
    try reject { _ = try admit(bytes: try canonicalJSONData(Array(repeating: 3, count: 65))) }
    try reject { _ = try admit(bytes: try canonicalJSONData([-1] + Array(repeating: 3, count: 8191))) }
    try reject { _ = try admit(bytes: try canonicalJSONData([248_320] + Array(repeating: 3, count: 8191))) }
    for malformed in ["[1.0]", "[1e0]", "[true]", "{\"tokens\":[3]}", "[{\"x\":1,\"x\":2}]"] {
        try reject { _ = try admit(bytes: Data(malformed.utf8)) }
    }
    let oldSize = try QwenLayerStageProfiledPrefillRequestSpec(profile: .longPrefill8KV1,
        requestID: request.requestID, batchSize: 1, promptCount: 65, chunkSize: 32, outputCount: 1)
    try reject { _ = try admit(spec: oldSize) }
    let wrongChunk = try QwenLayerStageProfiledPrefillRequestSpec(profile: .longPrefill8KV1,
        requestID: request.requestID, batchSize: 1, promptCount: 8192, chunkSize: 256, outputCount: 1)
    try reject { _ = try admit(spec: wrongChunk) }
    let forged = QwenLongPrefillArithmeticEnvironment.Receipt(contract: arithmetic.contract,
        requiredValues: arithmetic.requiredValues, requiredAbsentNames: arithmetic.requiredAbsentNames,
        full512TokenChunkQueryBlocks: 3, defaultBindings: arithmetic.defaultBindings)
    try reject { _ = try admit(environment: forged) }
    return (accepted: 1, rejected: rejected)
}
