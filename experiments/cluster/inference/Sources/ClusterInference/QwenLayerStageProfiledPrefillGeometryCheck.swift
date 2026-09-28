import Foundation

struct QwenLayerStageProfiledPrefillGeometryCheckResult: Encodable {
    let kind = "qwen_layer_stage_profiled_prefill_geometry_check"
    let cpuOnly = true
    let profile = QwenLayerStagePrefillProfile.longPrefill8KV1.rawValue
    let longTimelineFrames = 16, raggedTimelineFrames = 3, maximumTimelineFrames = 128
    let legacyForwardCount = 6
    let legacyFingerprintsPreserved = true, distinctProfiledIdentity = true
    let strictRequestDecode = true, modelOrWireAdmissionPerformed = false
    let acceptedFixtures: Int, rejectedFixtures: Int
}

struct QwenLayerStageProfiledPrefillCheckCounts {
    var accepted = 0, rejected = 0

    mutating func reject(_ label: String, _ body: () throws -> Void) throws {
        do { try body() } catch { rejected += 1; return }
        throw ProbeError("Profiled prefill check accepted " + label)
    }
}

enum QwenLayerStageProfiledPrefillCheckFixture {
    static let id = UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!
    static func request(_ prompt: Int, _ chunk: Int) throws -> QwenLayerStageProfiledPrefillRequestSpec {
        try .init(profile: .longPrefill8KV1, requestID: id, batchSize: 1,
                  promptCount: prompt, chunkSize: chunk, outputCount: 1)
    }
    static func recorded(_ prompt: Int, _ chunk: Int) throws -> QwenLayerStageProfiledPrefillRecordedRequest {
        try .init(request: request(prompt, chunk), vocabularySize: 32,
                  prompt: (0..<prompt).map { $0 % 32 }, teacher: [])
    }
}

/// Returns one CPU-only result; the adapter owner decides when to emit it.
/// Hash vectors were reproduced independently with Python hashlib, not Swift.
func checkQwenLayerStageProfiledPrefillGeometry() throws -> QwenLayerStageProfiledPrefillGeometryCheckResult {
    var counts = QwenLayerStageProfiledPrefillCheckCounts()
    try checkQwenLayerStageProfiledPrefillRequestAdmission(&counts)
    try checkQwenLayerStageProfiledPrefillSchedules(&counts)
    let profile = QwenLayerStagePrefillProfile.longPrefill8KV1
    let long = try QwenLayerStageProfiledPrefillCheckFixture.recorded(8192, 512)
    let small = try QwenLayerStageProfiledPrefillCheckFixture.recorded(65, 32)
    let legacy = try QwenLayerStageRequestSpec(requestID: QwenLayerStageProfiledPrefillCheckFixture.id,
        promptCount: 65, chunkSize: 32, outputCount: 1)
    let legacyRecorded = try QwenLayerStageRecordedRequest(request: legacy, vocabularySize: 32,
        prompt: (0..<65).map { $0 % 32 }, teacher: [])
    guard profile.fingerprint == "2b7f484488df61c4f6042acfb472a8099828c8a6246819501c88d4f6e07bcc0b",
          long.request.fingerprint == "a0f720bd2fc26e70f6cf3e747a8bbd452da4db35e93a3223b6f7a15141e00f01",
          long.fingerprint == "a93b4569df924539c679d5c1e2422306f682cba54b6ef7b9ddbc8680ded64fc5",
          small.request.fingerprint == "ca72e47086f50e35696703d925884565f504e8d413b931974e699803c27b6519",
          small.fingerprint == "da199a3499b6e881f848faa9d53c35267d17bf5632c57994de53495e3f8d1c6d",
          legacy.fingerprint == "069237459dc6d71e70c9c3d4fa1c7852753812d76982b6874af67a9722ee9293",
          legacyRecorded.fingerprint == "e6fbad7c4d7870cbe2b1c6950b5920369501ed7fefeb52d44651efba32e2f7a1",
          small.request.fingerprint != legacy.fingerprint, small.fingerprint != legacyRecorded.fingerprint,
          QwenLayerStageAdmittedRequest.legacy(legacy) != .profiled(small.request) else {
        throw ProbeError("Profiled prefill identity or legacy fingerprint vector changed")
    }
    counts.accepted += 7
    let oldJSON = try canonicalJSONData(legacy)
    let oldExpected = Data("{\"chunkSize\":32,\"outputCount\":1,\"promptCount\":65,\"requestID\":\"00112233-4455-6677-8899-AABBCCDDEEFF\"}".utf8)
    guard oldJSON == oldExpected,
          try JSONDecoder().decode(QwenLayerStageRequestSpec.self, from: oldJSON) == legacy else {
        throw ProbeError("Legacy four-field JSON encoding or direct decoder changed")
    }
    counts.accepted += 1
    return .init(acceptedFixtures: counts.accepted, rejectedFixtures: counts.rejected)
}
