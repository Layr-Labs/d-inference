import Foundation

func checkQwenLayerStageProfiledWireRejections(fixture: QwenLayerStageProfiledWireCheckFixture,
                                              checks: inout QwenLayerStageProfiledWireChecks) throws {
    typealias Start = QwenLayerStageProfiledPrefillStartWirePacket
    typealias Boundary = QwenLayerStageProfiledPrefillBoundaryEnvelope
    typealias Token = QwenLayerStageProfiledPrefillFirstTokenWirePacket
    typealias C = QwenLayerStageProfiledWireChecks
    func start(_ bytes: Data) throws { _ = try Start.decode(bytes, expectedAgreement: fixture.agreement) }
    func boundary(_ bytes: Data) throws {
        _ = try Boundary.decode(bytes, agreement: fixture.agreement, expectedFrame: fixture.final.boundary.frame)
    }
    func token(_ bytes: Data) throws {
        _ = try Token.decode(bytes, expectedAgreement: fixture.agreement, finalBoundary: fixture.final)
    }
    for (label, bytes, limit, decode) in [
        ("start", fixture.start.encoded(), Start.maximumEncodedBytes, start),
        ("boundary", fixture.final.encoded(), Boundary.maximumEncodedBytes, boundary),
        ("token", fixture.token.encoded(), Token.maximumEncodedBytes, token),
    ] {
        try checks.reject(label + " unknown field") { try decode(C.changed(bytes) { $0["unknown"] = 1 }) }
        try checks.reject(label + " old v3 flow") { try decode(C.changed(bytes) { $0["flow"] = "bounded_prefill_measurement_v1" }) }
        try checks.reject(label + " old version") { try decode(C.changed(bytes) { $0["version"] = 3 }) }
        try checks.reject(label + " boolean version") { try decode(C.changed(bytes) { $0["version"] = true }) }
        try checks.reject(label + " fraction") { try decode(C.replaced(bytes, "\"version\":4", "\"version\":4.0")) }
        try checks.reject(label + " exponent") { try decode(C.replaced(bytes, "\"version\":4", "\"version\":4e0")) }
        try checks.reject(label + " duplicate") { try decode(Data("{\"version\":4,".utf8) + Data(bytes.dropFirst())) }
        try checks.reject(label + " escaped duplicate") { try decode(Data("{\"\\u0076ersion\":4,".utf8) + Data(bytes.dropFirst())) }
        try checks.reject(label + " oversized") { try decode(bytes + Data(repeating: 32, count: limit + 1 - bytes.count)) }
        try checks.reject(label + " trailing data") { try decode(bytes + Data(" null".utf8)) }
        try checks.reject(label + " invalid UTF8") { try decode(Data([0xff])) }
    }
    for field in ["profile", "profileFingerprint", "epoch", "promptTokenIDsSHA256", "recordedRequestFingerprint", "requestFingerprint", "arithmeticEnvironmentSHA256"] {
        try checks.reject("start changed " + field) {
            try start(C.changed(fixture.start.encoded()) { var d = $0["agreement"] as! [String: Any]; d[field] = "wrong"; $0["agreement"] = d })
        }
    }
    try checks.reject("start missing profile") {
        try start(C.changed(fixture.start.encoded()) { var d = $0["agreement"] as! [String: Any]; d.removeValue(forKey: "profile"); $0["agreement"] = d })
    }
    try checks.reject("start nested boolean count") {
        try start(C.changed(fixture.start.encoded()) { var d = $0["agreement"] as! [String: Any]; d["frameCount"] = true; $0["agreement"] = d })
    }
    try checks.reject("start nested duplicate count") {
        try start(C.replaced(fixture.start.encoded(), "\"agreement\":{", "\"agreement\":{\"frameCount\":16,"))
    }
    for (field, replacement) in [("profile", "wrong"), ("profileFingerprint", String(repeating: "0", count: 64)),
        ("tokenIDsSHA256", String(repeating: "0", count: 64)), ("recordedRequestFingerprint", String(repeating: "0", count: 64))] {
        try checks.reject("inner changed " + field) {
            try boundary(C.changed(fixture.final.encoded()) { var d = $0["boundary"] as! [String: Any]; d[field] = replacement; $0["boundary"] = d })
        }
    }
    for (field, value) in [("sequence", -1), ("sequence", 128), ("tokenOffset", 8192), ("tokenOffset", Int.max),
                            ("tokenCount", 0), ("tokenCount", 513)] {
        try checks.reject("inner invalid " + field + " " + String(value)) {
            try boundary(C.changed(fixture.final.encoded()) {
                var d = $0["boundary"] as! [String: Any]; var frame = d["frame"] as! [String: Any]
                frame[field] = value; d["frame"] = frame; $0["boundary"] = d
            })
        }
    }
    try checks.reject("inner legacy version") {
        try boundary(C.changed(fixture.final.encoded()) { var d = $0["boundary"] as! [String: Any]; d["version"] = 1; $0["boundary"] = d })
    }
    try checks.reject("inner byte count boolean") {
        try boundary(C.changed(fixture.final.encoded()) { var d = $0["boundary"] as! [String: Any]; d["byteCount"] = true; $0["boundary"] = d })
    }
    try checks.reject("inner byte count fraction") {
        try boundary(C.replaced(fixture.final.encoded(), "\"byteCount\":131072", "\"byteCount\":131072.0"))
    }
    try checks.reject("inner frame duplicate") {
        try boundary(C.replaced(fixture.final.encoded(), "\"frame\":{", "\"frame\":{\"sequence\":15,"))
    }
    try checks.reject("inner decode phase") {
        try boundary(C.replaced(fixture.final.encoded(), "\"phase\":\"prefill\"", "\"phase\":\"decode\""))
    }
    try checks.reject("valid frame received at wrong local frontier") {
        _ = try Boundary.decode(fixture.first.encoded(), agreement: fixture.agreement, expectedFrame: fixture.final.boundary.frame)
    }
    try checks.reject("off-grid local expected frame") {
        _ = try fixture.agreement.boundaryExpectation(for: .init(sequence: 0, phase: .prefill,
            tokenOffset: 1, tokenCount: 512, finalPromptChunk: false))
    }
    try checks.reject("hidden width beyond local profile") { _ = try QwenLayerStageProfiledWireCheckFixture(hiddenSize: 8193) }
    try checks.reject("8192 chunk32 exceeds 128 frames") { _ = try QwenLayerStageProfiledWireCheckFixture(chunkSize: 32) }
    for field in ["profile", "profileFingerprint", "agreementFingerprint", "finalBoundaryEnvelopeFingerprint",
                  "finalBoundaryWireBytesSHA256", "recordedRequestFingerprint", "logitsDType", "selectionPolicy"] {
        try checks.reject("token changed " + field) { try token(C.changed(fixture.token.encoded()) { $0[field] = "wrong" }) }
    }
    for field in ["committedTokens", "vocabularySize", "tokenOrdinal", "tokenID"] {
        try checks.reject("token boolean " + field) { try token(C.changed(fixture.token.encoded()) { $0[field] = true }) }
    }
    try checks.reject("token outside vocabulary") { try token(C.changed(fixture.token.encoded()) { $0["tokenID"] = 256 }) }
    try checks.reject("token nonfinite flag") { try token(C.changed(fixture.token.encoded()) { $0["allLogitsFinite"] = false }) }
    try checks.reject("token nested fractional offset") {
        try token(C.replaced(fixture.token.encoded(), "\"tokenOffset\":7680", "\"tokenOffset\":7680.0"))
    }
    let others = [
        ("policy", try QwenLayerStageProfiledWireCheckFixture(policy: .promptLookaheadOne)),
        ("source", try QwenLayerStageProfiledWireCheckFixture(artifactDigit: "9")),
        ("history", try QwenLayerStageProfiledWireCheckFixture(tokenShift: 1)),
        ("request", try QwenLayerStageProfiledWireCheckFixture(requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)),
        ("arithmetic environment", try QwenLayerStageProfiledWireCheckFixture(arithmeticDigit: "6")),
    ]
    for (name, other) in others {
        guard fixture.agreement.fingerprint != other.agreement.fingerprint else { throw ProbeError("Agreement omitted " + name) }
        try checks.reject("start " + name + " replay") { _ = try Start.decode(fixture.start.encoded(), expectedAgreement: other.agreement) }
        try checks.reject("boundary " + name + " replay") { _ = try Boundary.decode(fixture.final.encoded(), agreement: other.agreement, expectedFrame: other.final.boundary.frame) }
        try checks.reject("token " + name + " replay") { _ = try Token.decode(fixture.token.encoded(), expectedAgreement: other.agreement, finalBoundary: other.final) }
    }
    try checks.reject("actual token source mismatch") { _ = try Token(selection: others[1].1.selection, agreement: fixture.agreement, finalBoundary: fixture.final) }
    try checks.reject("actual token history mismatch") { _ = try Token(selection: others[2].1.selection, agreement: fixture.agreement, finalBoundary: fixture.final) }
    try checks.reject("token based on nonfinal boundary") { _ = try Token(selection: fixture.selection, agreement: fixture.agreement, finalBoundary: fixture.first) }
}
