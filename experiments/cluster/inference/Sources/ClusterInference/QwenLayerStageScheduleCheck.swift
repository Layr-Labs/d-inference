import Foundation

/// Real schedule admission failures and validated decoding, without MLX or IO.
func checkQwenLayerStageSchedule() throws {
    let id = UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!
    let request = try QwenLayerStageRequestSpec(requestID: id, promptCount: 65, chunkSize: 32, outputCount: 4)
    let decoded = try JSONDecoder().decode(QwenLayerStageRequestSpec.self, from: JSONEncoder().encode(request))
    guard decoded == request, decoded.fingerprint == request.fingerprint else {
        throw ProbeError("Stage request decoding changed admitted values or identity")
    }
    var rejected = 0
    func reject(_ label: String, _ action: () throws -> Void) throws {
        do { try action() } catch { rejected += 1; return }
        throw ProbeError("Stage schedule check accepted " + label)
    }
    let valid: [String: Any] = ["requestID": id.uuidString, "promptCount": 65, "chunkSize": 32, "outputCount": 4]
    for (key, value) in [("promptCount", 0 as Any), ("promptCount", 129), ("promptCount", -1),
        ("chunkSize", 0), ("chunkSize", 33), ("outputCount", 0), ("outputCount", 5),
        ("promptCount", true), ("chunkSize", 1.5), ("outputCount", "4"), ("requestID", "not-a-uuid")] {
        var invalid = valid; invalid[key] = value
        let data = try JSONSerialization.data(withJSONObject: invalid, options: [.sortedKeys])
        try reject("decoded request " + key) { _ = try JSONDecoder().decode(QwenLayerStageRequestSpec.self, from: data) }
    }
    var schedule = QwenLayerStageSchedule(request: decoded)
    try reject("decode before prompt") { _ = try schedule.admitDecode(offset: 0) }
    try reject("short nonfinal chunk") { _ = try schedule.admitPrefill(count: 31, offset: 0, final: false) }
    try reject("early final flag") { _ = try schedule.admitPrefill(count: 32, offset: 0, final: true) }
    try reject("out-of-order offset") { _ = try schedule.admitPrefill(count: 32, offset: 32, final: false) }
    let first = try schedule.admitPrefill(count: 32, offset: 0, final: false)
    try reject("out-of-order sequence") {
        try schedule.commit(.init(sequence: 1, phase: .prefill, tokenOffset: 0, tokenCount: 32, finalPromptChunk: false))
    }
    guard schedule.committedTokens == 0, schedule.nextSequence == 0 else {
        throw ProbeError("Rejected first stage frame advanced state")
    }
    try schedule.commit(first)
    try reject("duplicate committed frame") { try schedule.commit(first) }
    let second = try schedule.admitPrefill(count: 32, offset: 32, final: false)
    try schedule.commit(second)
    try reject("missing final flag") { _ = try schedule.admitPrefill(count: 1, offset: 64, final: false) }
    let last = try schedule.admitPrefill(count: 1, offset: 64, final: true)
    guard [first.sequence, second.sequence, last.sequence] == [0, 1, 2],
        [first.tokenCount, second.tokenCount, last.tokenCount] == [32, 32, 1] else {
        throw ProbeError("65-token stage prompt did not retain its exact 32/32/1 microchunks")
    }
    try schedule.commit(last)
    try reject("prefill after prompt frontier") { _ = try schedule.admitPrefill(count: 1, offset: 65, final: true) }
    try reject("decode at wrong frontier") { _ = try schedule.admitDecode(offset: 64) }
    try reject("malformed decode frame") {
        try schedule.commit(.init(sequence: 3, phase: .decode, tokenOffset: 65, tokenCount: 2, finalPromptChunk: false))
    }
    for offset in 65..<68 {
        let frame = try schedule.admitDecode(offset: offset)
        guard frame.sequence == offset - 62, frame.phase == .decode,
            frame.tokenCount == 1, !frame.finalPromptChunk else { throw ProbeError("Decode frame identity differs") }
        try schedule.commit(frame)
    }
    try reject("extra decode") { _ = try schedule.admitDecode(offset: 68) }
    guard schedule.complete, schedule.committedPromptTokens == 65,
        schedule.decodeForwardCount == 3, schedule.committedTokens == 68, schedule.nextSequence == 6 else {
        throw ProbeError("Layer-stage schedule did not complete its exact agreed frontier")
    }
    struct Result: Encodable {
        let kind = "qwen_layer_stage_schedule_check"
        let cpuOnly = true
        let validatedRequestDecode = true
        let promptChunkSizes = [32, 32, 1]
        let decodeForwards = 3
        let finalCommittedTokens = 68
        let rejectedFixtures: Int
    }
    try emitJSON(Result(rejectedFixtures: rejected))
}
