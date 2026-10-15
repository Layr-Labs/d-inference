import Foundation
import MLX

/// One residual in flight. All native IO uses the existing completed Collective
/// helpers. A failure poisons this transport; the owner must fence both ranks.
final class QwenLayerStageGenerationTransport {
    let agreement: QwenLayerStageGenerationAgreement
    let collective: Collective
    private(set) var isFailed = false
    private var inOperation = false
    var rank: Int { collective.rank }

    init(agreement: QwenLayerStageGenerationAgreement, collective: Collective) throws {
        guard collective.size == 2, (0...1).contains(collective.rank) else {
            throw ProbeError("Generation transport requires two initialized ranks")
        }
        self.agreement = agreement; self.collective = collective
    }
    func retire() { isFailed = true }

    func sendBoundary(_ boundary: QwenLayerStageBoundary,
                      packet: QwenLayerStageGenerationBoundaryPacket,
                      check: () throws -> Void) throws {
        try operation {
            guard rank == 0 else { throw ProbeError("Only generation rank0 sends residuals") }
            let expected = packet.content.expectation, source = agreement.descriptor
            guard boundary.requestFingerprint == expected.requestFingerprint,
                  boundary.sourceConfigurationSHA256 == source.sourceConfigurationSHA256,
                  boundary.artifactAggregateSHA256 == source.artifactAggregateSHA256,
                  boundary.storageCommitmentSHA256 == source.storageCommitmentSHA256,
                  boundary.planFingerprint == source.planFingerprint,
                  boundary.producerStageFingerprint == source.stageFingerprints[0],
                  boundary.frame == expected.frame, boundary.tokenIDsSHA256 == expected.tokenIDsSHA256,
                  boundary.payloadSHA256 == packet.content.payloadSHA256,
                  boundary.array.shape == expected.shape,
                  String(describing: boundary.array.dtype) == expected.dtype,
                  boundary.array.nbytes == expected.byteCount else {
                throw ProbeError("Generation residual lost its actual source/request/layout identity")
            }
            try boundary.validateOwnedArray(tokens: expected.frame.tokenCount,
                hidden: agreement.request.profile.hiddenSize, dtype: boundary.array.dtype)
            try check()
            try sendData(packet.encoded(), maximumBytes: QwenLayerStageGenerationBoundaryPacket.maximumEncodedBytes, check: check)
            try receiveAck(.boundaryReady, packet.fingerprint, from: 1, check: check)
            _ = try collective.sendCompleted(boundary.array, to: 1, maximumBytes: expected.byteCount, check: check)
            try receiveAck(.boundaryConsumed, packet.fingerprint, from: 1, check: check)
        }
    }

    func receiveBoundary<T>(expected: QwenLayerStageGenerationBoundaryExpectation,
                            consume: (QwenLayerStageBoundary, QwenLayerStageGenerationBoundaryPacket) throws -> T,
                            check: () throws -> Void) throws -> (T, QwenLayerStageGenerationBoundaryPacket) {
        try operation {
            guard rank == 1 else { throw ProbeError("Only generation rank1 receives residuals") }
            let packet = try QwenLayerStageGenerationBoundaryPacket.decode(
                receiveData(maximumBytes: QwenLayerStageGenerationBoundaryPacket.maximumEncodedBytes, check: check), expected: expected)
            try sendAck(.boundaryReady, packet.fingerprint, check: check)
            let dtype: DType
            switch expected.dtype {
            case "float16": dtype = .float16
            case "bfloat16": dtype = .bfloat16
            case "float32": dtype = .float32
            default: throw ProbeError("Generation receive dtype unsupported")
            }
            let array = try collective.receiveCompleted(shape: expected.shape, dtype: dtype, from: 0,
                maximumBytes: expected.byteCount, check: check)
            let source = agreement.descriptor
            let boundary = QwenLayerStageBoundary(requestFingerprint: expected.requestFingerprint,
                sourceConfigurationSHA256: source.sourceConfigurationSHA256,
                artifactAggregateSHA256: source.artifactAggregateSHA256,
                storageCommitmentSHA256: source.storageCommitmentSHA256, planFingerprint: source.planFingerprint,
                producerStageFingerprint: source.stageFingerprints[0], frame: expected.frame,
                tokenIDsSHA256: expected.tokenIDsSHA256, payloadSHA256: packet.content.payloadSHA256, array: array)
            try boundary.validateOwnedArray(tokens: expected.frame.tokenCount,
                hidden: agreement.request.profile.hiddenSize, dtype: dtype)
            try check()
            let result = try consume(boundary, packet)
            try check()
            try sendAck(.boundaryConsumed, packet.fingerprint, check: check)
            return (result, packet)
        }
    }

