import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
import Foundation
import MLX

/// One residual in flight. All native IO uses the existing completed Collective
/// helpers. A failure poisons this transport; the owner must fence both ranks.
///
/// A stop (D6) does not: with `abort`, each message this rank owes its peer
/// is first a stop point. When the latch is set the message's own record
/// carries the stop marker instead (`QwenStageAbortWire`), the peer answers
/// with one confirmation, and `QwenStageAborted` is thrown with the record
/// streams still aligned. Every receive recognizes the peer's marker the same
/// way, confirms it and throws. Both ranks then retire the request together
/// (`exchangeAbortRetirement`) and the collectives serve the next request.
final class QwenLayerStageGenerationTransport {
    let agreement: QwenLayerStageGenerationAgreement
    let collective: Collective
    private(set) var isFailed = false
    /// The request ended on both ranks alone; only the abort's retirement exchange remains.
    private(set) var isAborted = false
    private let abort: QwenStageAbort?
    private var inOperation = false
    struct BoundaryTicket {
        let packet: QwenLayerStageGenerationBoundaryPacket
        fileprivate init(packet: QwenLayerStageGenerationBoundaryPacket) { self.packet = packet }
    }
    private var pendingBoundaryFingerprint: String?
    var rank: Int { collective.rank }

    /// The record each transfer is on a keyed data plane (S16): its kind, this
    /// request, this agreement, and a label both ranks derive locally.
    private func record(_ type: ClusterRecordType, _ label: String) -> CollectiveRecordScope {
        .request(type, requestID: agreement.request.requestID, agreementFingerprint: agreement.fingerprint, label)
    }

    init(agreement: QwenLayerStageGenerationAgreement, collective: Collective, abort: QwenStageAbort? = nil) throws {
        guard collective.size == 2, (0...1).contains(collective.rank) else {
            throw ProbeError("Generation transport requires two initialized ranks")
        }
        guard abort.map({ $0.rank == collective.rank }) ?? true else {
            throw ProbeError("Generation stop latch belongs to another rank")
        }
        self.agreement = agreement; self.collective = collective; self.abort = abort
    }

    // MARK: Stop (D6)

    /// A stop point a driver takes before a forward whose result is the next
    /// message it owes (rank 0's boundary at a frame's start): when the latch
    /// is set, the marker goes in that message's slot and the forward is skipped.
    func stopIfLatched(owing slot: QwenStageAbortSlot, check: () throws -> Void) throws {
        try operation { try stop(at: slot, check: check) }
    }

    /// The latch alone, without sending: a driver skips work it would only
    /// throw away (rank 0's lookahead chunk while a boundary is still owed).
    func stopLatched() throws -> Bool { try abort?.poll() ?? false }

    /// Both ranks confirm they retired an aborted request, as a clean finish's
    /// retirement exchange does, bound to the abort: rank 0 sends first.
    func exchangeAbortRetirement(_ aborted: QwenStageAborted, check: () throws -> Void) throws {
        guard isAborted, !isFailed, !inOperation else {
            isFailed = true; throw ProbeError("Generation abort retirement needs an aborted transport")
        }
        inOperation = true; defer { inOperation = false }
        do {
            let fingerprint = try QwenStageAbortWire.retirementFingerprint(agreement: agreement, abort: aborted.abort)
            let actual: [Int32]
            if rank == 0 {
                try sendAck(.requestRetired, fingerprint, check: check)
                actual = try receiveAckValues(type: .requestRetired, check: check)
            } else {
                actual = try receiveAckValues(type: .requestRetired, check: check)
                try sendAck(.requestRetired, fingerprint, check: check)
            }
            try QwenLayerStageGenerationAcknowledgement.validate(actual, agreement: agreement,
                phase: .requestRetired, packetFingerprint: fingerprint, rank: 1 - rank)
        } catch { isFailed = true; throw error }
    }

