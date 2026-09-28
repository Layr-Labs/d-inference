import Foundation

/// Pure codec checks. No model, MLX array, process, socket or transport operation.
func checkQwenLayerStageLookaheadWire(includeVectors: Bool = false) throws {
    typealias Envelope = QwenLayerStageLookaheadWireEnvelope
    typealias ACK = QwenLayerStageLookaheadWireAcknowledgement
    let source = try QwenLayerStageWireSourceIdentity(sourceConfigurationSHA256: String(repeating: "a", count: 64),
        artifactAggregateSHA256: String(repeating: "b", count: 64), storageCommitmentSHA256: String(repeating: "c", count: 64),
        planFingerprint: String(repeating: "d", count: 64), producerStageFingerprint: String(repeating: "e", count: 64))
    let request = try QwenLayerStageRequestSpec(requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        promptCount: 65, chunkSize: 32, outputCount: 4)
    var schedule = QwenLayerStageSchedule(request: request)
    var frames = [QwenLayerStageFrame]()
    for offset in [0, 32, 64] {
        let count = min(32, request.promptCount - offset)
        let frame = try schedule.admitPrefill(count: count, offset: offset, final: offset + count == request.promptCount)
        frames.append(frame); try schedule.commit(frame)
    }
    for _ in 0..<3 {
        let frame = try schedule.admitDecode(offset: schedule.committedTokens)
        frames.append(frame); try schedule.commit(frame)
    }
    func expectation(_ frame: QwenLayerStageFrame, dtype: String = "bfloat16") throws -> QwenLayerStageBoundaryWireExpectation {
        try QwenLayerStageBoundaryWireExpectation(request: request, frame: frame,
            tokenIDs: Array(repeating: 7, count: frame.tokenCount), sourceIdentity: source, hiddenSize: 128, nativeDType: dtype)
    }
    struct AcknowledgementVector: Encodable {
        let phase: String
        let values: [Int32]
        let logicalBytesSHA256: String
    }
    struct Vector: Encodable {
        let variant: String
        let frame: QwenLayerStageFrame
        let dtype: String
        let payloadByteCount: Int
        let innerBase64: String
        let outerBase64: String
        let outerSHA256: String
        let acknowledgements: [AcknowledgementVector]
    }
    var vectors = [Vector](), rejections = [String]()
    func capture(_ envelope: Envelope, variant: String) throws {
        let acks = try ACK.Phase.allCases.map { phase -> AcknowledgementVector in
            let values = ACK.values(envelope: envelope, phase: phase)
            try ACK.validate(values, envelope: envelope, phase: phase)
            var bytes = Data()
            for value in values {
                var little = value.littleEndian
                withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
            }
            guard values.count == 64, bytes.count == 256 else { throw ProbeError("Lookahead ACK storage geometry changed") }
            return .init(phase: phase.rawValue, values: values, logicalBytesSHA256: sha256(bytes))
        }
        vectors.append(.init(variant: variant, frame: envelope.boundary.frame, dtype: envelope.boundary.dtype,
            payloadByteCount: envelope.boundary.byteCount, innerBase64: try envelope.boundary.encoded().base64EncodedString(),
            outerBase64: envelope.encoded().base64EncodedString(), outerSHA256: sha256(envelope.encoded()), acknowledgements: acks))
    }
    for dtype in ["bfloat16", "float16", "float32"] {
        for frame in frames {
            let expected = try expectation(frame, dtype: dtype)
            let payload = Data(repeating: 19, count: expected.byteCount)
            let boundary = try QwenLayerStageBoundaryWireHeader(expected: expected, payloadSHA256: sha256(payload))
            let envelope = try Envelope(boundary: boundary, expected: expected)
            let decoded = try Envelope.decode(envelope.encoded(), expected: expected)
            guard decoded == envelope, decoded.boundary == boundary else { throw ProbeError("Lookahead round trip changed identity") }
            try decoded.boundary.validatePayload(payload)
            try capture(decoded, variant: "canonical")
        }
    }
    let expected = try expectation(frames[0])
    let payload = Data(repeating: 19, count: expected.byteCount)
    let boundary = try QwenLayerStageBoundaryWireHeader(expected: expected, payloadSHA256: sha256(payload))
    let envelope = try Envelope(boundary: boundary, expected: expected)
    let encoded = envelope.encoded(), text = String(decoding: encoded, as: UTF8.self)
    let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    func replace(_ original: String, _ replacement: String) throws -> Data {
        guard text.contains(original) else { throw ProbeError("Lookahead test replacement did not select original bytes") }
        return Data(text.replacingOccurrences(of: original, with: replacement).utf8)
    }
    func reject(_ label: String, _ action: () throws -> Void) throws {
        do { try action() } catch { rejections.append(label); return }
        throw ProbeError("Lookahead codec admitted " + label)
    }
    func rejectData(_ label: String, _ data: Data) throws {
        try reject(label) { _ = try Envelope.decode(data, expected: expected) }
    }
    func rejectObject(_ label: String, _ change: (inout [String: Any]) -> Void) throws {
        var changed = object; change(&changed)
        try rejectData(label, JSONSerialization.data(withJSONObject: changed, options: [.sortedKeys]))
    }
    func rejectNested(_ label: String, _ change: (inout [String: Any]) -> Void) throws {
        try rejectObject(label) { outer in
            var nested = outer["boundary"] as! [String: Any]; change(&nested); outer["boundary"] = nested
        }
    }
    for (variant, data) in [
        ("surrounding_whitespace", Data(" \n".utf8) + encoded + Data("\t".utf8)),
        ("integer_negative_zero", try replace("\"tokenOffset\":0", "\"tokenOffset\":-0")),
        ("exact_byte_limit", encoded + Data(repeating: 32, count: Envelope.maximumEncodedBytes - encoded.count)),
    ] {
        let decoded = try Envelope.decode(data, expected: expected)
        guard decoded.boundary == boundary, decoded.encoded() == data, decoded.encoded() != encoded,
              ACK.values(envelope: decoded, phase: .ready) != ACK.values(envelope: envelope, phase: .ready) else {
            throw ProbeError("Lookahead decoder canonicalized exact outer bytes before ACK binding")
        }
        try capture(decoded, variant: variant)
        try reject("canonical ACK replay into " + variant) {
            try ACK.validate(ACK.values(envelope: envelope, phase: .ready), envelope: decoded, phase: .ready)
        }
    }
    try rejectData("bare v1 into lookahead v2", boundary.encoded())
    try reject("lookahead v2 into bare v1") { _ = try QwenLayerStageBoundaryWireHeader.decode(encoded, expected: expected) }
    for flow in ["strict_v1", "prompt_lookahead_two_v1", "prompt_lookahead_one_v2", ""] {
        try rejectObject("incompatible flow " + flow) { $0["flow"] = flow }
    }
    try rejectObject("numeric flow") { $0["flow"] = 1 }
    try rejectObject("outer version 1") { $0["version"] = 1 }
    try rejectObject("outer boolean version") { $0["version"] = true }
    try rejectObject("missing outer flow") { $0.removeValue(forKey: "flow") }
    try rejectObject("extra outer field") { $0["unexpected"] = 1 }
    try rejectObject("nonobject nested boundary") { $0["boundary"] = [] }
    try rejectNested("extra nested field") { $0["unexpected"] = 1 }
    try rejectNested("missing nested byteCount") { $0.removeValue(forKey: "byteCount") }
    try rejectNested("nested version 2") { $0["version"] = 2 }
    try rejectNested("boolean nested count") { $0["byteCount"] = true }
    try rejectNested("boolean shape dimension") { $0["shape"] = [true, 32, 128] as [Any] }
    try rejectNested("numeric finalPromptChunk") {
        var frame = $0["frame"] as! [String: Any]; frame["finalPromptChunk"] = 0; $0["frame"] = frame
    }
    try rejectNested("boolean frame sequence") {
        var frame = $0["frame"] as! [String: Any]; frame["sequence"] = true; $0["frame"] = frame
    }
    try rejectNested("extra frame field") {
        var frame = $0["frame"] as! [String: Any]; frame["extra"] = false; $0["frame"] = frame
    }
    try rejectNested("missing frame sequence") {
        var frame = $0["frame"] as! [String: Any]; frame.removeValue(forKey: "sequence"); $0["frame"] = frame
    }
    for (original, bad) in [
        ("\"version\":2", "\"version\":2.0"), ("\"version\":2", "\"version\":2e0"),
        ("\"version\":1", "\"version\":1.0"), ("\"byteCount\":8192", "\"byteCount\":8192.0"),
        ("\"byteCount\":8192", "\"byteCount\":8192e0"), ("\"byteCount\":8192", "\"byteCount\":9223372036854775808"),
        ("\"sequence\":0", "\"sequence\":0.0"), ("\"tokenOffset\":0", "\"tokenOffset\":0E0"),
        ("\"tokenCount\":32", "\"tokenCount\":32.0"), ("\"shape\":[1,32,128]", "\"shape\":[1.0,32,128]"),
        ("\"shape\":[1,32,128]", "\"shape\":[1,32e0,128]"), ("\"shape\":[1,32,128]", "\"shape\":[1,32,128.0]"),
        ("\"version\":2", "\"version\":02"), ("\"version\":2", "\"version\":200000000000000000000"),
        ("\"version\":2", "\"version\":NaN"),
    ] { try rejectData("raw integer lexeme " + bad, replace(original, bad)) }
    for malformed in [
        "{\"version\":2," + String(text.dropFirst()),
        "{\"\\u0076ersion\":2," + String(text.dropFirst()),
        text.replacingOccurrences(of: "\"boundary\":{", with: "\"boundary\":{\"version\":1,"),
        text.replacingOccurrences(of: "\"boundary\":{", with: "\"boundary\":{\"\\u0076ersion\":1,"),
        text.replacingOccurrences(of: "\"frame\":{", with: "\"frame\":{\"sequence\":0,"),
        text.replacingOccurrences(of: "\"frame\":{", with: "\"frame\":{\"seque\\u006ece\":0,"),
        text + " null", "[]", "null", "", String(text.dropLast()),
        String(repeating: "[", count: 66) + "0" + String(repeating: "]", count: 66),
    ].enumerated() { try rejectData("raw malformed JSON \(malformed.offset)", Data(malformed.element.utf8)) }
    try rejectData("invalid UTF8", Data([0xff, 0xfe]))
    try rejectData("over byte bound", encoded + Data(repeating: 32, count: Envelope.maximumEncodedBytes + 1 - encoded.count))
    try reject("sender actual header differs from local tokens") {
        let different = try QwenLayerStageBoundaryWireExpectation(request: request, frame: frames[0], tokenIDs: Array(repeating: 8, count: 32),
            sourceIdentity: source, hiddenSize: 128, nativeDType: "bfloat16")
        _ = try Envelope(boundary: boundary, expected: different)
    }
    try reject("receiver local frame replay") { _ = try Envelope.decode(encoded, expected: expectation(frames[1])) }
    for actual in ACK.Phase.allCases {
        for expectedPhase in ACK.Phase.allCases where actual != expectedPhase {
            try reject("ACK phase \(actual.rawValue) replay into \(expectedPhase.rawValue)") {
                try ACK.validate(ACK.values(envelope: envelope, phase: actual), envelope: envelope, phase: expectedPhase)
            }
        }
    }
    let changed = try QwenLayerStageBoundaryWireHeader(expected: expected, payloadSHA256: String(repeating: "f", count: 64))
    let other = try Envelope(boundary: changed, expected: expected)
    for phase in ACK.Phase.allCases {
        try reject("ACK changed header replay " + phase.rawValue) {
            try ACK.validate(ACK.values(envelope: envelope, phase: phase), envelope: other, phase: phase)
        }
    }
    try reject("bare v1 ACK into v2") {
        try ACK.validate(QwenLayerStageWireAcknowledgement.values(header: boundary.encoded(), phase: .ready), envelope: envelope, phase: .ready)
    }
    try reject("v2 ACK into bare v1") {
        try QwenLayerStageWireAcknowledgement.validate(ACK.values(envelope: envelope, phase: .ready), header: boundary.encoded(), phase: .ready)
    }
    try reject("bare v1 namespace using same outer bytes") {
        try ACK.validate(QwenLayerStageWireAcknowledgement.values(header: encoded, phase: .ready), envelope: envelope, phase: .ready)
    }
    try reject("short ACK") { try ACK.validate(Array(ACK.values(envelope: envelope, phase: .ready).dropLast()), envelope: envelope, phase: .ready) }
    try reject("oversize ACK") { try ACK.validate(ACK.values(envelope: envelope, phase: .ready) + [0], envelope: envelope, phase: .ready) }
    try reject("out of range ACK element") {
        var values = ACK.values(envelope: envelope, phase: .ready); values[0] = Int32.max
        try ACK.validate(values, envelope: envelope, phase: .ready)
    }
    guard vectors.count == 21, Set(rejections).count == rejections.count else { throw ProbeError("Lookahead codec coverage changed") }
    struct Result: Encodable {
        let kind = "qwen_layer_stage_lookahead_wire_check"
        let cpuOnly = true
        let flow = Envelope.flow
        let acceptedEnvelopeCases: Int
        let rejectedFixtures: Int
        let rejectionLabels: [String]
        let vectors: [Vector]?
    }
    try emitJSON(Result(acceptedEnvelopeCases: vectors.count, rejectedFixtures: rejections.count,
        rejectionLabels: rejections, vectors: includeVectors ? vectors : nil))
}
