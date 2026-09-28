import Foundation

func checkQwenLayerStageProfiledWireLegacyAndBytes(fixture: QwenLayerStageProfiledWireCheckFixture,
                                                checks: inout QwenLayerStageProfiledWireChecks) throws {
    typealias Start = QwenLayerStageProfiledPrefillStartWirePacket
    typealias Boundary = QwenLayerStageProfiledPrefillBoundaryEnvelope
    typealias Token = QwenLayerStageProfiledPrefillFirstTokenWirePacket
    typealias ACK = QwenLayerStageProfiledPrefillBoundaryAcknowledgement
    typealias PostStop = QwenLayerStageProfiledPrefillPostStopAcknowledgement
    let spacedStart = try Start.decode(Data(" \n".utf8) + fixture.start.encoded(), expectedAgreement: fixture.agreement)
    let spacedBoundary = try Boundary.decode(Data(" \n".utf8) + fixture.final.encoded() + Data("\t".utf8),
        agreement: fixture.agreement, expectedFrame: fixture.final.boundary.frame)
    let spacedToken = try Token.decode(Data(" ".utf8) + fixture.token.encoded(),
        expectedAgreement: fixture.agreement, finalBoundary: fixture.final)
    guard spacedStart.encoded() != fixture.start.encoded(), spacedStart.fingerprint != fixture.start.fingerprint,
          spacedStart.wireBytesSHA256 != fixture.start.wireBytesSHA256,
          spacedBoundary.encoded() != fixture.final.encoded(), spacedBoundary.fingerprint != fixture.final.fingerprint,
          spacedBoundary.wireBytesSHA256 != fixture.final.wireBytesSHA256,
          spacedToken.encoded() != fixture.token.encoded(), spacedToken.fingerprint != fixture.token.fingerprint,
          spacedToken.wireBytesSHA256 != fixture.token.wireBytesSHA256 else {
        throw ProbeError("Profiled raw-byte/domain identities normalized an accepted packet")
    }
    checks.accepted += 1
    for phase in ACK.Phase.allCases {
        let values = ACK.values(envelope: fixture.final, phase: phase)
        guard values.count == ACK.elements, ACK.byteCount == values.count * 4 else { throw ProbeError("Profiled ACK geometry differs") }
        try ACK.validate(values, envelope: fixture.final, phase: phase)
        try checks.reject("ACK changed envelope bytes " + phase.rawValue) {
            try ACK.validate(values, envelope: spacedBoundary, phase: phase)
        }
    }
    try checks.reject("token changed final envelope bytes") {
        _ = try Token.decode(fixture.token.encoded(), expectedAgreement: fixture.agreement, finalBoundary: spacedBoundary)
    }
    try checks.reject("post-stop changed token bytes") {
        try PostStop.validate(PostStop.values(token: fixture.token), token: spacedToken)
    }
    let legacy = try QwenLayerStagePrefillWireCheckFixture()
    let short = try QwenLayerStageProfiledWireCheckFixture(promptCount: 65, chunkSize: 32)
    let legacyExpected = try legacy.agreement.boundaryExpectation(for: legacy.final.boundary.frame)
    let lookahead = try QwenLayerStageLookaheadWireEnvelope(boundary: legacy.final.boundary, expected: legacyExpected)
    guard short.agreement.request.request.fingerprint != legacy.agreement.request.request.fingerprint,
          short.agreement.request.fingerprint != legacy.agreement.request.fingerprint else {
        throw ProbeError("Small profiled requests collided with legacy request/history identity")
    }
    try checks.reject("legacy v1 header into profiled inner v2") {
        _ = try QwenLayerStageProfiledBoundaryWireHeader.decode(legacy.final.boundary.encoded(),
            expected: short.agreement.boundaryExpectation(for: short.final.boundary.frame))
    }
    try checks.reject("profiled inner v2 into legacy v1") {
        _ = try QwenLayerStageBoundaryWireHeader.decode(short.final.boundary.encoded(), expected: legacyExpected)
    }
    for (label, bytes) in [("v1", try legacy.final.boundary.encoded()), ("v2", lookahead.encoded()), ("v3", legacy.final.encoded())] {
        try checks.reject("legacy " + label + " into profiled v4") {
            _ = try Boundary.decode(bytes, agreement: short.agreement, expectedFrame: short.final.boundary.frame)
        }
    }
    try checks.reject("profiled v4 into legacy v2") { _ = try QwenLayerStageLookaheadWireEnvelope.decode(short.final.encoded(), expected: legacyExpected) }
    try checks.reject("profiled v4 into legacy v3") { _ = try QwenLayerStagePrefillBoundaryEnvelope.decode(short.final.encoded(), agreement: legacy.agreement, expectedFrame: legacy.final.boundary.frame) }
    try checks.reject("legacy start into profiled") { _ = try Start.decode(legacy.start.encoded(), expectedAgreement: short.agreement) }
    try checks.reject("profiled start into legacy") { _ = try QwenLayerStagePrefillStartWirePacket.decode(short.start.encoded(), expectedAgreement: legacy.agreement) }
    try checks.reject("legacy token into profiled") { _ = try Token.decode(legacy.token.encoded(), expectedAgreement: short.agreement, finalBoundary: short.final) }
    try checks.reject("profiled token into legacy") { _ = try QwenLayerStagePrefillFirstTokenWirePacket.decode(short.token.encoded(), expectedAgreement: legacy.agreement, finalBoundary: legacy.final) }
    try checks.reject("legacy ACK into profiled") {
        try ACK.validate(QwenLayerStagePrefillBoundaryAcknowledgement.values(envelope: legacy.final, phase: .consumed),
            envelope: short.final, phase: .consumed)
    }
    try checks.reject("legacy post-stop into profiled") {
        try PostStop.validate(QwenLayerStagePrefillPostStopAcknowledgement.values(token: legacy.token), token: short.token)
    }
    func started() throws -> QwenLayerStageProfiledPrefillWireLifecycle {
        var gate = QwenLayerStageProfiledPrefillWireLifecycle(agreement: fixture.agreement)
        _ = try gate.acceptStart(fixture.start.encoded()); try gate.bindFinalBoundary(fixture.final)
        return gate
    }
    try checks.reject("final boundary before start") {
        var gate = QwenLayerStageProfiledPrefillWireLifecycle(agreement: fixture.agreement); try gate.bindFinalBoundary(fixture.final)
    }
    try checks.reject("replayed start") { var gate = try started(); _ = try gate.acceptStart(fixture.start.encoded()) }
    try checks.reject("replayed final boundary") { var gate = try started(); try gate.bindFinalBoundary(fixture.final) }
    try checks.reject("token before final consumed") { var gate = try started(); _ = try gate.acceptFirstToken(fixture.token.encoded()) }
    for phase in [ACK.Phase.ready, .received] {
        try checks.reject("wrong final ACK phase " + phase.rawValue) {
            var gate = try started(); try gate.acceptFinalConsumed(ACK.values(envelope: fixture.final, phase: phase))
        }
    }
    try checks.reject("replayed final consumed") {
        var gate = try started(); let values = ACK.values(envelope: fixture.final, phase: .consumed)
        try gate.acceptFinalConsumed(values); try gate.acceptFinalConsumed(values)
    }
    var gate = try started()
    try gate.acceptFinalConsumed(ACK.values(envelope: fixture.final, phase: .consumed))
    _ = try gate.acceptFirstToken(fixture.token.encoded())
    try checks.reject("replayed selected token") { _ = try gate.acceptFirstToken(fixture.token.encoded()) }
    guard gate.isFailed, !gate.firstTokenComplete else { throw ProbeError("Profiled replay failed to poison lifecycle") }
    var released = QwenLayerStageProfiledPrefillPostStopGate(token: fixture.token)
    let release = PostStop.values(token: fixture.token)
    try released.accept(release)
    try checks.reject("replayed post-stop") { try released.accept(release) }
    guard released.isFailed else { throw ProbeError("Profiled repeated post-stop release did not poison its gate") }
    try checks.reject("retired gate reused") {
        var retired = QwenLayerStageProfiledPrefillWireLifecycle(agreement: fixture.agreement)
        retired.retire(); _ = try retired.acceptStart(fixture.start.encoded())
    }
}