    /// When the latch is set: the marker in `slot`, then the peer's confirmation.
    private func stop(at slot: QwenStageAbortSlot, check: () throws -> Void) throws {
        guard let abort, try abort.poll(), let value = abort.latched else { return }
        switch slot {
        case .data(let type, let label):
            _ = try collective.sendCompleted(MLXArray([QwenStageAbortWire.lengthMarker]), to: 1 - rank, maximumBytes: 4,
                scope: record(type, label).part("length"), check: check)
        case .acknowledgement:
            _ = try collective.sendCompleted(MLXArray(try QwenStageAbortWire.acknowledgement(agreement: agreement, rank: rank)),
                to: 1 - rank, maximumBytes: 256, scope: record(.acknowledgement, "ack"), check: check)
        case .frame(let frameBytes, let type, let label):
            try sendFrame(try QwenStageAbortWire.packet(agreement: agreement, abort: value), frameBytes: frameBytes,
                record: record(type, label), check: check)
        case .compactBoundary:
            try sendFrame(try QwenStageAbortWire.packet(agreement: agreement, abort: value), frameBytes: compactBoundaryFrameBytes,
                record: record(.residualPayload, "compact-boundary"), check: check)
        }
        let confirmation = try collective.receiveCompleted(shape: [64], dtype: .int32, from: 1 - rank, maximumBytes: 256,
            scope: record(.acknowledgement, "abort"), check: check).asArray(Int32.self)
        guard confirmation == (try QwenStageAbortWire.confirmation(agreement: agreement, rank: 1 - rank)) else {
            throw ProbeError("Generation peer did not confirm this rank's stop")
        }
        throw QwenStageAborted(abort: value, local: true)
    }

    /// The peer stopped in the slot this rank was receiving: one confirmation, then the abort.
    private func peerStopped(_ value: ClusterWorkerAbort, check: () throws -> Void) throws -> Never {
        guard value.rank == 1 - rank else { throw ProbeError("Generation stop marker names this rank") }
        _ = try collective.sendCompleted(MLXArray(try QwenStageAbortWire.confirmation(agreement: agreement, rank: rank)),
            to: 1 - rank, maximumBytes: 256, scope: record(.acknowledgement, "abort"), check: check)
        throw QwenStageAborted(abort: value, local: false)
    }
    func retire() { isFailed = true; pendingBoundaryFingerprint = nil }

    func sendBoundary(_ boundary: QwenLayerStageBoundary,
                      packet: QwenLayerStageGenerationBoundaryPacket,
                      check: () throws -> Void) throws {
        let ticket = try sendBoundaryUntilSent(boundary, packet: packet, check: check)
        try finishBoundaryConsumed(ticket, check: check)
    }