    func sendToken(_ packet: QwenLayerStageGenerationTokenPacket, check: () throws -> Void) throws {
        try operation {
            guard rank == 1 else { throw ProbeError("Only generation rank1 selects target tokens") }
            try sendData(packet.encoded(), maximumBytes: 4096, check: check)
            try receiveAck(.tokenAccepted, packet.fingerprint, from: 0, check: check)
        }
    }
    func receiveToken(boundaryFingerprint: String, previousChain: String, ordinal: Int,
                      committedTokens: Int, check: () throws -> Void) throws -> QwenLayerStageGenerationTokenPacket {
        try operation {
            guard rank == 0 else { throw ProbeError("Only generation rank0 receives target tokens") }
            return try .decode(receiveData(maximumBytes: 4096, check: check), agreement: agreement,
                boundaryFingerprint: boundaryFingerprint, previousTokenChainSHA256: previousChain,
                ordinal: ordinal, committedTokens: committedTokens)
        }
    }
    func acknowledgeToken(_ packet: QwenLayerStageGenerationTokenPacket, check: () throws -> Void) throws {
        try operation {
            guard rank == 0 else { throw ProbeError("Only generation rank0 acknowledges returned tokens") }
            try sendAck(.tokenAccepted, packet.fingerprint, check: check)
        }
    }
    func sendDecision(_ packet: QwenLayerStageGenerationDecisionPacket, check: () throws -> Void) throws {
        try operation {
            guard rank == 0 else { throw ProbeError("Only request owner sends generation decisions") }
            try sendData(packet.encoded(), maximumBytes: 4096, check: check)
            try receiveAck(.decisionAccepted, packet.fingerprint, from: 1, check: check)
        }
    }
    func receiveDecision(token: QwenLayerStageGenerationTokenPacket,
                         check: () throws -> Void) throws -> QwenLayerStageGenerationDecisionPacket {
        try operation {
            guard rank == 1 else { throw ProbeError("Only generation rank1 receives decisions") }
            return try .decode(receiveData(maximumBytes: 4096, check: check), agreement: agreement, token: token)
        }
    }
    func acknowledgeDecision(_ packet: QwenLayerStageGenerationDecisionPacket, check: () throws -> Void) throws {
        try operation {
            guard rank == 1 else { throw ProbeError("Only generation rank1 acknowledges decisions") }
            try sendAck(.decisionAccepted, packet.fingerprint, check: check)
        }
    }

    /// Both ranks send before either rejects a mismatch, preserving the shared
    /// readiness fix's completion order. Call only after native state retirement.
    func exchangeRetirement(decision: QwenLayerStageGenerationDecisionPacket, check: () throws -> Void) throws {
        try operation {
            let actual: [Int32]
            if rank == 0 {
                try sendAck(.requestRetired, decision.fingerprint, check: check)
                actual = try receiveAckValues(check: check)
            } else {
                actual = try receiveAckValues(check: check)
                try sendAck(.requestRetired, decision.fingerprint, check: check)
            }
            try QwenLayerStageGenerationAcknowledgement.validate(actual, agreement: agreement,
                phase: .requestRetired, packetFingerprint: decision.fingerprint, rank: 1 - rank)
        }
    }

    private func sendData(_ data: Data, maximumBytes: Int, check: () throws -> Void) throws {
        guard !data.isEmpty, data.count <= maximumBytes else { throw ProbeError("Generation send control byte cap") }
        _ = try collective.sendCompleted(MLXArray([UInt32(data.count)]), to: 1 - rank, maximumBytes: 4, check: check)
        _ = try collective.sendCompleted(MLXArray(Array(data)), to: 1 - rank, maximumBytes: maximumBytes, check: check)
    }
    private func receiveData(maximumBytes: Int, check: () throws -> Void) throws -> Data {
        let length = try collective.receiveCompleted(shape: [1], dtype: .uint32, from: 1 - rank,
            maximumBytes: 4, check: check).item(UInt32.self)
        guard length > 0, Int(length) <= maximumBytes else { throw ProbeError("Generation received control byte cap") }
        let data = try collective.receiveCompleted(shape: [Int(length)], dtype: .uint8, from: 1 - rank,
            maximumBytes: maximumBytes, check: check).asData().data
        try check(); return data
    }
    private func sendAck(_ phase: QwenLayerStageGenerationAcknowledgement.Phase, _ fingerprint: String,
                         check: () throws -> Void) throws {
        let values = try QwenLayerStageGenerationAcknowledgement.values(agreement: agreement,
            phase: phase, packetFingerprint: fingerprint, rank: rank)
        _ = try collective.sendCompleted(MLXArray(values), to: 1 - rank, maximumBytes: 256, check: check)
    }
    private func receiveAckValues(check: () throws -> Void) throws -> [Int32] {
        let actual = try collective.receiveCompleted(shape: [64], dtype: .int32, from: 1 - rank,
            maximumBytes: 256, check: check).asArray(Int32.self)
        try check(); return actual
    }
    private func receiveAck(_ phase: QwenLayerStageGenerationAcknowledgement.Phase, _ fingerprint: String,
                            from peer: Int, check: () throws -> Void) throws {
        try QwenLayerStageGenerationAcknowledgement.validate(receiveAckValues(check: check), agreement: agreement,
            phase: phase, packetFingerprint: fingerprint, rank: peer)
    }
    private func operation<T>(_ body: () throws -> T) throws -> T {
        guard !inOperation, !isFailed else { isFailed = true; throw ProbeError("Generation transport is failed or reentered") }
        inOperation = true; defer { inOperation = false }
        do { let result = try body(); guard !isFailed else { throw ProbeError("Generation transport was poisoned") }; return result }
        catch { isFailed = true; throw error }
    }
}
