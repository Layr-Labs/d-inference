import Foundation

func checkQwenLayerStageProfiledPrefillRequestAdmission(
    _ counts: inout QwenLayerStageProfiledPrefillCheckCounts
) throws {
    typealias Fixture = QwenLayerStageProfiledPrefillCheckFixture
    for (prompt, chunk, frames) in [(1, 1, 1), (1, 512, 1), (65, 32, 3),
        (1025, 512, 3), (8192, 512, 16), (8192, 64, 128), (128, 1, 128)] {
        let original = try Fixture.request(prompt, chunk)
        let decoded = try QwenLayerStageProfiledPrefillRequestSpec.decode(original.encoded())
        let admitted = QwenLayerStageAdmittedRequest.profiled(decoded)
        guard decoded == original, decoded.fingerprint == original.fingerprint,
              admitted.prefillFrameCount == frames, admitted.forwardCount == frames,
              admitted.maximumTokens == prompt + 1, admitted.batchSize == 1 else {
            throw ProbeError("Profiled request round trip changed admitted geometry")
        }
        counts.accepted += 1
    }
    for (batch, prompt, chunk, output) in [(0, 1, 1, 1), (2, 1, 1, 1), (1, 0, 1, 1),
        (1, -1, 1, 1), (1, 8193, 512, 1), (1, 8192, 32, 1), (1, 129, 1, 1),
        (1, 1, 0, 1), (1, 1, 513, 1), (1, 1, 1, 0), (1, 1, 1, 2),
        (1, Int.max, 512, 1), (1, Int.min, 1, 1), (1, 1, Int.max, 1), (Int.max, 1, 1, 1)] {
        try counts.reject("constructor geometry") {
            _ = try QwenLayerStageProfiledPrefillRequestSpec(profile: .longPrefill8KV1,
                requestID: Fixture.id, batchSize: batch, promptCount: prompt, chunkSize: chunk, outputCount: output)
        }
    }
    let data = try Fixture.request(8192, 512).encoded()
    let valid = String(decoding: data, as: UTF8.self)
    let invalid = [
        valid.replacingOccurrences(of: "\"long_prefill_8k_v1\"", with: "\"unknown\""),
        valid.replacingOccurrences(of: "\"profile\":\"long_prefill_8k_v1\",", with: ""),
        valid.replacingOccurrences(of: "\"promptCount\":8192", with: "\"promptCount\":8192.0"),
        valid.replacingOccurrences(of: "\"promptCount\":8192", with: "\"promptCount\":8.192e3"),
        valid.replacingOccurrences(of: "\"promptCount\":8192", with: "\"promptCount\":true"),
        valid.replacingOccurrences(of: "\"promptCount\":8192", with: "\"promptCount\":\"8192\""),
        valid.replacingOccurrences(of: "\"promptCount\":8192", with: "\"promptCount\":-0"),
        valid.replacingOccurrences(of: "\"promptCount\":8192", with: "\"promptCount\":99999999999999999999999999999"),
        valid.replacingOccurrences(of: "\"chunkSize\":512", with: "\"chunkSize\":32"),
        valid.replacingOccurrences(of: "\"outputCount\":1", with: "\"outputCount\":2"),
        valid.replacingOccurrences(of: "\"batchSize\":1", with: "\"batchSize\":null"),
        valid.replacingOccurrences(of: Fixture.id.uuidString, with: "invalid-uuid"),
        "{\"extra\":1," + String(valid.dropFirst()),
        "{\"profile\":\"long_prefill_8k_v1\"," + String(valid.dropFirst()),
        "{\"\\u0070rofile\":\"long_prefill_8k_v1\"," + String(valid.dropFirst()),
        valid + "{}", "[]", "", String(repeating: " ", count: 2049),
    ]
    for raw in invalid {
        guard raw != valid else { throw ProbeError("Malformed profiled request fixture failed to change its input") }
        try counts.reject("strict raw request") { _ = try QwenLayerStageProfiledPrefillRequestSpec.decode(Data(raw.utf8)) }
    }
    try counts.reject("unscanned direct decoder") { _ = try JSONDecoder().decode(QwenLayerStageProfiledPrefillRequestSpec.self, from: data) }
    try counts.reject("long request through legacy constructor") {
        _ = try QwenLayerStageRequestSpec(requestID: Fixture.id, promptCount: 8192, chunkSize: 512, outputCount: 1)
    }
    try counts.reject("long request through legacy decoder") { _ = try JSONDecoder().decode(QwenLayerStageRequestSpec.self, from: data) }
    let request = try Fixture.request(65, 32)
    for (vocabulary, prompt, teacher) in [(32, [Int](repeating: 1, count: 64), []),
        (32, [Int](repeating: 1, count: 65), [1]), (0, [Int](repeating: 1, count: 65), []),
        (262_145, [Int](repeating: 1, count: 65), []), (32, [Int](repeating: -1, count: 65), []),
        (32, [Int](repeating: 32, count: 65), [])] {
        try counts.reject("recorded token history") {
            _ = try QwenLayerStageProfiledPrefillRecordedRequest(request: request, vocabularySize: vocabulary,
                prompt: prompt, teacher: teacher)
        }
    }
}
