import DarkbloomClusterProtocol
import Foundation
import MLX
import Testing
@testable import DarkbloomClusterRuntime

/// D6: a stage whose memory gate refuses the running request stops in the
/// slot it owes its peer (a marker of that message's own record), the peer
/// confirms once, both retire it, and the same collectives serve the next
/// request. Real two-rank local sockets; no model.
@Suite("A pipeline stage's memory refusal ends that request alone", .serialized)
struct PipelineStageAbortTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.withLock { value += 1; return value } }
        var count: Int { lock.withLock { value } }
    }

    /// A latch whose live check refuses for memory from its `refusingAt`-th poll on.
    private static func latch(rank: Int, refusingAt poll: Int, counter: Counter = Counter()) -> QwenStageAbort {
        QwenStageAbort(rank: rank, intervalNanoseconds: 0) {
            if counter.next() >= poll { throw QwenResidentMemoryRefusal(message: "fixture: the memory gate refused") }
        }
    }

    private static func request(prompt: [Int] = [1, 2], outputs: Int = 3) throws -> QwenLayerStageGenerationRequest {
        let profile = try QwenLayerStageGenerationProfile(identifier: "stage-abort-fixture", vocabularySize: 64,
            hiddenSize: 64, activationDType: "bfloat16", maximumPromptTokens: 8, maximumChunkTokens: 8,
            maximumOutputTokens: 4, maximumContextTokens: 12)
        return try .init(profile: profile, requestID: UUID(), promptTokenIDs: prompt, chunkSize: 2,
            outputCount: outputs, stopTokenIDs: [])
    }

    private static func agreement(_ request: QwenLayerStageGenerationRequest,
                                  compact: Bool = false) throws -> QwenLayerStageGenerationAgreement {
        let source = try QwenLayerStageWireSourceIdentity(
            sourceConfigurationSHA256: String(repeating: "a", count: 64),
            artifactAggregateSHA256: String(repeating: "b", count: 64),
            storageCommitmentSHA256: String(repeating: "c", count: 64),
            planFingerprint: String(repeating: "d", count: 64),
            producerStageFingerprint: String(repeating: "e", count: 64))
        return try .init(request: request, membershipEpoch: UUID(), source: source,
            consumerStageFingerprint: String(repeating: "f", count: 64),
            rankBuildSHA256: [String(repeating: "1", count: 64), String(repeating: "2", count: 64)],
            numericalPolicySHA256: String(repeating: "3", count: 64), compactDecode: compact)
    }

    /// Frame `sequence`'s boundary as rank 0 would send it, with distinct bytes.
    private static func boundary(_ agreement: QwenLayerStageGenerationAgreement, sequence: Int, token: Int? = nil) throws
        -> (QwenLayerStageBoundary, QwenLayerStageGenerationBoundaryPacket, QwenLayerStageGenerationBoundaryExpectation) {
        let request = agreement.request, frame = try request.frame(sequence: sequence)
        let tokens = frame.phase == .prefill
            ? Array(request.promptTokenIDs[frame.tokenOffset..<(frame.tokenOffset + frame.tokenCount)]) : [token ?? 5]
        let chain = frame.phase == .prefill ? agreement.initialTokenChainSHA256 : String(repeating: "4", count: 64)
        let expected = try QwenLayerStageGenerationBoundaryExpectation(agreement: agreement, frame: frame, tokenIDs: tokens,
            previousTokenChainSHA256: chain)
        let words = (0..<(expected.byteCount / 2)).map { UInt16(0x3f00 + $0 % 256).littleEndian }
        let bytes = words.withUnsafeBytes { Data($0) }
        let array = try CollectivePointToPoint.materializeCompletedBytes(bytes, shape: expected.shape, dtype: .bfloat16,
            maximumBytes: expected.byteCount, check: {})
        let source = agreement.descriptor
        let value = QwenLayerStageBoundary(requestFingerprint: expected.requestFingerprint,
            sourceConfigurationSHA256: source.sourceConfigurationSHA256,
            artifactAggregateSHA256: source.artifactAggregateSHA256,
            storageCommitmentSHA256: source.storageCommitmentSHA256, planFingerprint: source.planFingerprint,
            producerStageFingerprint: source.stageFingerprints[0], frame: expected.frame,
            tokenIDsSHA256: expected.tokenIDsSHA256, payloadSHA256: sha256(bytes), array: array)
        return (value, try .init(expected: expected, payloadSHA256: sha256(bytes)), expected)
    }

    private static func aborted(_ body: () throws -> Void) -> QwenStageAborted? {
        do { try body() } catch let value as QwenStageAborted { return value } catch { Issue.record("not an abort: \(error)") }
        return nil
    }

    /// The next request's first exchange on the same collectives (a token and
    /// its acknowledgement): it succeeds only if neither rank left a record behind.
    private static func nextRequestExchanges(_ pair: ResidualStreamCollectiveFixture) throws {
        let next = try agreement(request(prompt: [3, 4]))
        let boundary = String(repeating: "5", count: 64), chain = next.initialTokenChainSHA256
        let token = try QwenLayerStageGenerationTokenPacket(agreement: next, boundaryFingerprint: boundary,
            previousTokenChainSHA256: chain, ordinal: 0, committedTokens: 2, tokenID: 9)
        let received = try pair.exchange(send: {
            let transport = try QwenLayerStageGenerationTransport(agreement: next, collective: pair.first)
            defer { transport.retire() }
            let value = try transport.receiveToken(boundaryFingerprint: boundary, previousChain: chain, ordinal: 0,
                committedTokens: 2, check: {})
            try transport.acknowledgeToken(value, check: {})
            #expect(value.content.tokenID == 9)
        }, receive: { peer -> Int in
            let transport = try QwenLayerStageGenerationTransport(agreement: next, collective: peer)
            defer { transport.retire() }
            try transport.sendToken(token, check: {})
            return token.content.tokenID
        })
        #expect(received == 9)
    }

    @Test func theLatchKeepsAMemoryRefusalAndRethrowsAnythingElse() throws {
        let counter = Counter()
        let memory = Self.latch(rank: 1, refusingAt: 2, counter: counter)
        #expect(try memory.poll() == false && memory.latched == nil)
        #expect(try memory.poll() == true)
        #expect(memory.latched == ClusterWorkerAbort(reason: .memory, rank: 1))
        // Latched for good: the live check is not asked again.
        #expect(try memory.poll() == true && counter.count == 2)
        let power = QwenStageAbort(rank: 0, intervalNanoseconds: 0) { throw ProbeError("Resident execution requires AC") }
        #expect(throws: ProbeError.self) { _ = try power.poll() }
        #expect(power.latched == nil)
        // Its interval is the running check's: a poll inside it asks nothing.
        let throttled = Counter()
        let slow = QwenStageAbort(rank: 0, intervalNanoseconds: 60_000_000_000) { _ = throttled.next() }
        _ = try slow.poll(); _ = try slow.poll(); _ = try slow.poll()
        #expect(throttled.count == 1)
    }

    @Test func everyMarkerIsAValueNoMessageTakes() throws {
        let agreement = try Self.agreement(Self.request())
        // A length word: past every control body and boundary header bound.
        #expect(Int(QwenStageAbortWire.lengthMarker) > QwenLayerStageGenerationBoundaryPacket.maximumEncodedBytes)
        #expect(Int(QwenStageAbortWire.lengthMarker) > QwenLayerStageGenerationTokenPacket.maximumEncodedBytes)
        // An acknowledgement: a phase no message acknowledges, bound to the agreement and its sender.
        for rank in 0...1 {
            let marker = try QwenStageAbortWire.acknowledgement(agreement: agreement, rank: rank)
            let confirmation = try QwenStageAbortWire.confirmation(agreement: agreement, rank: rank)
            #expect(marker != confirmation && marker.count == 64)
            let phases: [QwenLayerStageGenerationAcknowledgement.Phase] = [.boundaryReady, .boundaryConsumed,
                .tokenAccepted, .decisionAccepted, .requestRetired, .handoffReady, .handoffAccepted, .handoffRefused]
            for phase in phases {
                for fingerprint in [agreement.fingerprint, String(repeating: "9", count: 64)] {
                    let real = try QwenLayerStageGenerationAcknowledgement.values(agreement: agreement, phase: phase,
                        packetFingerprint: fingerprint, rank: rank)
                    #expect(real != marker && real != confirmation)
                }
            }
            #expect(try QwenStageAbortWire.acknowledgement(agreement: agreement, rank: 1 - rank) != marker)
        }
        // A frame body: its own schema, read before the slot's own packet.
        let abort = ClusterWorkerAbort(reason: .memory, rank: 1)
        let body = try QwenStageAbortWire.packet(agreement: agreement, abort: abort)
        #expect(try QwenStageAbortWire.abort(in: body, agreement: agreement) == abort)
        let token = try QwenLayerStageGenerationTokenPacket(agreement: agreement,
            boundaryFingerprint: String(repeating: "5", count: 64), previousTokenChainSHA256: agreement.initialTokenChainSHA256,
            ordinal: 0, committedTokens: 2, tokenID: 9)
        #expect(try QwenStageAbortWire.abort(in: token.encoded(), agreement: agreement) == nil)
        let other = try Self.agreement(Self.request())
        #expect(throws: ProbeError.self) { try QwenStageAbortWire.abort(in: body, agreement: other) }
        // It fits every fixed frame a marker can stand in.
        for frameBytes in [2048, QwenPhaseSplitRelayPacket.frameBytes, QwenPhaseSplitRelayDecisionPacket.frameBytes,
                           QwenAlonePromptPacket.frameBytes, QwenPhaseSplitHandoffHeader.frameBytes,
                           MiMoMTPRoundPacket.frameBytes, MiMoMTPRoundResultPacket.frameBytes,
                           MiMoMTPRoundDecisionPacket.frameBytes] {
            #expect(throws: Never.self) { _ = try QwenControlFrame.encode(body, frameBytes: frameBytes) }
        }
        #expect(try QwenStageAbortWire.retirementFingerprint(agreement: agreement, abort: abort)
            != QwenStageAbortWire.retirementFingerprint(agreement: agreement, abort: .init(reason: .memory, rank: 0)))
    }

    /// D6's own slot: rank 1's gate refuses with a boundary on its way. Rank 1
    /// answers the header with the marker instead of `boundaryReady`, so rank 0
    /// never sends the payload; both report rank 1's abort, retire it together,
    /// and the next request's first exchange runs on the same collectives.
    @Test func rankOneStopsAtTheReadinessItOwesAndTheWireServesTheNextRequest() throws {
        let agreement = try Self.agreement(Self.request())
        let (boundary, packet, expected) = try Self.boundary(agreement, sequence: 0)
        let pair = try ResidualStreamCollectiveFixture()
        var producer: QwenStageAborted?
        let consumer = try pair.exchange(send: {
            let transport = try QwenLayerStageGenerationTransport(agreement: agreement, collective: pair.first)
            producer = Self.aborted { try transport.sendBoundary(boundary, packet: packet, check: {}) }
            if let producer { try transport.exchangeAbortRetirement(producer, check: {}) }
            #expect(!transport.isFailed && transport.isAborted)
        }, receive: { peer -> (QwenStageAborted?, Bool) in
            let transport = try QwenLayerStageGenerationTransport(agreement: agreement, collective: peer,
                abort: Self.latch(rank: 1, refusingAt: 1))
            var consumed = false
            let value = Self.aborted {
                _ = try transport.receiveBoundary(expected: expected, consume: { _, _ in consumed = true }, check: {})
            }
            if let value { try transport.exchangeAbortRetirement(value, check: {}) }
            return (value, consumed || transport.isFailed)
        })
        #expect(producer?.abort == .init(reason: .memory, rank: 1) && producer?.local == false)
        #expect(consumer.0?.abort == .init(reason: .memory, rank: 1) && consumer.0?.local == true)
        #expect(!consumer.1, "rank 1 consumed a frame or failed its transport")
        try Self.nextRequestExchanges(pair)
    }

    /// Rank 0's gate refuses at a frame's start: it runs no forward and sends
    /// the marker where rank 1 waits for the header.
    @Test func rankZeroStopsAtTheHeaderItOwesWithoutAForward() throws {
        let agreement = try Self.agreement(Self.request())
        let (_, _, expected) = try Self.boundary(agreement, sequence: 0)
        let pair = try ResidualStreamCollectiveFixture()
        var producer: QwenStageAborted?
        let consumer = try pair.exchange(send: {
            let transport = try QwenLayerStageGenerationTransport(agreement: agreement, collective: pair.first,
                abort: Self.latch(rank: 0, refusingAt: 1))
            producer = Self.aborted { try transport.stopIfLatched(owing: .boundaryHeader, check: {}) }
            if let producer { try transport.exchangeAbortRetirement(producer, check: {}) }
        }, receive: { peer -> QwenStageAborted? in
            let transport = try QwenLayerStageGenerationTransport(agreement: agreement, collective: peer)
            let value = Self.aborted {
                _ = try transport.receiveBoundary(expected: expected, consume: { _, _ in Issue.record("consumed") }, check: {})
            }
            if let value { try transport.exchangeAbortRetirement(value, check: {}) }
            return value
        })
        #expect(producer?.abort == .init(reason: .memory, rank: 0) && producer?.local == true)
        #expect(consumer?.abort == .init(reason: .memory, rank: 0) && consumer?.local == false)
        try Self.nextRequestExchanges(pair)
    }

    /// Rank 1's gate refuses once the payload has arrived: it skips its
    /// forward and sends the marker where rank 0 waits for `boundaryConsumed`.
    /// A latch that is clear is never a marker: the request runs as before.
    @Test func rankOneStopsInsteadOfConsumingThePayload() throws {
        let agreement = try Self.agreement(Self.request())
        let (boundary, packet, expected) = try Self.boundary(agreement, sequence: 0)
        let pair = try ResidualStreamCollectiveFixture()
        var producer: QwenStageAborted?
        let consumed = try pair.exchange(send: {
            let transport = try QwenLayerStageGenerationTransport(agreement: agreement, collective: pair.first)
            producer = Self.aborted { try transport.sendBoundary(boundary, packet: packet, check: {}) }
            if let producer { try transport.exchangeAbortRetirement(producer, check: {}) }
        }, receive: { peer -> Bool in
            // Clear when the header arrives, refusing once the payload has.
            let transport = try QwenLayerStageGenerationTransport(agreement: agreement, collective: peer,
                abort: Self.latch(rank: 1, refusingAt: 2))
            var consumed = false
            let value = Self.aborted {
                _ = try transport.receiveBoundary(expected: expected, consume: { _, _ in consumed = true }, check: {})
            }
            #expect(value?.abort == .init(reason: .memory, rank: 1) && value?.local == true)
            if let value { try transport.exchangeAbortRetirement(value, check: {}) }
            return consumed
        })
        #expect(producer?.abort == .init(reason: .memory, rank: 1) && producer?.local == false)
        #expect(!consumed)
        try Self.nextRequestExchanges(pair)
    }

    /// A real refusal, no fault: this Mac's memory reads as taken
    /// (`TakenMemory`). Rank 1's latch asks MiMo's own gate and stops at the
    /// readiness it owes; then rank 0's asks GPT-OSS's own gate and stops at
    /// the header it owes. Each time both ranks end that request alone, and the
    /// next request's first exchange runs on the same collectives.
    @Test func aRealRefusalOfAMiMoOrGPTOSSStageEndsTheRequestOnBothRanks() throws {
        let pair = try ResidualStreamCollectiveFixture()
        let first = try Self.agreement(Self.request())
        let (boundary, packet, expected) = try Self.boundary(first, sequence: 0)
        var producer: QwenStageAborted?
        let consumer = try pair.exchange(send: {
            let transport = try QwenLayerStageGenerationTransport(agreement: first, collective: pair.first)
            producer = Self.aborted { try transport.sendBoundary(boundary, packet: packet, check: {}) }
            if let producer { try transport.exchangeAbortRetirement(producer, check: {}) }
        }, receive: { peer -> QwenStageAborted? in
            let mimo = QwenStageAbort(rank: 1, intervalNanoseconds: 0) {
                try TakenMemory.whileTaken { try TakenMemory.mimo().requireLive() }
            }
            let transport = try QwenLayerStageGenerationTransport(agreement: first, collective: peer, abort: mimo)
            let value = Self.aborted {
                _ = try transport.receiveBoundary(expected: expected, consume: { _, _ in Issue.record("consumed") }, check: {})
            }
            if let value { try transport.exchangeAbortRetirement(value, check: {}) }
            return value
        })
        #expect(producer?.abort == .init(reason: .memory, rank: 1) && consumer?.abort == .init(reason: .memory, rank: 1))
        try Self.nextRequestExchanges(pair)

        let second = try Self.agreement(Self.request())
        let (_, _, header) = try Self.boundary(second, sequence: 0)
        var stopping: QwenStageAborted?
        let follower = try pair.exchange(send: {
            let gptOSS = QwenStageAbort(rank: 0, intervalNanoseconds: 0) {
                try TakenMemory.whileTaken { try TakenMemory.gptOSS().requireLive() }
            }
            let transport = try QwenLayerStageGenerationTransport(agreement: second, collective: pair.first, abort: gptOSS)
            stopping = Self.aborted { try transport.stopIfLatched(owing: .boundaryHeader, check: {}) }
            if let stopping { try transport.exchangeAbortRetirement(stopping, check: {}) }
        }, receive: { peer -> QwenStageAborted? in
            let transport = try QwenLayerStageGenerationTransport(agreement: second, collective: peer)
            let value = Self.aborted {
                _ = try transport.receiveBoundary(expected: header, consume: { _, _ in Issue.record("consumed") }, check: {})
            }
            if let value { try transport.exchangeAbortRetirement(value, check: {}) }
            return value
        })
        #expect(stopping?.abort == .init(reason: .memory, rank: 0) && follower?.abort == .init(reason: .memory, rank: 0))
        try Self.nextRequestExchanges(pair)
    }

    /// Compact decode: rank 0 stops in the compact boundary frame it owes, and
    /// rank 1 in the compact token frame it owes.
    @Test func compactDecodeStopsInTheFrameEachRankOwes() throws {
        for stopping in 0...1 {
            let agreement = try Self.agreement(Self.request(), compact: true)
            let (boundary, packet, expected) = try Self.boundary(agreement, sequence: 1)
            let pair = try ResidualStreamCollectiveFixture()
            var producer: QwenStageAborted?
            let consumer = try pair.exchange(send: {
                let transport = try QwenLayerStageGenerationTransport(agreement: agreement, collective: pair.first,
                    abort: stopping == 0 ? Self.latch(rank: 0, refusingAt: 1) : nil)
                producer = Self.aborted {
                    if stopping == 0 { try transport.stopIfLatched(owing: .compactBoundary, check: {}) }
                    try transport.sendCompactBoundary(boundary, packet: packet, check: {})
                    _ = try transport.receiveCompactToken(boundaryFingerprint: packet.fingerprint,
                        previousChain: expected.previousTokenChainSHA256, ordinal: 1, committedTokens: 3, check: {})
                }
                if let producer { try transport.exchangeAbortRetirement(producer, check: {}) }
            }, receive: { peer -> QwenStageAborted? in
                let transport = try QwenLayerStageGenerationTransport(agreement: agreement, collective: peer,
                    abort: stopping == 1 ? Self.latch(rank: 1, refusingAt: 1) : nil)
                let value = Self.aborted {
                    let (_, received) = try transport.receiveCompactBoundary(expected: expected, check: {})
                    let token = try QwenLayerStageGenerationTokenPacket(agreement: agreement,
                        boundaryFingerprint: received.fingerprint, previousTokenChainSHA256: expected.previousTokenChainSHA256,
                        ordinal: 1, committedTokens: 3, tokenID: 7)
                    try transport.sendCompactToken(token, check: {})
                }
                if let value { try transport.exchangeAbortRetirement(value, check: {}) }
                return value
            })
            #expect(producer?.abort == .init(reason: .memory, rank: stopping) && producer?.local == (stopping == 0))
            #expect(consumer?.abort == .init(reason: .memory, rank: stopping) && consumer?.local == (stopping == 1))
            try Self.nextRequestExchanges(pair)
        }
    }

    /// Batch lanes (wire v3): a lane leaves for memory with its own
    /// disposition and the refusing rank; rank 1 names lanes its gate refused
    /// in the reply's memory mask. Neither is a cancel or a finish, and a
    /// running slot cannot carry it.
    @Test func aLaneLeavesForMemoryWithTheRefusingRankAndTheReplyNamesIt() throws {
        #expect(QwenBatchWire.version == 3)
        let id = UUID()
        var slot = QwenBatchWire.Slot(state: .leaving, requestID: id, selectedTokens: 2)
        slot.leaveAborted = ClusterWorkerAbort(reason: .memory, rank: 1)
        let header = QwenBatchWire.Header(step: 7, stop: false, slots: [slot, .init()])
        let decoded = try QwenBatchWire.Header(words: header.words, expectedStep: 7, lanes: 2)
        #expect(decoded == header)
        #expect(decoded.slots[0].leaveAborted == .init(reason: .memory, rank: 1))
        #expect(!decoded.slots[0].leaveCancelled && decoded.slots[0].leaveReason == nil)
        func refused(_ change: (inout [Int32]) -> Void) {
            var words = header.words
            change(&words)
            words[QwenBatchWire.headerWords - 1] = QwenBatchWire.checksum(words[0..<(QwenBatchWire.headerWords - 1)])
            #expect(throws: ProbeError.self) { _ = try QwenBatchWire.Header(words: words, expectedStep: 7, lanes: 2) }
        }
        refused { $0[16] = QwenBatchWire.SlotState.active.rawValue }     // a running slot
        refused { $0[16 + 27] = 2 }                                        // no third rank
        refused { $0[5] = 2 }                                              // the v2 wire
        let reply = QwenBatchWire.Reply(step: 7, tokens: [-1, 4], memoryMask: 0b01)
        let read = try QwenBatchWire.Reply(words: reply.words, expectedStep: 7, lanes: 2)
        #expect(read.memoryMask == 0b01 && read.cancelledMask == 0)
        var outside = reply.words
        outside[6] = 0b100
        outside[QwenBatchWire.replyWords - 1] = QwenBatchWire.checksum(outside[0..<(QwenBatchWire.replyWords - 1)])
        #expect(throws: ProbeError.self) { _ = try QwenBatchWire.Reply(words: outside, expectedStep: 7, lanes: 2) }
    }

    /// The lane a memory refusal stops: the newest one still running, never
    /// one already leaving; none when every lane is.
    @Test func aMemoryRefusalStopsTheNewestRunningLane() {
        let a = UUID(), b = UUID(), c = UUID()
        let orders = [a: 0, b: 2, c: 1]
        #expect(QwenBatchMemoryStop.lane(orders: orders, stopping: []) == b)
        #expect(QwenBatchMemoryStop.lane(orders: orders, stopping: [b]) == c)
        #expect(QwenBatchMemoryStop.lane(orders: orders, stopping: [a, b, c]) == nil)
        #expect(QwenBatchMemoryStop.lane(orders: [:], stopping: []) == nil)
    }

    /// Rank 0 replaces only a decision to go on: a decision that ends the
    /// request is sent as it is, and the request ends as it would have.
    @Test func onlyADecisionToGoOnIsReplaced() throws {
        for (outputs, continuing) in [(3, true), (1, true), (3, false)] {
            let agreement = try Self.agreement(Self.request(outputs: outputs))
            let boundary = String(repeating: "5", count: 64), chain = agreement.initialTokenChainSHA256
            let token = try QwenLayerStageGenerationTokenPacket(agreement: agreement, boundaryFingerprint: boundary,
                previousTokenChainSHA256: chain, ordinal: 0, committedTokens: 2, tokenID: 9)
            let decision = try QwenLayerStageGenerationDecisionPacket(agreement: agreement, token: token,
                continueRequested: continuing)
            let replaced = decision.content.decision == .proceed
            let pair = try ResidualStreamCollectiveFixture()
            var producer: QwenStageAborted?
            let consumer = try pair.exchange(send: {
                let transport = try QwenLayerStageGenerationTransport(agreement: agreement, collective: pair.first,
                    abort: Self.latch(rank: 0, refusingAt: 1))
                producer = replaced ? Self.aborted { try transport.sendDecision(decision, check: {}) } : nil
                if !replaced { try transport.sendDecision(decision, check: {}) }
                if let producer { try transport.exchangeAbortRetirement(producer, check: {}) }
            }, receive: { peer -> (QwenStageAborted?, QwenLayerStageGenerationDecision?) in
                let transport = try QwenLayerStageGenerationTransport(agreement: agreement, collective: peer)
                var received: QwenLayerStageGenerationDecision?
                let value = Self.aborted {
                    let packet = try transport.receiveDecision(token: token, check: {})
                    received = packet.content.decision
                    try transport.acknowledgeDecision(packet, check: {})
                }
                if let value { try transport.exchangeAbortRetirement(value, check: {}) }
                return (value, received)
            })
            if replaced {
                #expect(producer?.abort.rank == 0 && consumer.0?.abort.rank == 0 && consumer.1 == nil)
            } else {
                #expect(producer == nil && consumer.0 == nil && consumer.1 == decision.content.decision)
            }
            try Self.nextRequestExchanges(pair)
        }
    }
}
