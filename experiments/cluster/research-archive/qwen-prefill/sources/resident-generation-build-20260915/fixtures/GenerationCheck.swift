import Foundation

struct GenerationCheckResult: Encodable {
    let accepted: [String]
    let rejected: [String]
    let nativeModelExecutionPerformed = false
    let physicalTransportExecuted = false
    let actualResourceAdmissionEstablished = false
}

private final class GenerationChecks {
    var accepted: [String] = []
    var rejected: [String] = []
    func accept(_ label: String, _ body: () throws -> Void) throws {
        try body(); accepted.append(label)
    }
    func reject(_ label: String, _ body: () throws -> Void) throws {
        do { try body() } catch { rejected.append(label); return }
        throw ProbeError("Generation fixture unexpectedly accepted: " + label)
    }
}

private func requireGeneration(_ value: Bool, _ message: String) throws {
    guard value else { throw ProbeError("Generation fixture: " + message) }
}

private func agreement(prompt: Int = 5, chunk: Int = 2, output: Int = 3,
                       epoch: UUID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!) throws -> QwenLayerStageGenerationAgreement {
    let profile = try QwenLayerStageGenerationProfile(identifier: "invented-cpu-fixture", vocabularySize: 16,
        hiddenSize: 4, activationDType: "bfloat16", maximumPromptTokens: max(prompt, 1),
        maximumChunkTokens: max(prompt, chunk), maximumOutputTokens: max(output, 1), maximumContextTokens: max(prompt + output, 1))
    let request = try QwenLayerStageGenerationRequest(profile: profile,
        requestID: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
        promptTokenIDs: Array(repeating: 1, count: prompt), chunkSize: chunk, outputCount: output, stopTokenIDs: [15])
    let source = try QwenLayerStageWireSourceIdentity(sourceConfigurationSHA256: String(repeating: "a", count: 64),
        artifactAggregateSHA256: String(repeating: "b", count: 64), storageCommitmentSHA256: String(repeating: "c", count: 64),
        planFingerprint: String(repeating: "d", count: 64), producerStageFingerprint: String(repeating: "e", count: 64))
    return try .init(request: request, membershipEpoch: epoch, source: source,
        consumerStageFingerprint: String(repeating: "f", count: 64),
        rankBuildSHA256: [String(repeating: "1", count: 64), String(repeating: "2", count: 64)],
        numericalPolicySHA256: String(repeating: "3", count: 64))
}

private func completeFrame(_ control: QwenLayerStageGenerationControl) throws -> QwenLayerStageGenerationBoundaryPacket {
    let expected = try control.beginFrame()
    let payload = Data(repeating: 0, count: expected.byteCount)
    let packet = try QwenLayerStageGenerationBoundaryPacket(expected: expected, payloadSHA256: sha256(payload))
    let received = try QwenLayerStageGenerationBoundaryPacket.decode(packet.encoded(), expected: expected)
    try received.validatePayload(payload)
    for rank in [0, 1] {
        try control.acknowledgeFrame(rank: rank, packet: packet,
            nativeCommittedTokens: expected.frame.tokenOffset + expected.frame.tokenCount)
    }
    return packet
}

private func completePrompt(_ control: QwenLayerStageGenerationControl) throws -> QwenLayerStageGenerationBoundaryPacket {
    var packet = try completeFrame(control)
    while control.committedTokens < control.agreement.request.promptCount { packet = try completeFrame(control) }
    return packet
}

private func makeToken(_ control: QwenLayerStageGenerationControl, _ boundary: QwenLayerStageGenerationBoundaryPacket,
                       tokenID: Int = 2) throws -> QwenLayerStageGenerationTokenPacket {
    try .init(agreement: control.agreement, boundaryFingerprint: boundary.fingerprint,
        previousTokenChainSHA256: control.tokenChainSHA256, ordinal: control.selectedTokenCount,
        committedTokens: control.committedTokens, tokenID: tokenID)
}

