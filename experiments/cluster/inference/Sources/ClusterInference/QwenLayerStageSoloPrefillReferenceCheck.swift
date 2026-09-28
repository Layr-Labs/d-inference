import Foundation

struct QwenLayerStageSoloPrefillReferenceCheckResult: Encodable {
    let kind = "qwen_layer_stage_solo_prefill_reference_check"
    let cpuOnly = true
    let acceptedCases: Int
    let rejectedCases: Int
    let rejectionLabels: [String]
}

/// Pure codec/scope checks; callable by adapter-check without loading a model,
/// constructing native arrays, reading files, using a clock or opening sockets.
func checkQwenLayerStageSoloPrefillReference() throws -> QwenLayerStageSoloPrefillReferenceCheckResult {
    typealias R = QwenLayerStageSoloPrefillReference
    let fixture = try QwenLayerStageSoloPrefillReferenceFixture()
    var accepted = 0, rejected: [String] = []
    func decode(_ bytes: Data, using value: QwenLayerStageSoloPrefillReferenceFixture? = nil,
        filePin: String? = nil, evidencePin: String? = nil,
        request: QwenLayerStageRecordedRequest? = nil) throws -> R {
        let f = value ?? fixture
        return try R.decode(bytes, expectedFileSHA256: filePin ?? sha256(bytes),
            expectedBaselineEvidenceFingerprint: evidencePin ?? f.descriptor.baselineEvidenceFingerprint,
            plan: f.plan, request: request ?? f.request)
    }
    func reject(_ label: String, _ body: () throws -> Void) throws {
        do { try body() } catch { rejected.append(label); return }
        throw ProbeError("Solo reference check admitted " + label)
    }
    func changed(_ key: String?, _ mutate: (inout [String: Any]) -> Void) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: fixture.data) as! [String: Any]
        if let key {
            var nested = object[key] as! [String: Any]; mutate(&nested); object[key] = nested
        } else { mutate(&object) }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    func replace(_ old: String, _ new: String) throws -> Data {
        let text = String(decoding: fixture.data, as: UTF8.self)
        guard text.contains(old) else { throw ProbeError("Solo reference fixture replacement missed its target") }
        return Data(text.replacingOccurrences(of: old, with: new).utf8)
    }
    func rejectChange(_ label: String, key: String?, _ mutation: (inout [String: Any]) -> Void) throws {
        let bytes = try changed(key, mutation)
        try reject(label) { _ = try decode(bytes) }
    }
    for dtype in ["float16", "bfloat16", "float32"] {
        let f = try QwenLayerStageSoloPrefillReferenceFixture(dtype: dtype)
        let value = try decode(f.data, using: f)
        guard value.descriptor == f.descriptor, value.fileSHA256 == sha256(f.data) else {
            throw ProbeError("Solo reference round trip changed admitted CPU metadata")
        }
        accepted += 1
    }
    for (prompt, chunk, kernel) in [(1, 1, 4), (128, 1, 4), (128, 32, 4), (65, 32, 1)] {
        let f = try QwenLayerStageSoloPrefillReferenceFixture(promptCount: prompt, chunkSize: chunk, convolutionKernel: kernel)
        _ = try decode(f.data, using: f); accepted += 1
    }
    let padded = fixture.data + Data(repeating: 32, count: R.maximumEncodedBytes - fixture.data.count)
    _ = try decode(padded); accepted += 1
    try reject("oversized bytes") { _ = try decode(padded + Data([32])) }
    try reject("unknown file pin") { _ = try decode(fixture.data, filePin: String(repeating: "f", count: 64)) }
    try reject("unknown native evidence pin") { _ = try decode(fixture.data, evidencePin: String(repeating: "f", count: 64)) }
    try reject("non-SHA file pin") { _ = try decode(fixture.data, filePin: "bad") }
    try reject("baseline request identity reused") { _ = try decode(fixture.data, request: fixture.baselineRequest) }
    let nestedKeys: [String?] = [nil, "source", "request", "finalState", "finalLogits", "selection"]
    for key in nestedKeys {
        try rejectChange("extra field in " + (key ?? "root"), key: key) { $0["unknown"] = 1 }
    }
    for (label, replacement) in [("duplicate key", "\"schemaVersion\":1,\"schemaVersion\":1"),
        ("escaped duplicate key", "\"schemaVersion\":1,\"schema\\u0056ersion\":1"),
        ("fraction integer", "\"schemaVersion\":1.0"), ("exponent integer", "\"schemaVersion\":1e0"),
        ("boolean integer", "\"schemaVersion\":true"), ("out-of-range integer", "\"schemaVersion\":18446744073709551616")] {
        try reject(label) { _ = try decode(replace("\"schemaVersion\":1", replacement)) }
    }
    try reject("trailing value") { _ = try decode(fixture.data + Data(" {}".utf8)) }
    try rejectChange("wrong schema", key: nil) { $0["schemaVersion"] = 2 }
    try rejectChange("wrong kind", key: nil) { $0["kind"] = "other" }
    for (key, value) in [("promptCount", 66), ("chunkSize", 31), ("outputCount", 2),
        ("vocabularySize", 255), ("committedTokens", 64)] {
        try rejectChange("request " + key, key: "request") { $0[key] = value }
    }
    try rejectChange("prompt history SHA", key: "request") { $0["promptTokenIDsSHA256"] = String(repeating: "f", count: 64) }
    for (key, value) in [("sequence", 1), ("tokenOffset", 63), ("tokenCount", 2)] {
        try rejectChange("final frame " + key, key: "request") {
            var frame = $0["finalFrame"] as! [String: Any]; frame[key] = value; $0["finalFrame"] = frame
        }
    }
    try rejectChange("frame extra field", key: "request") {
        var frame = $0["finalFrame"] as! [String: Any]; frame["unknown"] = 1; $0["finalFrame"] = frame
    }
    try rejectChange("frame final flag", key: "request") {
        var frame = $0["finalFrame"] as! [String: Any]; frame["finalPromptChunk"] = false; $0["finalFrame"] = frame
    }
    for key in ["sourceConfigurationSHA256", "planSHA256"] {
        try rejectChange("source " + key, key: "source") { $0[key] = String(repeating: "f", count: 64) }
    }
    try rejectChange("unbounded source bytes", key: "source") { $0["sourceModelTensorBytes"] = Int.max }
    let stateChanges: [(String, (inout [String: Any]) -> Void)] = [
        ("state geometry", { (entry: inout [String: Any]) in entry["shape"] = [1, 1, 1] }),
        ("state dtype", { (entry: inout [String: Any]) in entry["dtype"] = "int32" }),
        ("state bytes", { (entry: inout [String: Any]) in entry["byteCount"] = -1 }),
        ("state hash", { (entry: inout [String: Any]) in entry["sha256"] = String(repeating: "f", count: 64) }),
        ("state extra field", { (entry: inout [String: Any]) in entry["unknown"] = 1 })]
    for (label, mutation) in stateChanges {
        try rejectChange(label, key: "finalState") {
            var entries = $0["entries"] as! [[String: Any]]; mutation(&entries[0]); $0["entries"] = entries
        }
    }
    try rejectChange("state missing entry", key: "finalState") { var entries = $0["entries"] as! [[String: Any]]; entries.removeLast(); $0["entries"] = entries }
    try rejectChange("state duplicate entry", key: "finalState") { var entries = $0["entries"] as! [[String: Any]]; entries[1] = entries[0]; $0["entries"] = entries }
    try rejectChange("state fingerprint", key: "finalState") { $0["fingerprint"] = String(repeating: "f", count: 64) }
    try rejectChange("state total", key: "finalState") { $0["logicalByteCount"] = 1 }
    try rejectChange("state frontier", key: "finalState") { $0["committedTokens"] = 64 }
    for (key, value) in [("tokenID", -1), ("tokenID", 256), ("maximumTieCount", 0), ("maximumTieCount", 257)] {
        try rejectChange("selection " + key + "=" + String(value), key: "selection") { $0[key] = value }
    }
    try rejectChange("selection policy", key: "selection") { $0["policy"] = "other" }
    try rejectChange("selection nonfinite", key: "selection") { $0["allLogitsFinite"] = false }
    try rejectChange("selection boolean integer", key: "selection") { $0["allLogitsFinite"] = 1 }
    try rejectChange("logit dtype", key: "finalLogits") { $0["dtype"] = "int32" }
    try rejectChange("logit shape", key: "finalLogits") { $0["shape"] = [1, 255] }
    try rejectChange("logit bytes", key: "finalLogits") { $0["byteCount"] = 1 }
    try rejectChange("logit malformed hash", key: "finalLogits") { $0["logicalBytesSHA256"] = "bad" }
    let changedDigest = try changed("finalLogits") { $0["logicalBytesSHA256"] = String(repeating: "f", count: 64) }
    try reject("altered valid digest under frozen file pin") { _ = try decode(changedDigest, filePin: sha256(fixture.data)) }
    return .init(acceptedCases: accepted, rejectedCases: rejected.count, rejectionLabels: rejected)
}
