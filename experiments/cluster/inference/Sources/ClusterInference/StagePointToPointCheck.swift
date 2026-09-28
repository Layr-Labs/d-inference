import Foundation
import MLX

struct StagePointToPointFrameRecord: Encodable, Equatable {
    let frame: QwenLayerStageFrame
    let committedTokens: Int
    let byteCount: Int
    let payloadSHA256: String
    let headerSHA256: String
    let nativeBytesExact = true
}

struct StagePointToPointCaseRecord: Encodable, Equatable {
    let caseID: String
    let dtype: String
    let hiddenSize: Int
    let requestFingerprint: String
    let frames: [StagePointToPointFrameRecord]
    let complete: Bool
}

/// Serialized transport correctness only: there is no model, recurrence, GPU
/// overlap, remote machine or throughput result in this fixed fixture matrix.
func runStagePointToPointCheck(options: Options, check: () throws -> Void) throws {
    try validateStagePointToPointOptions(options)
    let collective = try Collective(transport: options.transport)
    struct Ready: Encodable {
        let kind = "stage_p2p_ready", schemaVersion = 1
        let epoch: String, rank: Int
        let worldSize = 2, transport = "loopback-test", backend = "ring"
    }
    try emitJSON(Ready(epoch: options.epoch!, rank: collective.rank))
    let controls = try checkStagePointToPointControls(collective: collective, check: check)
    let transfer = QwenLayerStageBoundaryTransport(collective: collective)
    let request = try StagePointToPointFixture.request(epoch: options.epoch!)
    var cases: [StagePointToPointCaseRecord] = []
    for dtype in StagePointToPointFixture.nativeDTypes {
        for hidden in StagePointToPointFixture.hiddenSizes {
            let caseID = "\(String(describing: dtype))-h\(hidden)"
            let identity = try StagePointToPointFixture.identity(caseID: caseID)
            var schedule = QwenLayerStageSchedule(request: request)
            var frames: [StagePointToPointFrameRecord] = []
            while !schedule.complete {
                let offset = schedule.committedTokens
                let count = min(request.chunkSize, request.promptCount - offset)
                let frame = try offset < request.promptCount
                    ? schedule.admitPrefill(count: count, offset: offset, final: offset + count == request.promptCount)
                    : schedule.admitDecode(offset: offset)
                let tokens = StagePointToPointFixture.tokens(frame: frame)
                let expected = try QwenLayerStageBoundaryWireExpectation(request: request, frame: frame,
                    tokenIDs: tokens, sourceIdentity: identity, hiddenSize: hidden, nativeDType: String(describing: dtype))
                let payload = try StagePointToPointFixture.bytes(dtype: dtype,
                    count: frame.tokenCount * hidden, shift: frame.sequence)
                let payloadSHA = sha256(payload)
                let headerSHA: String = try autoreleasepool {
                    if collective.rank == 0 {
                        let array = MLXArray(payload, expected.shape, dtype: dtype)
                        eval(array); Stream.gpu.synchronize(); try check()
                        let boundary = QwenLayerStageBoundary(requestFingerprint: request.fingerprint,
                            sourceConfigurationSHA256: identity.sourceConfigurationSHA256,
                            artifactAggregateSHA256: identity.artifactAggregateSHA256,
                            storageCommitmentSHA256: identity.storageCommitmentSHA256,
                            planFingerprint: identity.planFingerprint,
                            producerStageFingerprint: identity.producerStageFingerprint,
                            frame: frame, tokenIDsSHA256: QwenLayerStageBoundary.tokenHash(tokens),
                            payloadSHA256: payloadSHA, array: array)
                        // Simulates stage zero's completed frontier before transfer.
                        try schedule.commit(frame)
                        return try transfer.send(boundary, expected: expected, check: check)
                    } else {
                        let result = try transfer.receive(expected: expected, consume: { boundary in
                            guard boundary.array.asData().data == payload else {
                                throw ProbeError("Native received residual differs from independent fixture bytes")
                            }
                            try check()
                            // Only fixture bookkeeping; no model state is claimed.
                            try schedule.commit(frame)
                        }, check: check)
                        return result.headerSHA256
                    }
                }
                frames.append(.init(frame: frame, committedTokens: schedule.committedTokens,
                    byteCount: payload.count, payloadSHA256: payloadSHA, headerSHA256: headerSHA))
            }
            cases.append(.init(caseID: caseID, dtype: String(describing: dtype), hiddenSize: hidden,
                requestFingerprint: request.fingerprint, frames: frames, complete: schedule.complete))
        }
    }
    try check()
    guard !transfer.isFailed else { throw ProbeError("Point-to-point fixture transport retired unexpectedly") }
    struct Report: Encodable {
        let kind = "stage_p2p_check", schemaVersion = 1
        let epoch: String, rank: Int
        let worldSize = 2, transport = "loopback-test", backend = "ring"
        let passed = true, correctnessOnly = true, throughputMeasurementValid = false
        let modelForwardCompared = false, physicalTransferQualified = false
        let fixtureFingerprint: String
        let controlCases: [StagePointToPointControlRecord]
        let cases: [StagePointToPointCaseRecord]
    }
    try emitJSON(Report(epoch: options.epoch!, rank: collective.rank,
        fixtureFingerprint: StagePointToPointFixture.fingerprint(), controlCases: controls, cases: cases))
}
