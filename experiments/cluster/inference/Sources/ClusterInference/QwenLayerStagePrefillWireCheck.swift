import Foundation

struct QwenLayerStagePrefillWireCheckResult: Encodable {
    let kind = "qwen_layer_stage_prefill_wire_check"
    let cpuOnly = true
    let acceptedCases: Int
    let rejectedCases: Int
    let rejectionLabels: [String]
}

/// Pure fixtures for scope, raw JSON ambiguity, exact-byte binding and replay.
/// No array, model, clock, socket, native execution or CLI dependency is used.
func checkQwenLayerStagePrefillWire() throws -> QwenLayerStagePrefillWireCheckResult {
    typealias Start = QwenLayerStagePrefillStartWirePacket
    typealias Boundary = QwenLayerStagePrefillBoundaryEnvelope
    typealias Token = QwenLayerStagePrefillFirstTokenWirePacket
    typealias ACK = QwenLayerStagePrefillBoundaryAcknowledgement
    let fixture = try QwenLayerStagePrefillWireCheckFixture()
    var accepted = 0, rejected: [String] = []
    func reject(_ label: String, _ body: () throws -> Void) throws {
        do { try body() } catch { rejected.append(label); return }
        throw ProbeError("Prefill wire check admitted " + label)
    }
    func start(_ data: Data) throws { _ = try Start.decode(data, expectedAgreement: fixture.agreement) }
    func token(_ data: Data) throws { _ = try Token.decode(data, expectedAgreement: fixture.agreement, finalBoundary: fixture.final) }
    func boundary(_ data: Data) throws {
        _ = try Boundary.decode(data, agreement: fixture.agreement, expectedFrame: fixture.final.boundary.frame)
    }
    func changed(_ data: Data, _ mutate: (inout [String: Any]) -> Void) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        mutate(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    func replace(_ data: Data, _ old: String, _ new: String) throws -> Data {
        let text = String(decoding: data, as: UTF8.self)
        guard text.contains(old) else { throw ProbeError("Prefill wire fixture replacement missed its target") }
        return Data(text.replacingOccurrences(of: old, with: new).utf8)
    }
    func active(_ value: QwenLayerStagePrefillWireCheckFixture) throws -> QwenLayerStagePrefillWireLifecycle {
        var gate = QwenLayerStagePrefillWireLifecycle(agreement: value.agreement)
        _ = try gate.acceptStart(value.start.encoded())
        try gate.bindFinalBoundary(value.final)
        return gate
    }
    for policy in QwenLayerStagePrefillMeasurementFlow.SchedulingPolicy.allCases {
        for dtype in ["float16", "bfloat16", "float32"] {
            let value = try QwenLayerStagePrefillWireCheckFixture(policy: policy, dtype: dtype)
            var gate = try active(value)
            guard !gate.firstTokenComplete else { throw ProbeError("A start completed first-token admission") }
            let decoded = try Boundary.decode(value.final.encoded(), agreement: value.agreement,
                expectedFrame: value.final.boundary.frame)
            guard decoded.fingerprint == value.final.fingerprint else { throw ProbeError("Boundary bytes changed in decoding") }
            try gate.acceptFinalConsumed(ACK.values(envelope: value.final, phase: .consumed))
            guard !gate.firstTokenComplete else { throw ProbeError("Consumed ACK supplied a nonexistent selected token") }
            let selected = try gate.acceptFirstToken(value.token.encoded())
            guard gate.firstTokenComplete, selected.tokenID == 7 else { throw ProbeError("Valid first-token handshake failed") }
            var postStop = QwenLayerStagePrefillPostStopGate(token: selected)
            try postStop.accept(QwenLayerStagePrefillPostStopAcknowledgement.values(token: selected))
            guard postStop.released, !postStop.isFailed else { throw ProbeError("Valid post-stop release failed") }
            accepted += 1
        }
    }
    for (prompt, chunk) in [(1, 1), (128, 1), (128, 32)] {
        let value = try QwenLayerStagePrefillWireCheckFixture(promptCount: prompt, chunkSize: chunk)
        _ = try Start.decode(value.start.encoded(), expectedAgreement: value.agreement)
        _ = try Token.decode(value.token.encoded(), expectedAgreement: value.agreement, finalBoundary: value.final)
        accepted += 1
    }
    let whitespace = Data(" \n".utf8) + fixture.final.encoded() + Data("\t".utf8)
    let spacedFinal = try Boundary.decode(whitespace, agreement: fixture.agreement,
        expectedFrame: fixture.final.boundary.frame)
    guard spacedFinal.encoded() == whitespace, spacedFinal.fingerprint != fixture.final.fingerprint else {
        throw ProbeError("Measurement boundary failed exact outer byte preservation")
    }
    accepted += 1
    try reject("ACK replay across equivalent but different boundary bytes") {
        try ACK.validate(ACK.values(envelope: fixture.final, phase: .consumed), envelope: spacedFinal, phase: .consumed)
    }
    try reject("token replay across different final envelope bytes") {
        _ = try Token.decode(fixture.token.encoded(), expectedAgreement: fixture.agreement, finalBoundary: spacedFinal)
    }
    let spacedToken = try Token.decode(Data(" ".utf8) + fixture.token.encoded(),
        expectedAgreement: fixture.agreement, finalBoundary: fixture.final)
    try reject("post-stop ACK replay across different token bytes") {
        try QwenLayerStagePrefillPostStopAcknowledgement.validate(
            QwenLayerStagePrefillPostStopAcknowledgement.values(token: fixture.token), token: spacedToken)
    }
    try reject("replayed post-stop release") {
        var gate = QwenLayerStagePrefillPostStopGate(token: fixture.token)
        let ack = QwenLayerStagePrefillPostStopAcknowledgement.values(token: fixture.token)
        try gate.accept(ack); try gate.accept(ack)
    }
    let otherPolicy = try QwenLayerStagePrefillWireCheckFixture(policy: .promptLookaheadOne)
    let otherSource = try QwenLayerStagePrefillWireCheckFixture(artifactDigit: "9")
    let otherRequest = try QwenLayerStagePrefillWireCheckFixture(
        requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    for (label, other) in [("policy", otherPolicy), ("source", otherSource), ("request", otherRequest)] {
        guard other.agreement.fingerprint != fixture.agreement.fingerprint else { throw ProbeError("Agreement omitted " + label) }
        try reject("start " + label + " mismatch") { _ = try Start.decode(fixture.start.encoded(), expectedAgreement: other.agreement) }
        try reject("boundary " + label + " mismatch") {
            _ = try Boundary.decode(fixture.final.encoded(), agreement: other.agreement, expectedFrame: other.final.boundary.frame)
        }
        try reject("token " + label + " mismatch") {
            _ = try Token.decode(fixture.token.encoded(), expectedAgreement: other.agreement, finalBoundary: other.final)
        }
    }
    try reject("actual sender selection source mismatch") {
        _ = try Token(selection: otherSource.selection, agreement: fixture.agreement, finalBoundary: fixture.final)
    }
    try reject("actual sender selection request mismatch") {
        _ = try Token(selection: otherRequest.selection, agreement: fixture.agreement, finalBoundary: fixture.final)
    }
    try reject("nonfinal boundary used for token") {
        _ = try Token(selection: fixture.selection, agreement: fixture.agreement, finalBoundary: fixture.first)
    }
    for (label, bytes, limit, decode) in [
        ("start", fixture.start.encoded(), Start.maximumEncodedBytes, start),
        ("boundary", fixture.final.encoded(), Boundary.maximumEncodedBytes, boundary),
        ("token", fixture.token.encoded(), Token.maximumEncodedBytes, token),
    ] {
        try reject(label + " extra field") { try decode(changed(bytes) { $0["unknown"] = 1 }) }
        try reject(label + " old flow") { try decode(changed(bytes) { $0["flow"] = "prompt_lookahead_one_v1" }) }
        try reject(label + " boolean version") { try decode(changed(bytes) { $0["version"] = true }) }
        try reject(label + " fractional version") { try decode(replace(bytes, "\"version\":3", "\"version\":3.0")) }
        try reject(label + " exponent version") { try decode(replace(bytes, "\"version\":3", "\"version\":3e0")) }
        try reject(label + " duplicate key") {
            try decode(Data("{\"version\":3,".utf8) + Data(bytes.dropFirst()))
        }
        try reject(label + " escaped duplicate key") {
            try decode(Data("{\"\\u0076ersion\":3,".utf8) + Data(bytes.dropFirst()))
        }
        try reject(label + " oversize") { try decode(bytes + Data(repeating: 32, count: limit + 1 - bytes.count)) }
        try reject(label + " trailing data") { try decode(bytes + Data(" null".utf8)) }
        try reject(label + " invalid UTF8") { try decode(Data([0xff, 0xfe])) }
    }
    try reject("start nested extra field") {
        try start(changed(fixture.start.encoded()) { var nested = $0["agreement"] as! [String: Any]; nested["extra"] = 1; $0["agreement"] = nested })
    }
    try reject("start nested boolean count") {
        try start(changed(fixture.start.encoded()) { var nested = $0["agreement"] as! [String: Any]; nested["outputCount"] = true; $0["agreement"] = nested })
    }
    try reject("start nested duplicate count") {
        try start(replace(fixture.start.encoded(), "\"agreement\":{", "\"agreement\":{\"promptCount\":65,"))
    }
    for field in ["epoch", "agreementFingerprint", "requestFingerprint", "recordedRequestFingerprint", "consumerStageFingerprint", "finalBoundaryEnvelopeSHA256", "selectionPolicy", "logitsDType", "selectionDType"] {
        try reject("token wrong " + field) { try token(changed(fixture.token.encoded()) { $0[field] = "wrong" }) }
    }
    try reject("start changed epoch") {
        try start(changed(fixture.start.encoded()) { var nested = $0["agreement"] as! [String: Any]; nested["epoch"] = String(repeating: "2", count: 32); $0["agreement"] = nested })
    }
    try reject("start missing field") { try start(changed(fixture.start.encoded()) { $0.removeValue(forKey: "agreementFingerprint") }) }
    try reject("token missing field") { try token(changed(fixture.token.encoded()) { $0.removeValue(forKey: "tokenID") }) }
    try reject("boundary original nested boolean integer") {
        try boundary(changed(fixture.final.encoded()) { var nested = $0["boundary"] as! [String: Any]; nested["byteCount"] = true; $0["boundary"] = nested })
    }
    try reject("boundary original nested fraction") {
        try boundary(replace(fixture.final.encoded(), "\"byteCount\":256", "\"byteCount\":256.0"))
    }
    for field in ["committedTokens", "vocabularySize", "tokenOrdinal", "tokenID"] {
        try reject("token boolean " + field) { try token(changed(fixture.token.encoded()) { $0[field] = true }) }
        try reject("token wrong " + field) { try token(changed(fixture.token.encoded()) { $0[field] = -1 }) }
    }
    try reject("token outside vocabulary") { try token(changed(fixture.token.encoded()) { $0["tokenID"] = 256 }) }
    try reject("token nonfinite flag") { try token(changed(fixture.token.encoded()) { $0["allLogitsFinite"] = false }) }
    try reject("token shape changed") { try token(changed(fixture.token.encoded()) { $0["logitsShape"] = [1, 255] }) }
    try reject("token nested frame extra key") {
        try token(changed(fixture.token.encoded()) { var frame = $0["frame"] as! [String: Any]; frame["extra"] = true; $0["frame"] = frame })
    }
    try reject("token nested final flag integer") {
        try token(changed(fixture.token.encoded()) { var frame = $0["frame"] as! [String: Any]; frame["finalPromptChunk"] = 1; $0["frame"] = frame })
    }
    try reject("token nested fraction") { try token(replace(fixture.token.encoded(), "\"tokenOffset\":64", "\"tokenOffset\":64.0")) }
    try reject("token nested duplicate") { try token(replace(fixture.token.encoded(), "\"frame\":{", "\"frame\":{\"sequence\":2,")) }
    try reject("bare v1 into measurement v3") { try boundary(fixture.final.boundary.encoded()) }
    try reject("measurement v3 into bare v1") {
        _ = try QwenLayerStageBoundaryWireHeader.decode(fixture.final.encoded(),
            expected: fixture.agreement.boundaryExpectation(for: fixture.final.boundary.frame))
    }
    for phase in [ACK.Phase.ready, .received] {
        try reject("wrong final ACK phase " + phase.rawValue) {
            var gate = try active(fixture)
            try gate.acceptFinalConsumed(ACK.values(envelope: fixture.final, phase: phase))
        }
    }
    try reject("token before final consumed") { var gate = try active(fixture); _ = try gate.acceptFirstToken(fixture.token.encoded()) }
    try reject("final boundary before start") {
        var gate = QwenLayerStagePrefillWireLifecycle(agreement: fixture.agreement); try gate.bindFinalBoundary(fixture.final)
    }
    try reject("replayed start") { var gate = try active(fixture); _ = try gate.acceptStart(fixture.start.encoded()) }
    try reject("replayed final boundary") { var gate = try active(fixture); try gate.bindFinalBoundary(fixture.final) }
    try reject("replayed final consumed") {
        var gate = try active(fixture); let ack = ACK.values(envelope: fixture.final, phase: .consumed)
        try gate.acceptFinalConsumed(ack); try gate.acceptFinalConsumed(ack)
    }
    var gate = try active(fixture)
    try gate.acceptFinalConsumed(ACK.values(envelope: fixture.final, phase: .consumed))
    _ = try gate.acceptFirstToken(fixture.token.encoded())
    try reject("replayed token") { _ = try gate.acceptFirstToken(fixture.token.encoded()) }
    guard gate.isFailed, !gate.firstTokenComplete, Set(rejected).count == rejected.count else {
        throw ProbeError("Replay did not poison the one-shot lifecycle or rejection labels repeated")
    }
    return .init(acceptedCases: accepted, rejectedCases: rejected.count, rejectionLabels: rejected)
}
