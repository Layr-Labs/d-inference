import Foundation

/// Pure header/admission check; no model, array, socket, payload transport or GPU.
func checkQwenLayerStageBoundaryWire() throws {
    let source = try QwenLayerStageWireSourceIdentity(sourceConfigurationSHA256: String(repeating: "a", count: 64),
        artifactAggregateSHA256: String(repeating: "b", count: 64),
        storageCommitmentSHA256: String(repeating: "c", count: 64),
        planFingerprint: String(repeating: "d", count: 64), producerStageFingerprint: String(repeating: "e", count: 64))
    let request = try QwenLayerStageRequestSpec(requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        promptCount: 65, chunkSize: 32, outputCount: 4)
    var schedule = QwenLayerStageSchedule(request: request)
    var accepted = 0, rejected = 0
    func roundTrip(_ frame: QwenLayerStageFrame) throws {
        let expected = try QwenLayerStageBoundaryWireExpectation(request: request, frame: frame,
            tokenIDs: Array(repeating: 7, count: frame.tokenCount), sourceIdentity: source,
            hiddenSize: 128, nativeDType: "bfloat16")
        let payload = Data(repeating: 19, count: expected.byteCount)
        let original = try QwenLayerStageBoundaryWireHeader(expected: expected, payloadSHA256: sha256(payload))
        let decoded = try QwenLayerStageBoundaryWireHeader.decode(original.encoded(), expected: expected)
        guard decoded == original, decoded.byteCount == expected.byteCount else {
            throw ProbeError("Valid stage wire round trip changed header identity")
        }
        try decoded.validatePayload(payload)
        accepted += 1
    }
    for offset in [0, 32, 64] {
        let count = min(32, request.promptCount - offset)
        let frame = try schedule.admitPrefill(count: count, offset: offset, final: offset + count == request.promptCount)
        try roundTrip(frame); try schedule.commit(frame)
    }
    for _ in 0..<3 {
        let frame = try schedule.admitDecode(offset: schedule.committedTokens)
        try roundTrip(frame); try schedule.commit(frame)
    }
    guard schedule.complete, accepted == 6 else { throw ProbeError("Stage wire round trips missed part of the request") }

    let frame = QwenLayerStageFrame(sequence: 0, phase: .prefill, tokenOffset: 0, tokenCount: 32, finalPromptChunk: false)
    let expected = try QwenLayerStageBoundaryWireExpectation(request: request, frame: frame,
        tokenIDs: Array(repeating: 7, count: 32), sourceIdentity: source, hiddenSize: 128, nativeDType: "bfloat16")
    let payload = Data(repeating: 19, count: expected.byteCount)
    let header = try QwenLayerStageBoundaryWireHeader(expected: expected, payloadSHA256: sha256(payload))
    let encoded = try header.encoded()
    let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    let text = String(decoding: encoded, as: UTF8.self)
    func reject(_ label: String, _ action: () throws -> Void) throws {
        do { try action() } catch { rejected += 1; return }
        throw ProbeError("Stage wire check accepted " + label)
    }
    func rejectObject(_ label: String, change: (inout [String: Any]) -> Void) throws {
        var changed = object; change(&changed)
        let data = try JSONSerialization.data(withJSONObject: changed, options: [.sortedKeys])
        try reject(label) { _ = try QwenLayerStageBoundaryWireHeader.decode(data, expected: expected) }
    }
    for key in ["requestFingerprint", "sourceConfigurationSHA256", "artifactAggregateSHA256",
                "storageCommitmentSHA256", "planFingerprint", "producerStageFingerprint", "tokenIDsSHA256"] {
        try rejectObject("wrong " + key) { $0[key] = String(repeating: "f", count: 64) }
    }
    for (key, value) in [("sequence", 1), ("tokenOffset", 1), ("tokenCount", 31)] {
        try rejectObject("wrong frame " + key) {
            var nested = $0["frame"] as! [String: Any]; nested[key] = value; $0["frame"] = nested
        }
    }
    try rejectObject("wrong final flag") {
        var nested = $0["frame"] as! [String: Any]; nested["finalPromptChunk"] = true; $0["frame"] = nested
    }
    try rejectObject("wrong phase") {
        var nested = $0["frame"] as! [String: Any]; nested["phase"] = "decode"; $0["frame"] = nested
    }
    for shape in [[2, 32, 128], [1, 31, 128], [1, 32, 256], [1, 32, 0], [1, 32], [1, 32, 8193]] {
        try rejectObject("wrong shape") { $0["shape"] = shape }
    }
    try rejectObject("wrong native dtype") { $0["dtype"] = "float32"; $0["byteCount"] = expected.byteCount * 2 }
    try rejectObject("unsupported dtype") { $0["dtype"] = "uint8" }
    try rejectObject("wrong payload length") { $0["byteCount"] = expected.byteCount + 1 }
    try rejectObject("wrong version") { $0["version"] = 2 }
    try rejectObject("malformed digest") { $0["payloadSHA256"] = String(repeating: "A", count: 64) }
    try rejectObject("extra field") { $0["unexpected"] = 1 }
    try rejectObject("missing field") { $0.removeValue(forKey: "payloadSHA256") }
    try rejectObject("extra frame field") {
        var nested = $0["frame"] as! [String: Any]; nested["unexpected"] = 1; $0["frame"] = nested
    }
    try rejectObject("missing frame field") {
        var nested = $0["frame"] as! [String: Any]; nested.removeValue(forKey: "sequence"); $0["frame"] = nested
    }
    try rejectObject("boolean count") { $0["byteCount"] = true }
    try rejectObject("boolean dimension") { $0["shape"] = [true, 32, 128] as [Any] }
    try rejectObject("integer final flag") {
        var nested = $0["frame"] as! [String: Any]; nested["finalPromptChunk"] = 0; $0["frame"] = nested
    }
    for malformed in [
        text.replacingOccurrences(of: "\"byteCount\":8192", with: "\"byteCount\":8192.0"),
        text.replacingOccurrences(of: "\"byteCount\":8192", with: "\"byteCount\":8192e0"),
        "{\"version\":1," + String(text.dropFirst()),
        "{\"\\u0076ersion\":1," + String(text.dropFirst()),
        text + " null", "[]", "null", "",
    ] {
        try reject("strict JSON syntax/type") {
            _ = try QwenLayerStageBoundaryWireHeader.decode(Data(malformed.utf8), expected: expected)
        }
    }
    try reject("oversize JSON") {
        _ = try QwenLayerStageBoundaryWireHeader.decode(Data(repeating: 32,
            count: QwenLayerStageBoundaryWireHeader.maximumEncodedBytes + 1), expected: expected)
    }
    try reject("bare Codable decoder bypass") { _ = try JSONDecoder().decode(QwenLayerStageBoundaryWireHeader.self, from: encoded) }
    try reject("wrong payload bytes") { try header.validatePayload(Data(repeating: 20, count: expected.byteCount)) }
    try reject("short payload") { try header.validatePayload(payload.dropLast()) }
    try reject("wrong locally expected token count") {
        _ = try QwenLayerStageBoundaryWireExpectation(request: request, frame: frame, tokenIDs: [7],
            sourceIdentity: source, hiddenSize: 128, nativeDType: "bfloat16")
    }
    try reject("frame outside local request") {
        _ = try QwenLayerStageBoundaryWireExpectation(request: request,
            frame: .init(sequence: 0, phase: .decode, tokenOffset: 0, tokenCount: 1, finalPromptChunk: false),
            tokenIDs: [7], sourceIdentity: source, hiddenSize: 128, nativeDType: "bfloat16")
    }
    struct Result: Encodable {
        let kind = "qwen_layer_stage_boundary_wire_check"
        let cpuOnly = true
        let acceptedFrames: Int
        let rejectedFixtures: Int
    }
    try emitJSON(Result(acceptedFrames: accepted, rejectedFixtures: rejected))
}