private func finishToken(_ control: QwenLayerStageGenerationControl, _ token: QwenLayerStageGenerationTokenPacket,
                         proceed: Bool = true) throws -> QwenLayerStageGenerationDecisionPacket {
    for rank in [1, 0] { try control.acknowledgeToken(rank: rank, packet: token) }
    try requireGeneration(try control.takeCommittedToken() == token.content.tokenID, "selected token changed")
    let decision = try control.decide(continueRequested: proceed)
    for rank in [0, 1] { try control.acknowledgeDecision(rank: rank, packet: decision) }
    return decision
}

private func changed(_ data: Data, _ body: (inout [String: Any]) -> Void) throws -> Data {
    var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    body(&object)
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

func checkQwenLayerStageGeneration() throws -> GenerationCheckResult {
    let checks = GenerationChecks()
    try checks.accept("8192/512/128 commits 143 frames, capacity8320, frontier8319") {
        let a = try agreement(prompt: 8192, chunk: 512, output: 128)
        try requireGeneration(a.request.prefillFrameCount == 16 && a.request.forwardCount == 143
            && a.request.maximumTokens == 8320 && a.request.finalCommittedTokens == 8319, "independent geometry vector")
        let control = QwenLayerStageGenerationControl(agreement: a)
        var packet = try completePrompt(control)
        var histories = Set<String>()
        for ordinal in 0..<128 {
            try requireGeneration(control.committedTokens == 8192 + ordinal, "decode offset")
            let token = try makeToken(control, packet)
            let decision = try finishToken(control, token)
            try requireGeneration(histories.insert(control.tokenChainSHA256).inserted, "token chain repeated")
            if ordinal < 127 {
                try requireGeneration(decision.content.decision == .proceed, "premature terminal")
                packet = try completeFrame(control)
            } else { try requireGeneration(decision.content.decision == .length, "missing length stop") }
        }
        try requireGeneration(control.completedFrames == 143 && control.committedTokens == 8319 && !control.isRetired, "terminal before retirement")
        try control.acknowledgeRetirement(rank: 0, disposition: .retired)
        try requireGeneration(!control.isRetired, "one retirement became pair retirement")
        try control.acknowledgeRetirement(rank: 1, disposition: .retired)
        try requireGeneration(control.isRetired && !control.isFailed, "clean retirement")
    }
    for (prompt, chunk, output) in [(1, 1, 1), (5, 2, 3), (17, 7, 2)] {
        try checks.accept("configurable geometry \(prompt)/\(chunk)/\(output)") {
            let a = try agreement(prompt: prompt, chunk: chunk, output: output)
            var schedule = QwenLayerStageAdmittedSchedule(request: .generation(a.request))
            for sequence in 0..<a.request.forwardCount {
                let expected = try a.request.frame(sequence: sequence)
                let actual = try expected.phase == .prefill
                    ? schedule.admitPrefill(count: expected.tokenCount, offset: expected.tokenOffset, final: expected.finalPromptChunk)
                    : schedule.admitDecode(offset: expected.tokenOffset)
                try requireGeneration(actual == expected, "shared admitted frame differs")
                try schedule.commit(actual)
            }
            try requireGeneration(!schedule.complete, "generation requires explicit finish")
            try schedule.finishGeneration(.length, selectedTokenCount: output, lastTokenID: 2)
            try requireGeneration(schedule.complete && schedule.committedTokens == prompt + output - 1, "shared schedule finish")
        }
    }
    for (name, token, proceed, reason) in [("EOS", 15, true, QwenLayerStageGenerationFinishReason.eos),
                                          ("client stop", 2, false, .clientStop)] {
        try checks.accept("early clean " + name) {
            let control = QwenLayerStageGenerationControl(agreement: try agreement())
            let packet = try completePrompt(control)
            _ = try finishToken(control, makeToken(control, packet, tokenID: token), proceed: proceed)
            try requireGeneration(control.finishReason == reason && !control.isFailed && control.committedTokens == 5, "early finish was failure/decode")
            try control.acknowledgeRetirement(rank: 1, disposition: .retired)
            try control.acknowledgeRetirement(rank: 0, disposition: .retired)
        }
    }
    try checks.accept("cancel before start waits for both retirements") {
        let control = QwenLayerStageGenerationControl(agreement: try agreement())
        let packet = try QwenLayerStageGenerationCancelPacket(agreement: control.agreement, reason: .callerCancelled)
        try control.acceptCancellation(QwenLayerStageGenerationCancelPacket.decode(packet.encoded(), agreement: control.agreement))
        try requireGeneration(control.isFailed && !control.isRetired && control.completedFrames == 0, "cancel claimed work/retirement")
        try control.acknowledgeRetirement(rank: 0, disposition: .retired)
        try control.acknowledgeRetirement(rank: 1, disposition: .fenced)
        try requireGeneration(control.isRetired && control.isFailed, "fence converted to success")
    }
    try checks.accept("membership changes request agreement and initial chain") {
        let a = try agreement(), b = try agreement(epoch: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!)
        try requireGeneration(a.request.fingerprint == b.request.fingerprint && a.fingerprint != b.fingerprint
            && a.initialTokenChainSHA256 != b.initialTokenChainSHA256, "membership was not bound")
    }
    let a = try agreement()
    for output in [0, 4, Int.max] {
        try checks.reject("request output bound \(output)") {
            _ = try QwenLayerStageGenerationRequest(profile: a.request.profile, requestID: UUID(),
                promptTokenIDs: [1], chunkSize: 1, outputCount: output, stopTokenIDs: [])
        }
    }
    for token in [-1, 16] {
        try checks.reject("prompt token \(token)") {
            _ = try QwenLayerStageGenerationRequest(profile: a.request.profile, requestID: UUID(),
                promptTokenIDs: [token], chunkSize: 1, outputCount: 1, stopTokenIDs: [])
        }
    }
    try checks.reject("stop token bounds") {
        _ = try QwenLayerStageGenerationRequest(profile: a.request.profile, requestID: UUID(),
            promptTokenIDs: [1,1,1,1,1], chunkSize: 1, outputCount: 3, stopTokenIDs: [Int.max])
    }
    try checks.reject("context capacity before arithmetic") {
        let profile = try QwenLayerStageGenerationProfile(identifier: "capacity-test", vocabularySize: 16,
            hiddenSize: 4, activationDType: "bfloat16", maximumPromptTokens: 5,
            maximumChunkTokens: 2, maximumOutputTokens: 3, maximumContextTokens: 6)
        _ = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
            promptTokenIDs: [1,1,1,1,1], chunkSize: 2, outputCount: 3, stopTokenIDs: [])
    }
    try checks.reject("legacy output128 remains refused") {
        _ = try QwenLayerStageRequestSpec(requestID: UUID(), promptCount: 5, chunkSize: 2, outputCount: 128)
    }
    try checks.reject("long benchmark still refuses decode") {
        let spec = try QwenLayerStageProfiledPrefillRequestSpec(profile: .longPrefill8KV1,
            requestID: UUID(), batchSize: 1, promptCount: 8192, chunkSize: 512, outputCount: 1)
        let schedule = QwenLayerStageAdmittedSchedule(request: .profiled(spec))
        _ = try schedule.admitDecode(offset: 8192)
    }
    try checks.reject("begin next frame before both native commits poisons") {
        let control = QwenLayerStageGenerationControl(agreement: a)
        let expected = try control.beginFrame()
        let packet = try QwenLayerStageGenerationBoundaryPacket(expected: expected, payloadSHA256: String(repeating: "0", count: 64))
        try control.acknowledgeFrame(rank: 0, packet: packet, nativeCommittedTokens: 2)
        try requireGeneration(control.committedTokens == 0, "one rank advanced common frontier")
        _ = try control.beginFrame()
    }
    try checks.reject("duplicate rank acknowledgement") {
        let control = QwenLayerStageGenerationControl(agreement: a)
        let e = try control.beginFrame(); let packet = try QwenLayerStageGenerationBoundaryPacket(expected: e, payloadSHA256: String(repeating: "0", count: 64))
        try control.acknowledgeFrame(rank: 0, packet: packet, nativeCommittedTokens: 2)
        try control.acknowledgeFrame(rank: 0, packet: packet, nativeCommittedTokens: 2)
    }
    let control = QwenLayerStageGenerationControl(agreement: a)
    let boundary = try completePrompt(control)
    let token = try makeToken(control, boundary)
    try checks.accept("token JSON round trip") {
        let decoded = try QwenLayerStageGenerationTokenPacket.decode(token.encoded(), agreement: a,
            boundaryFingerprint: boundary.fingerprint, previousTokenChainSHA256: control.tokenChainSHA256,
            ordinal: 0, committedTokens: 5)
        try requireGeneration(decoded.content == token.content, "token round trip")
    }
    for (name, mutation) in [
        ("bool token", { (o: inout [String: Any]) in o["tokenID"] = true }),
        ("wrong epoch", { (o: inout [String: Any]) in o["membershipEpoch"] = "wrong" }),
        ("wrong ordinal", { (o: inout [String: Any]) in o["ordinal"] = 1 }),
        ("wrong chain", { (o: inout [String: Any]) in o["previousTokenChainSHA256"] = String(repeating: "0", count: 64) }),
        ("extra field", { (o: inout [String: Any]) in o["extra"] = 1 }),
    ] {
        try checks.reject(name) {
            let raw = try changed(token.encoded(), mutation)
            _ = try QwenLayerStageGenerationTokenPacket.decode(raw, agreement: a, boundaryFingerprint: boundary.fingerprint,
                previousTokenChainSHA256: control.tokenChainSHA256, ordinal: 0, committedTokens: 5)
        }
    }
    for raw in [Data("{\"tokenID\":2,\"tokenID\":2}".utf8), Data("{\"tokenID\":2.0}".utf8), Data(repeating: 32, count: 4097)] {
        try checks.reject("strict JSON/cap \(raw.count)") {
            _ = try QwenLayerStageGenerationTokenPacket.decode(raw, agreement: a, boundaryFingerprint: boundary.fingerprint,
                previousTokenChainSHA256: control.tokenChainSHA256, ordinal: 0, committedTokens: 5)
        }
    }
    try checks.reject("token publication waits for both ACKs") {
        try control.acknowledgeToken(rank: 1, packet: token)
        _ = try control.takeCommittedToken()
    }
    try checks.accept("failure cancellation does not claim retirement") {
        try requireGeneration(control.isFailed && !control.isRetired, "failure did not poison")
        try control.acknowledgeRetirement(rank: 0, disposition: .retired)
        try requireGeneration(!control.isRetired, "one rank retirement")
        try control.acknowledgeRetirement(rank: 1, disposition: .fenced)
    }
    try checks.reject("decision requires both rank acknowledgements before decode") {
        let c = QwenLayerStageGenerationControl(agreement: a)
        let b = try completePrompt(c), t = try makeToken(c, b)
        for rank in [0, 1] { try c.acknowledgeToken(rank: rank, packet: t) }
        _ = try c.takeCommittedToken()
        let decision = try c.decide(continueRequested: true)
        try c.acknowledgeDecision(rank: 0, packet: decision)
        _ = try c.beginFrame()
    }
    try checks.reject("payload mutation") {
        try boundary.validatePayload(Data(repeating: 1, count: boundary.content.expectation.byteCount))
    }
    let ack = try QwenLayerStageGenerationAcknowledgement.values(agreement: a,
        phase: .tokenAccepted, packetFingerprint: token.fingerprint, rank: 0)
    try checks.accept("fixed64 token acknowledgement") {
        try requireGeneration(ack.count == 64, "ACK width changed")
        try QwenLayerStageGenerationAcknowledgement.validate(ack, agreement: a,
            phase: .tokenAccepted, packetFingerprint: token.fingerprint, rank: 0)
    }
    try checks.reject("ACK wrong phase") {
        try QwenLayerStageGenerationAcknowledgement.validate(ack, agreement: a,
            phase: .requestRetired, packetFingerprint: token.fingerprint, rank: 0)
    }
    try checks.reject("ACK wrong rank") {
        try QwenLayerStageGenerationAcknowledgement.validate(ack, agreement: a,
            phase: .tokenAccepted, packetFingerprint: token.fingerprint, rank: 1)
    }
    try checks.reject("cancellation wrong membership") {
        let foreign = try agreement(epoch: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!)
        let packet = try QwenLayerStageGenerationCancelPacket(agreement: foreign, reason: .deadline)
        _ = try QwenLayerStageGenerationCancelPacket.decode(packet.encoded(), agreement: a)
    }
    return .init(accepted: checks.accepted, rejected: checks.rejected)
}