    /// Only completed send credit: no claim that the peer validated/consumed it.
    /// Caller releases the original wrapper before preparing one next chunk.
    func sendBoundaryUntilSent(_ boundary: QwenLayerStageBoundary,
                               packet: QwenLayerStageGenerationBoundaryPacket,
                               check: () throws -> Void) throws -> BoundaryTicket {
        try operation {
            guard rank == 0 else { throw ProbeError("Only generation rank0 sends residuals") }
            try stop(at: .boundaryHeader, check: check)
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
                hidden: agreement.request.profile.hiddenSize, dtype: boundary.array.dtype,
                residualStreams: agreement.request.profile.residualStreams ?? 1)
            try check()
            try sendData(packet.encoded(), maximumBytes: QwenLayerStageGenerationBoundaryPacket.maximumEncodedBytes,
                record: record(.residualHeader, "boundary"), check: check)
            try receiveAck(.boundaryReady, packet.fingerprint, from: 1, check: check)
            _ = try collective.sendCompleted(boundary.array, to: 1, maximumBytes: expected.byteCount,
                scope: record(.residualPayload, packet.fingerprint), check: check)
            pendingBoundaryFingerprint = packet.fingerprint
            return BoundaryTicket(packet: packet)
        }
    }

    func finishBoundaryConsumed(_ ticket: BoundaryTicket, check: () throws -> Void) throws {
        try operation(allowPendingBoundary: true) {
            guard rank == 0, pendingBoundaryFingerprint == ticket.packet.fingerprint else {
                throw ProbeError("Generation consumed ticket differs or was replayed")
            }
            try receiveAck(.boundaryConsumed, ticket.packet.fingerprint, from: 1, check: check)
            pendingBoundaryFingerprint = nil
        }
    }

    func receiveBoundary<T>(expected: QwenLayerStageGenerationBoundaryExpectation,
                            consume: (QwenLayerStageBoundary, QwenLayerStageGenerationBoundaryPacket) throws -> T,
                            check: () throws -> Void) throws -> (T, QwenLayerStageGenerationBoundaryPacket) {
        try operation {
            guard rank == 1 else { throw ProbeError("Only generation rank1 receives residuals") }
            let packet = try QwenLayerStageGenerationBoundaryPacket.decode(
                receiveData(maximumBytes: QwenLayerStageGenerationBoundaryPacket.maximumEncodedBytes,
                    record: record(.residualHeader, "boundary"), check: check), expected: expected)
            try stop(at: .acknowledgement, check: check)
            try sendAck(.boundaryReady, packet.fingerprint, check: check)
            let dtype: DType
            switch expected.dtype {
            case "float16": dtype = .float16
            case "bfloat16": dtype = .bfloat16
            case "float32": dtype = .float32
            default: throw ProbeError("Generation receive dtype unsupported")
            }
            let array = try collective.receiveCompleted(shape: expected.shape, dtype: dtype, from: 0,
                maximumBytes: expected.byteCount, scope: record(.residualPayload, packet.fingerprint), check: check)
            let source = agreement.descriptor
            let boundary = QwenLayerStageBoundary(requestFingerprint: expected.requestFingerprint,
                sourceConfigurationSHA256: source.sourceConfigurationSHA256,
                artifactAggregateSHA256: source.artifactAggregateSHA256,
                storageCommitmentSHA256: source.storageCommitmentSHA256, planFingerprint: source.planFingerprint,
                producerStageFingerprint: source.stageFingerprints[0], frame: expected.frame,
                tokenIDsSHA256: expected.tokenIDsSHA256, payloadSHA256: packet.content.payloadSHA256, array: array)
            try boundary.validateOwnedArray(tokens: expected.frame.tokenCount,
                hidden: agreement.request.profile.hiddenSize, dtype: dtype,
                residualStreams: agreement.request.profile.residualStreams ?? 1)
            try check()
            // Stopping now skips this rank's forward: the marker is the consumed acknowledgement.
            try stop(at: .acknowledgement, check: check)
            let result = try consume(boundary, packet)
            try check()
            try sendAck(.boundaryConsumed, packet.fingerprint, check: check)
            return (result, packet)
        }
    }

    func sendToken(_ packet: QwenLayerStageGenerationTokenPacket, check: () throws -> Void) throws {
        try operation {
            guard rank == 1 else { throw ProbeError("Only generation rank1 selects target tokens") }
            try stop(at: .data(.targetToken, "token"), check: check)
            try sendData(packet.encoded(), maximumBytes: 4096, record: record(.targetToken, "token"), check: check)
            try receiveAck(.tokenAccepted, packet.fingerprint, from: 0, check: check)
        }
    }
    func receiveToken(boundaryFingerprint: String, previousChain: String, ordinal: Int,
                      committedTokens: Int, check: () throws -> Void) throws -> QwenLayerStageGenerationTokenPacket {
        try operation {
            guard rank == 0 else { throw ProbeError("Only generation rank0 receives target tokens") }
            return try .decode(receiveData(maximumBytes: 4096, record: record(.targetToken, "token"), check: check),
                agreement: agreement, boundaryFingerprint: boundaryFingerprint, previousTokenChainSHA256: previousChain,
                ordinal: ordinal, committedTokens: committedTokens)
        }
    }
    func acknowledgeToken(_ packet: QwenLayerStageGenerationTokenPacket, check: () throws -> Void) throws {
        try operation {
            guard rank == 0 else { throw ProbeError("Only generation rank0 acknowledges returned tokens") }
            try stop(at: .acknowledgement, check: check)
            try sendAck(.tokenAccepted, packet.fingerprint, check: check)
        }
    }
    func sendDecision(_ packet: QwenLayerStageGenerationDecisionPacket, check: () throws -> Void) throws {
        try operation {
            guard rank == 0 else { throw ProbeError("Only request owner sends generation decisions") }
            // A decision that ends the request anyway is sent as it is.
            if packet.content.decision == .proceed { try stop(at: .data(.generationDecision, "decision"), check: check) }
            try sendData(packet.encoded(), maximumBytes: 4096, record: record(.generationDecision, "decision"), check: check)
            try receiveAck(.decisionAccepted, packet.fingerprint, from: 1, check: check)
        }
    }
    func receiveDecision(token: QwenLayerStageGenerationTokenPacket,
                         check: () throws -> Void) throws -> QwenLayerStageGenerationDecisionPacket {
        try operation {
            guard rank == 1 else { throw ProbeError("Only generation rank1 receives decisions") }
            return try .decode(receiveData(maximumBytes: 4096, record: record(.generationDecision, "decision"), check: check),
                agreement: agreement, token: token)
        }
    }
    func acknowledgeDecision(_ packet: QwenLayerStageGenerationDecisionPacket, check: () throws -> Void) throws {
        try operation {
            guard rank == 1 else { throw ProbeError("Only generation rank1 acknowledges decisions") }
            if packet.content.decision == .proceed { try stop(at: .acknowledgement, check: check) }
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
                actual = try receiveAckValues(type: .requestRetired, check: check)
            } else {
                actual = try receiveAckValues(type: .requestRetired, check: check)
                try sendAck(.requestRetired, decision.fingerprint, check: check)
            }
            try QwenLayerStageGenerationAcknowledgement.validate(actual, agreement: agreement,
                phase: .requestRetired, packetFingerprint: decision.fingerprint, rank: 1 - rank)
        }
    }

    // MARK: Compact decode

    /// One decode step as four transfers instead of eleven: the boundary
    /// header and its residual in one fixed frame; the token in one frame,
    /// whose arrival is also rank 1's "consumed"; the decision in one frame,
    /// whose arrival is also rank 0's "token accepted"; and rank 1's decision
    /// acknowledgement. Every control acknowledgement still follows a
    /// validated message from the peer; only separate transfers are removed.
    static let compactHeaderLimit = 4096
    private var compactBoundaryFrameBytes: Int {
        let request = agreement.request
        let residual = request.profile.boundaryElementsPerToken * ((try? qwenStageWireElementBytes(request.profile.activationDType)) ?? 4)
        let needed = QwenControlFrame.headerBytes + 4 + Self.compactHeaderLimit + residual
        return (needed + 4095) / 4096 * 4096
    }
    private static let compactControlFrameBytes = 2048

    func sendCompactBoundary(_ boundary: QwenLayerStageBoundary, packet: QwenLayerStageGenerationBoundaryPacket,
                             check: () throws -> Void) throws {
        try operation {
            guard rank == 0, agreement.compactDecode else { throw ProbeError("Only compact-decode rank0 sends combined residuals") }
            try stop(at: .compactBoundary, check: check)
            let expected = packet.content.expectation, source = agreement.descriptor
            guard expected.frame.phase == .decode,
                  boundary.requestFingerprint == expected.requestFingerprint,
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
                hidden: agreement.request.profile.hiddenSize, dtype: boundary.array.dtype,
                residualStreams: agreement.request.profile.residualStreams ?? 1)
            try check()
            let payload = boundary.array.asData().data
            try check()
            try packet.validatePayload(payload)
            let header = packet.encoded()
            guard header.count <= Self.compactHeaderLimit else { throw ProbeError("Compact boundary header exceeds its limit") }
            var body = Data(capacity: 4 + header.count + payload.count)
            let length = UInt32(header.count)
            body.append(contentsOf: [UInt8(truncatingIfNeeded: length >> 24), UInt8(truncatingIfNeeded: length >> 16),
                                     UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length)])
            body.append(header); body.append(payload)
            try sendFrame(body, frameBytes: compactBoundaryFrameBytes, record: record(.residualPayload, "compact-boundary"), check: check)
        }
    }

    func receiveCompactBoundary(expected: QwenLayerStageGenerationBoundaryExpectation, check: () throws -> Void
    ) throws -> (QwenLayerStageBoundary, QwenLayerStageGenerationBoundaryPacket) {
        try operation {
            guard rank == 1, agreement.compactDecode, expected.frame.phase == .decode else {
                throw ProbeError("Only compact-decode rank1 receives combined residuals")
            }
            let body = [UInt8](try receiveFrame(frameBytes: compactBoundaryFrameBytes,
                record: record(.residualPayload, "compact-boundary"), check: check))
            guard body.count > 4 else { throw ProbeError("Compact boundary frame is empty") }
            let length = Int(body[0]) << 24 | Int(body[1]) << 16 | Int(body[2]) << 8 | Int(body[3])
            guard length > 0, length <= Self.compactHeaderLimit, body.count == 4 + length + expected.byteCount else {
                throw ProbeError("Compact boundary frame differs from the expected header and residual sizes")
            }
            let packet = try QwenLayerStageGenerationBoundaryPacket.decode(Data(body[4..<(4 + length)]), expected: expected)
            let payload = Data(body[(4 + length)...])
            try packet.validatePayload(payload)
            let dtype: DType
            switch expected.dtype {
            case "float16": dtype = .float16
            case "bfloat16": dtype = .bfloat16
            case "float32": dtype = .float32
            default: throw ProbeError("Generation receive dtype unsupported")
            }
            let array = try CollectivePointToPoint.materializeCompletedBytes(payload, shape: expected.shape, dtype: dtype,
                maximumBytes: expected.byteCount, check: check)
            let source = agreement.descriptor
            let boundary = QwenLayerStageBoundary(requestFingerprint: expected.requestFingerprint,
                sourceConfigurationSHA256: source.sourceConfigurationSHA256,
                artifactAggregateSHA256: source.artifactAggregateSHA256,
                storageCommitmentSHA256: source.storageCommitmentSHA256, planFingerprint: source.planFingerprint,
                producerStageFingerprint: source.stageFingerprints[0], frame: expected.frame,
                tokenIDsSHA256: expected.tokenIDsSHA256, payloadSHA256: packet.content.payloadSHA256, array: array)
            try boundary.validateOwnedArray(tokens: expected.frame.tokenCount,
                hidden: agreement.request.profile.hiddenSize, dtype: dtype,
                residualStreams: agreement.request.profile.residualStreams ?? 1)
            try check()
            return (boundary, packet)
        }
    }

    /// Rank 1: the token, sent only after this rank's own commit of the frame.
    func sendCompactToken(_ packet: QwenLayerStageGenerationTokenPacket, check: () throws -> Void) throws {
        try operation {
            guard rank == 1, agreement.compactDecode else { throw ProbeError("Only compact-decode rank1 selects target tokens") }
            try stop(at: .frame(frameBytes: Self.compactControlFrameBytes, .targetToken, "compact-token"), check: check)
            try sendFrame(try packet.encoded(), frameBytes: Self.compactControlFrameBytes, record: record(.targetToken, "compact-token"), check: check)
        }
    }
    func receiveCompactToken(boundaryFingerprint: String, previousChain: String, ordinal: Int, committedTokens: Int,
                             check: () throws -> Void) throws -> QwenLayerStageGenerationTokenPacket {
        try operation {
            guard rank == 0, agreement.compactDecode else { throw ProbeError("Only compact-decode rank0 receives target tokens") }
            return try .decode(receiveFrame(frameBytes: Self.compactControlFrameBytes,
                record: record(.targetToken, "compact-token"), check: check), agreement: agreement,
                boundaryFingerprint: boundaryFingerprint, previousTokenChainSHA256: previousChain,
                ordinal: ordinal, committedTokens: committedTokens)
        }
    }
    /// Rank 0: the decision, then rank 1's acknowledgement of it.
    func sendCompactDecision(_ packet: QwenLayerStageGenerationDecisionPacket, check: () throws -> Void) throws {
        try operation {
            guard rank == 0, agreement.compactDecode else { throw ProbeError("Only the request owner sends generation decisions") }
            if packet.content.decision == .proceed {
                try stop(at: .frame(frameBytes: Self.compactControlFrameBytes, .generationDecision, "compact-decision"), check: check)
            }
            try sendFrame(try packet.encoded(), frameBytes: Self.compactControlFrameBytes,
                record: record(.generationDecision, "compact-decision"), check: check)
            try receiveAck(.decisionAccepted, packet.fingerprint, from: 1, check: check)
        }
    }
    func receiveCompactDecision(token: QwenLayerStageGenerationTokenPacket,
                                check: () throws -> Void) throws -> QwenLayerStageGenerationDecisionPacket {
        try operation {
            guard rank == 1, agreement.compactDecode else { throw ProbeError("Only compact-decode rank1 receives decisions") }
            return try .decode(receiveFrame(frameBytes: Self.compactControlFrameBytes,
                record: record(.generationDecision, "compact-decision"), check: check),
                agreement: agreement, token: token)
        }
    }

    // MARK: Phase split

    /// Rank 0: the header, the adopting rank's answer, every segment in the
    /// agreed order, then its verdict. Returns only after rank 1 accepted the
    /// complete state. A refusal arrives as an acknowledgement and throws here
    /// at once; a rank that has gone silent ends this at the progress limit.
    func sendHandoff(_ sender: QwenPhaseSplitHandoffSender, fault: QwenPhaseSplitFault? = nil,
                     check: () throws -> Void) throws {
        try operation {
            guard rank == 0, agreement.phaseSplit != nil else { throw ProbeError("Only phase-split rank0 hands state over") }
            try stop(at: .frame(frameBytes: QwenPhaseSplitHandoffHeader.frameBytes, .handoffHeader, "handoff"), check: check)
            let header = sender.header
            try sendFrame(try header.encoded(), frameBytes: QwenPhaseSplitHandoffHeader.frameBytes,
                record: record(.handoffHeader, "handoff"), check: check)
            try receiveHandoffAck(.handoffReady, header.fingerprint, check: check)
            let state = record(.handoffState, header.fingerprint)
            for (index, segment) in sender.segments.enumerated() {
                try autoreleasepool {
                    let array = try QwenPhaseSplitArrays.materialize(sender, segment: segment,
                        corrupted: fault?.corruptSegment == index, check: check)
                    _ = try collective.sendCompleted(array, to: 1, maximumBytes: segment.byteCount,
                        scope: state.part("segment-\(index)"), check: check)
                }
            }
            try receiveHandoffAck(.handoffAccepted, header.fingerprint, check: check)
        }
    }

    /// Rank 1: the header is checked before any state is received, and one this
    /// rank does not expect is answered with a refusal. Every agreed segment is
    /// then received whatever its digest, because the sender is mid-transfer
    /// and must not be left blocked. The caller verifies and adopts the state
    /// and reports the verdict with `concludeHandoff`.
    func receiveHandoff(_ intake: QwenPhaseSplitHandoffIntake, fault: QwenPhaseSplitFault? = nil,
                        check: () throws -> Void) throws {
        try operation {
            guard rank == 1, agreement.phaseSplit != nil else { throw ProbeError("Only phase-split rank1 adopts state") }
            let frame = try receiveFrame(frameBytes: QwenPhaseSplitHandoffHeader.frameBytes,
                record: record(.handoffHeader, "handoff"), check: check)
            do { try intake.receiver.acceptHeader(frame) }
            catch {
                try? sendAck(.handoffRefused, agreement.fingerprint, check: check)
                throw error
            }
            guard let header = intake.receiver.header else { throw ProbeError("Hand-off header was not retained") }
            try stop(at: .acknowledgement, check: check)
            try sendAck(.handoffReady, header.fingerprint, check: check)
            let state = record(.handoffState, header.fingerprint)
            var index = 0
            while let segment = intake.nextSegment {
                try autoreleasepool {
                    let array = try collective.receiveCompleted(shape: segment.shape,
                        dtype: try QwenPhaseSplitArrays.dtype(segment.dtype), from: 0,
                        maximumBytes: segment.byteCount, scope: state.part("segment-\(index)"), check: check)
                    try intake.accept(array, check: check)
                }
                if let fault, fault.stallAfterSegment == index {
                    // Qualification fault: this rank stops receiving, as a
                    // stalled rank would, and still notices its own deadline.
                    let until = DispatchTime.now().uptimeNanoseconds + UInt64(fault.stallMilliseconds) * 1_000_000
                    while DispatchTime.now().uptimeNanoseconds < until { usleep(20_000); try check() }
                }
                index += 1
            }
        }
    }

    /// Rank 1, once: accept the state it verified and adopted, or refuse it.
    /// The refusal is what lets rank 0 stop at once instead of waiting out the
    /// progress limit, so it is sent even though this transport is then failed.
    func concludeHandoff(_ header: QwenPhaseSplitHandoffHeader?, accepted: Bool, check: () throws -> Void) throws {
        guard rank == 1, !inOperation else { throw ProbeError("Only phase-split rank1 concludes a hand-off") }
        guard accepted, let header else {
            let live = !isFailed
            isFailed = true
            if live { try sendAck(.handoffRefused, agreement.fingerprint, check: check) }
            return
        }
        try operation {
            try stop(at: .acknowledgement, check: check)
            try sendAck(.handoffAccepted, header.fingerprint, check: check)
        }
    }

    /// Rank 1: one batch of tokens it selected alone. It does not wait for
    /// the answer here: rank 0 publishes the batch while rank 1 decodes the
    /// next one, and the answer is read at the next batch boundary.
    func sendRelay(_ packet: QwenPhaseSplitRelayPacket, check: () throws -> Void) throws {
        try operation {
            guard rank == 1 else { throw ProbeError("Only phase-split rank1 relays tokens") }
            try stop(at: .frame(frameBytes: QwenPhaseSplitRelayPacket.frameBytes, .tokenRelay, "relay"), check: check)
            try sendFrame(try packet.encoded(), frameBytes: QwenPhaseSplitRelayPacket.frameBytes,
                record: record(.tokenRelay, "relay"), check: check)
        }
    }

    /// Rank 1: rank 0's answer to a batch already sent.
    func receiveRelayDecision(relay packet: QwenPhaseSplitRelayPacket,
                              check: () throws -> Void) throws -> QwenPhaseSplitRelayDecisionPacket {
        try operation {
            guard rank == 1 else { throw ProbeError("Only phase-split rank1 receives relay decisions") }
            return try .decode(receiveFrame(frameBytes: QwenPhaseSplitRelayDecisionPacket.frameBytes,
                record: record(.relayDecision, "relay-decision"), check: check), agreement: agreement, relay: packet)
        }
    }

    /// Rank 0, idle after the hand-off: the next batch. It waits in a receive
    /// for as long as rank 1 decodes that batch, bounded by the progress limit.
    func receiveRelay(handoffFingerprint: String, firstOrdinal: Int, previousTokenChainSHA256: String,
                      check: () throws -> Void) throws -> QwenPhaseSplitRelayPacket {
        try operation {
            guard rank == 0 else { throw ProbeError("Only the request owner receives relayed tokens") }
            return try .decode(receiveFrame(frameBytes: QwenPhaseSplitRelayPacket.frameBytes,
                record: record(.tokenRelay, "relay"), check: check),
                agreement: agreement, handoffFingerprint: handoffFingerprint, firstOrdinal: firstOrdinal,
                previousTokenChainSHA256: previousTokenChainSHA256)
        }
    }

    func sendRelayDecision(_ packet: QwenPhaseSplitRelayDecisionPacket, check: () throws -> Void) throws {
        try operation {
            guard rank == 0 else { throw ProbeError("Only the request owner answers relayed tokens") }
            if packet.content.decision == .proceed {
                try stop(at: .frame(frameBytes: QwenPhaseSplitRelayDecisionPacket.frameBytes, .relayDecision, "relay-decision"),
                    check: check)
            }
            try sendFrame(try packet.encoded(), frameBytes: QwenPhaseSplitRelayDecisionPacket.frameBytes,
                record: record(.relayDecision, "relay-decision"), check: check)
        }
    }

    /// Rank 1, serving a request alone: its prompt frames' residual digests.
    func sendAlonePrompt(_ packet: QwenAlonePromptPacket, check: () throws -> Void) throws {
        try operation {
            guard rank == 1 else { throw ProbeError("Only the decoding rank serves a request alone") }
            try stop(at: .frame(frameBytes: QwenAlonePromptPacket.frameBytes, .tokenRelay, "alone-prompt"), check: check)
            try sendFrame(try packet.encoded(), frameBytes: QwenAlonePromptPacket.frameBytes,
                record: record(.tokenRelay, "alone-prompt"), check: check)
        }
    }

    /// Rank 0: the next batch of those digests, from frame `firstFrame`.
    func receiveAlonePrompt(firstFrame: Int, check: () throws -> Void) throws -> QwenAlonePromptPacket {
        try operation {
            guard rank == 0 else { throw ProbeError("Only the request owner receives an alone-route prompt") }
            return try .decode(receiveFrame(frameBytes: QwenAlonePromptPacket.frameBytes,
                record: record(.tokenRelay, "alone-prompt"), check: check), agreement: agreement, firstFrame: firstFrame)
        }
    }

    /// One fixed-size zero-padded transfer per control message.
    private func sendFrame(_ body: Data, frameBytes: Int, record scope: CollectiveRecordScope,
                           check: () throws -> Void) throws {
        let frame = try QwenControlFrame.encode(body, frameBytes: frameBytes)
        _ = try collective.sendCompleted(MLXArray(Array(frame)), to: 1 - rank, maximumBytes: frameBytes,
            scope: scope, check: check)
    }
    private func receiveFrame(frameBytes: Int, record scope: CollectiveRecordScope, check: () throws -> Void) throws -> Data {
        let data = try collective.receiveCompleted(shape: [frameBytes], dtype: .uint8, from: 1 - rank,
            maximumBytes: frameBytes, scope: scope, check: check).asData().data
        try check()
        let body = try QwenControlFrame.decode(data, frameBytes: frameBytes)
        if let stopped = try QwenStageAbortWire.abort(in: body, agreement: agreement) { try peerStopped(stopped, check: check) }
        return body
    }

    /// A fixed control frame of another protocol over this request's records
    /// (a pipeline MTP round's frames), with the same stop point and marker.
    func sendControlFrame(_ body: Data, frameBytes: Int, type: ClusterRecordType, label: String,
                          stopPoint: Bool, check: () throws -> Void) throws {
        try operation {
            if stopPoint { try stop(at: .frame(frameBytes: frameBytes, type, label), check: check) }
            try sendFrame(body, frameBytes: frameBytes, record: record(type, label), check: check)
        }
    }
    func receiveControlFrame(frameBytes: Int, type: ClusterRecordType, label: String,
                             check: () throws -> Void) throws -> Data {
        try operation { try receiveFrame(frameBytes: frameBytes, record: record(type, label), check: check) }
    }
    private func receiveHandoffAck(_ phase: QwenLayerStageGenerationAcknowledgement.Phase, _ fingerprint: String,
                                   check: () throws -> Void) throws {
        let actual = try receiveAckValues(type: .acknowledgement, check: check)
        // A refusal is bound to the agreement alone: a rank that rejected the
        // header never held a fingerprint of it that it could trust.
        if actual == (try QwenLayerStageGenerationAcknowledgement.values(agreement: agreement,
            phase: .handoffRefused, packetFingerprint: agreement.fingerprint, rank: 1)) {
            throw ProbeError("The adopting rank refused the hand-off")
        }
        try QwenLayerStageGenerationAcknowledgement.validate(actual, agreement: agreement,
            phase: phase, packetFingerprint: fingerprint, rank: 1)
    }

    private func sendData(_ data: Data, maximumBytes: Int, record scope: CollectiveRecordScope,
                          check: () throws -> Void) throws {
        guard !data.isEmpty, data.count <= maximumBytes else { throw ProbeError("Generation send control byte cap") }
        _ = try collective.sendCompleted(MLXArray([UInt32(data.count)]), to: 1 - rank, maximumBytes: 4,
            scope: scope.part("length"), check: check)
        _ = try collective.sendCompleted(MLXArray(Array(data)), to: 1 - rank, maximumBytes: maximumBytes,
            scope: scope.part("body"), check: check)
    }
    private func receiveData(maximumBytes: Int, record scope: CollectiveRecordScope,
                             check: () throws -> Void) throws -> Data {
        let length = try collective.receiveCompleted(shape: [1], dtype: .uint32, from: 1 - rank,
            maximumBytes: 4, scope: scope.part("length"), check: check).item(UInt32.self)
        if length == QwenStageAbortWire.lengthMarker { try peerStopped(.init(reason: .memory, rank: 1 - rank), check: check) }
        guard length > 0, Int(length) <= maximumBytes else { throw ProbeError("Generation received control byte cap") }
        let data = try collective.receiveCompleted(shape: [Int(length)], dtype: .uint8, from: 1 - rank,
            maximumBytes: maximumBytes, scope: scope.part("body"), check: check).asData().data
        try check(); return data
    }
    /// Acknowledgements: one record kind (retirement has its own); the
    /// values themselves carry and are checked for the phase and packet.
    private func sendAck(_ phase: QwenLayerStageGenerationAcknowledgement.Phase, _ fingerprint: String,
                         check: () throws -> Void) throws {
        let values = try QwenLayerStageGenerationAcknowledgement.values(agreement: agreement,
            phase: phase, packetFingerprint: fingerprint, rank: rank)
        let type: ClusterRecordType = phase == .requestRetired ? .requestRetired : .acknowledgement
        _ = try collective.sendCompleted(MLXArray(values), to: 1 - rank, maximumBytes: 256,
            scope: record(type, "ack"), check: check)
    }
    private func receiveAckValues(type: ClusterRecordType, check: () throws -> Void) throws -> [Int32] {
        let actual = try collective.receiveCompleted(shape: [64], dtype: .int32, from: 1 - rank,
            maximumBytes: 256, scope: record(type, "ack"), check: check).asArray(Int32.self)
        try check()
        if type == .acknowledgement, actual == (try QwenStageAbortWire.acknowledgement(agreement: agreement, rank: 1 - rank)) {
            try peerStopped(.init(reason: .memory, rank: 1 - rank), check: check)
        }
        return actual
    }
    private func receiveAck(_ phase: QwenLayerStageGenerationAcknowledgement.Phase, _ fingerprint: String,
                            from peer: Int, check: () throws -> Void) throws {
        try QwenLayerStageGenerationAcknowledgement.validate(receiveAckValues(type: .acknowledgement, check: check),
            agreement: agreement, phase: phase, packetFingerprint: fingerprint, rank: peer)
    }
    private func operation<T>(allowPendingBoundary: Bool = false, _ body: () throws -> T) throws -> T {
        guard !inOperation, !isFailed, !isAborted, allowPendingBoundary || pendingBoundaryFingerprint == nil else {
            isFailed = true; throw ProbeError("Generation transport is failed, aborted, reentered or has pending consumption")
        }
        inOperation = true; defer { inOperation = false }
        do { let result = try body(); guard !isFailed else { throw ProbeError("Generation transport was poisoned") }; return result }
        catch let stopped as QwenStageAborted {
            // Both ranks are at the same point of the record stream: nothing
            // owed is in flight, so this is not a failure of the transport.
            isAborted = true; pendingBoundaryFingerprint = nil
            throw stopped
        }
        catch { isFailed = true; throw error }
    }
}
