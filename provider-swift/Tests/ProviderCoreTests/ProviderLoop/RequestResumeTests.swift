import Foundation
import Testing

@testable import ProviderCore

#if DEBUG
/// Request resume v1 (failover phase 5, rows C4, C6 and C7). A request whose sealed body carries a resume id keeps its
/// generation when the connection to its coordinator drops. A surviving coordinator's dispatch of the same request,
/// through a normal hop 2 with a fresh session key, takes the whole answer: every chunk from the first, sealed to the
/// new session key with this Mac's static key as sender, then the terminal with the whole usage, under the new request
/// id. A dispatch that fails any check runs as new; nothing that attaches within the window is cancelled at its end,
/// unanswered. The requests travel the encrypted coordinator path to the Me-first harness's engine, a queue with no
/// tensors.
@Suite("Request resume: a held request's answer goes to the survivor's dispatch", .serialized, .timeLimit(.minutes(1)))
struct RequestResumeTests {
    static let resumeID = String(repeating: "5e", count: 32)

    /// Holds one resumable request ("held", sealed with `original`) that sent one token's output, then dropped its
    /// connection.
    private func heldRequest(slots: Int = 8) async throws -> (Fixture, original: NodeKeyPair, body: Data, sentBefore: Int) {
        let f = try await Fixture.make(slots: slots)
        let original = NodeKeyPair.generate()
        let body = try Fixture.body()
        try await f.dispatchReachingEngine("held", body: body, session: original)
        f.h.engine.token(0)
        try #require(await resumeEventually { f.outbound.contentFrames("held", original) == 1 }, "held streamed a token")
        let sentBefore = f.outbound.chunks("held").count
        await f.loop.handleCoordinatorDisconnected()
        #expect(await f.loop.state.resumableRequests == [Self.resumeID], "the next register lists it")
        #expect(f.h.engine.cancelledIndices.isEmpty, "its generation keeps running")
        return (f, original, body, sentBefore)
    }

    /// C4: one generation, the whole answer, sealed to the new session key, under the new request id.
    @Test func theSurvivorsDispatchTakesTheWholeAnswerOfTheHeldGeneration() async throws {
        let (f, original, body, sentBefore) = try await heldRequest()
        f.h.engine.token(0)   // generated while no coordinator could receive it
        let survivor = NodeKeyPair.generate()
        try await f.dispatch("survivor", body: body, session: survivor)
        #expect(f.outbound.accepted("survivor") == 1)
        try #require(await resumeEventually { f.outbound.contentFrames("survivor", survivor) == 2 },
                     "every token, from the first, reached the new dispatch")
        f.h.engine.finish(0)
        try #require(await resumeEventually { f.outbound.completion("survivor") != nil }, "the new dispatch completed")

        #expect(f.h.engine.submittedCount == 1, "one generation")
        #expect(f.outbound.chunks("held").count == sentBefore, "nothing more went out under the old request id")
        #expect(f.outbound.terminals("held") == 0, "the old request id is forgotten")
        let chunks = f.outbound.chunks("survivor")
        let providerKey = await f.loop.keyPair.publicKeyBase64
        #expect(chunks.allSatisfy { $0.ephemeralPublicKey == providerKey }, "sealed with the static key K as sender")
        #expect(f.outbound.frames("survivor", original) == nil, "the dead coordinator's session key opens none of them")
        let frames = try #require(f.outbound.frames("survivor", survivor))
        let oldFrames = try #require(f.outbound.frames("held", original))
        #expect(Array(frames.prefix(oldFrames.count)) == oldFrames, "the resend starts with the first chunk")

        let completion = try #require(f.outbound.completion("survivor"))
        #expect(completion.usage.resumed, "the terminal says it was resumed")
        let encoded = try #require(String(data: try JSONEncoder().encode(completion.usage), encoding: .utf8))
        #expect(encoded.contains(#""resumed":true"#))
        let sealed = try #require(completion.encryptedUsage)
        let usage = try JSONDecoder().decode(SealedResponseUsage.self, from: try survivor.decryptPayload(sealed))
        #expect(usage.frameCount == UInt64(chunks.count), "the sealed usage follows every resent chunk")
        #expect(usage.usage.resumed)
        let text = frames.compactMap { ProviderLoop.parseStreamChunk($0)?.contentDelta }.joined()
        #expect(completion.responseHash == computeResponseAttestation(
            identity: nil, requestId: "survivor", completionTokens: completion.usage.completionTokens,
            responseBody: text).hash, "the response hash binds the new request id")
        #expect(await f.loop.state.resumableRequests.isEmpty)
        try #require(await resumeEventually { await f.loop.resumableRequests.isEmpty }, "nothing is held any more")
        await f.h.remove()
    }

    /// A held generation that ends before any dispatch takes it keeps its answer for the window after its end; the
    /// dispatch then gets every chunk and the terminal at once.
    @Test func aHeldAnswerThatEndedGoesWholeAndTheWindowCountsFromItsEnd() async throws {
        let (f, _, body, _) = try await heldRequest()
        let window = await f.loop.requestResumeWindow
        let beforeEnd = ContinuousClock.now
        f.h.engine.finish(0)
        try #require(await resumeEventually { await f.loop.resumableRequests["held"]?.taskFinished == true },
                     "the generation ended while held")
        await f.loop.expireHeldRequests(now: beforeEnd + window)
        #expect(await f.loop.state.resumableRequests == [Self.resumeID], "W from the end, not from the disconnect")

        let survivor = NodeKeyPair.generate()
        try await f.dispatch("survivor", body: body, session: survivor)
        #expect(f.outbound.contentFrames("survivor", survivor) == 1)
        #expect(f.outbound.completion("survivor")?.usage.resumed == true)
        #expect(f.outbound.terminals("held") == 0)
        #expect(await f.loop.resumableRequests.isEmpty)
        await f.h.remove()
    }

    /// W counts from the disconnect the connection-control reader stamped (`noteCoordinatorDisconnect`), not from
    /// when the work loop gets to `handleCoordinatorDisconnected`; queued disconnects keep their own stamps, oldest
    /// first.
    @Test func theWindowCountsFromTheStampedDisconnectNotFromTheLateHandler() async throws {
        let f = try await Fixture.make(slots: 8)
        let session = NodeKeyPair.generate()
        try await f.dispatchReachingEngine("held", body: try Fixture.body(), session: session)
        f.h.engine.token(0)
        try #require(await resumeEventually { f.outbound.contentFrames("held", session) == 1 })
        let window = await f.loop.requestResumeWindow
        let disconnectedAt = ContinuousClock.now - .seconds(10)   // the reader saw the socket end 10 s ago
        await f.loop.noteCoordinatorDisconnect(at: disconnectedAt)
        await f.loop.noteCoordinatorDisconnect(at: disconnectedAt + .seconds(5))   // a second one, queued behind it
        await f.loop.handleCoordinatorDisconnected()   // the work loop handles the first only now
        #expect(await f.loop.resumableRequests["held"]?.heldSince == disconnectedAt, "held from the first stamp")
        #expect(await f.loop.coordinatorDisconnectStamps == [disconnectedAt + .seconds(5)], "the second waits")

        await f.loop.expireHeldRequests(now: disconnectedAt + window - .milliseconds(1))
        #expect(f.h.engine.cancelledIndices.isEmpty)
        // 5 s after the late handler ran, W from the stamp has passed.
        await f.loop.expireHeldRequests(now: disconnectedAt + window)
        #expect(await resumeEventually { f.h.engine.cancelledIndices == [0] }, "it ends at disconnect + W")
        await f.loop.handleCoordinatorDisconnected()
        #expect(await f.loop.coordinatorDisconnectStamps.isEmpty, "each handler takes its own stamp")
        await f.h.remove()
    }

    /// Past 64 queued disconnects the newest stamps are not kept: the queue stays bounded and drains, and an
    /// overflowed disconnect's hold starts when its handler runs, which is late, never before the real disconnect.
    @Test func overflowedDisconnectStampsAreLateNeverEarly() async throws {
        let f = try await Fixture.make(slots: 8)
        let session = NodeKeyPair.generate()
        try await f.dispatchReachingEngine("held", body: try Fixture.body(), session: session)
        f.h.engine.token(0)
        try #require(await resumeEventually { f.outbound.contentFrames("held", session) == 1 })
        // Every disconnect lies in the past and inside W, so the expiry timer leaves the hold alone: a hold whose
        // stamp is older than W is cancelled at once, as it must be.
        let base = ContinuousClock.now - .seconds(1)
        let disconnects = (0..<70).map { base + .milliseconds(10 * $0) }
        for instant in disconnects { await f.loop.noteCoordinatorDisconnect(at: instant) }
        #expect(await f.loop.coordinatorDisconnectStamps == Array(disconnects.prefix(64)), "bounded at 64, oldest kept")

        for index in 0..<64 {
            await f.loop.handleCoordinatorDisconnected()
            #expect(await f.loop.coordinatorDisconnectStamps == Array(disconnects[(index + 1)..<64]),
                    "handler \(index) takes its own stamp")
        }
        #expect(await f.loop.resumableRequests["held"]?.heldSince == disconnects[0],
                "held from its own disconnect; a later handler never stamps it again")
        #expect(await f.loop.coordinatorDisconnectStamps.isEmpty, "the queue drains")

        // The 65th disconnect's stamp was not kept: its handler holds from when it runs.
        let other = String(repeating: "7a", count: 32)
        try await f.dispatchReachingEngine("late", body: try Fixture.body(resumeID: other), session: session)
        f.h.engine.token(1)
        try #require(await resumeEventually { f.outbound.contentFrames("late", session) == 1 })
        await f.loop.handleCoordinatorDisconnected()
        let lateHeldSince = try #require(await f.loop.resumableRequests["late"]?.heldSince)
        #expect(lateHeldSince >= disconnects[64], "an overflowed hold starts late, never before its disconnect")
        #expect(await f.loop.resumableRequests["held"]?.heldSince == disconnects[0])
        #expect(await f.loop.coordinatorDisconnectStamps.isEmpty)
        await f.h.remove()
    }

    /// C6: nothing takes the held request; at W it is cancelled as a lost connection and sends nothing.
    @Test func anUnmatchedHeldRequestEndsAtTheWindowUnanswered() async throws {
        let (f, _, body, sentBefore) = try await heldRequest()
        let window = await f.loop.requestResumeWindow
        await f.loop.expireHeldRequests(now: .now + window - .seconds(1))
        #expect(f.h.engine.cancelledIndices.isEmpty, "held until W")

        await f.loop.expireHeldRequests(now: .now + window + .seconds(1))
        #expect(await resumeEventually { f.h.engine.cancelledIndices == [0] }, "cancelled at W")
        try #require(await resumeEventually { await !f.loop.hasInflightTaskForTesting("held") }, "its task ended")
        #expect(f.outbound.chunks("held").count == sentBefore)
        #expect(f.outbound.terminals("held") == 0, "no completion: its output is dropped, unpaid")
        var lost = EndedEarlyCounts()
        lost.connectionLost = 1
        #expect(await f.loop.stats.endedEarly == lost, "cause connectionLost")
        #expect(await f.loop.state.resumableRequests.isEmpty)

        try await f.dispatchReachingEngine("late", body: body, session: NodeKeyPair.generate())
        #expect(f.outbound.accepted("late") == 1, "a dispatch after W runs as new")
        await f.h.remove()
    }

    /// C7: the dead coordinator's frame written again on the new socket takes nothing: under its own id it gets no
    /// answer, and under another id its session key is the held one's, so it runs as new. The survivor's dispatch then
    /// takes the held answer.
    @Test func aReplayedOriginalFrameDoesNotTakeTheHeldAnswer() async throws {
        let f = try await Fixture.make(slots: 8)
        let original = NodeKeyPair.generate()
        let body = try Fixture.body()
        let frame = try await f.dispatchReachingEngine("held", body: body, session: original)
        f.h.engine.token(0)
        try #require(await resumeEventually { f.outbound.contentFrames("held", original) == 1 })
        let sentBefore = f.outbound.chunks("held").count
        await f.loop.handleCoordinatorDisconnected()

        try await f.dispatch("held", body: body, session: original, ciphertext: frame)
        #expect(f.outbound.accepted("held") == 1 && f.outbound.chunks("held").count == sentBefore,
                "the copy under the held id gets no answer")
        #expect(f.h.engine.submittedCount == 1)

        try await f.dispatchReachingEngine("copy", body: body, session: original, ciphertext: frame)
        #expect(f.outbound.accepted("copy") == 1 && f.outbound.contentFrames("copy", original) == 0,
                "the copy under another id runs as new, with nothing of the held answer")

        let survivor = NodeKeyPair.generate()
        try await f.dispatch("survivor", body: body, session: survivor)
        #expect(f.outbound.contentFrames("survivor", survivor) == 1, "the survivor's dispatch then takes it")
        #expect(f.h.engine.submittedCount == 2)
        await f.h.remove()
    }

    /// A request without a resume id is cancelled at the disconnect, as before; a resumable one beside it is held.
    @Test func aRequestWithoutAResumeIDIsCancelledAtTheDisconnect() async throws {
        let f = try await Fixture.make(slots: 8)
        let session = NodeKeyPair.generate()
        try await f.dispatchReachingEngine("plain", body: try Fixture.body(resumeID: nil), session: session)
        try await f.dispatchReachingEngine("resumable", body: try Fixture.body(), session: session)
        f.h.engine.token(0)
        f.h.engine.token(1)
        try #require(await resumeEventually {
            f.outbound.contentFrames("plain", session) == 1 && f.outbound.contentFrames("resumable", session) == 1
        })
        await f.loop.handleCoordinatorDisconnected()
        #expect(await resumeEventually { f.h.engine.cancelledIndices == [0] }, "the plain request is cancelled at once")
        #expect(await resumeEventually { f.outbound.terminals("plain") == 1 })
        #expect(f.outbound.terminals("resumable") == 0)
        #expect(await f.loop.state.resumableRequests == [Self.resumeID])
        await f.h.remove()
    }

    /// Each failed check of the attach runs the dispatch as new, and leaves the held request for the dispatch that
    /// matches; a second dispatch with the same resume id runs as new.
    @Test func eachFailedCheckRunsTheDispatchAsNew() async throws {
        let (f, _, body, _) = try await heldRequest(slots: 16)
        var submitted = 1
        func runsAsNew(_ id: String, body: Data, scope: String? = Fixture.scope, nonce: String? = nil,
                       gemma: Int? = nil, signature: CoordinatorSignatureCheck = .notChecked) async throws {
            let session = NodeKeyPair.generate()
            try await f.dispatchReachingEngine(id, body: body, session: session, scope: scope,
                                               nonce: nonce, gemma: gemma, signature: signature)
            submitted += 1
            #expect(f.h.engine.submittedCount == submitted, "\(id) runs as new")
            #expect(f.outbound.accepted(id) == 1)
            #expect(f.outbound.contentFrames(id, session) == 0, "\(id) got none of the held answer")
        }
        try await runsAsNew("other-body", body: try Fixture.body(content: "another prompt"))
        try await runsAsNew("other-scope", body: body, scope: "another-tenant")
        try await runsAsNew("other-contract", body: body, gemma: 2)
        try await runsAsNew("receipt-nonce", body: body, nonce: "a-new-attempt-nonce")
        try await runsAsNew("unsigned-under-pin", body: body, signature: .unsigned)

        let survivor = NodeKeyPair.generate()
        try await f.dispatch("survivor", body: body, session: survivor, signature: .verified)
        #expect(f.outbound.contentFrames("survivor", survivor) == 1, "a verified, matching dispatch attaches")
        #expect(f.h.engine.submittedCount == submitted)

        try await runsAsNew("second", body: body)
        await f.h.remove()
    }

    /// A request whose frame carries a receipt nonce has no receipt that could be bound to another dispatch's nonce:
    /// it is not held.
    @Test func aRequestWithAReceiptNonceIsCancelledAtTheDisconnect() async throws {
        let f = try await Fixture.make(slots: 8)
        let session = NodeKeyPair.generate()
        try await f.dispatchReachingEngine("nonce", body: try Fixture.body(), session: session, nonce: "attempt-nonce")
        f.h.engine.token(0)
        try #require(await resumeEventually { f.outbound.contentFrames("nonce", session) == 1 })
        #expect(await f.loop.state.resumableRequests.isEmpty)
        await f.loop.handleCoordinatorDisconnected()
        #expect(await resumeEventually { f.h.engine.cancelledIndices == [0] })
        await f.h.remove()
    }

    /// A frame or cancel that names the old request id reaches nothing; a cancel for the new dispatch stops the
    /// generation it took, and a second frame under the new dispatch's id gets no answer.
    @Test func cancelsAndCopiesFollowTheDispatchThatTookTheAnswer() async throws {
        let (f, _, body, _) = try await heldRequest()
        let survivor = NodeKeyPair.generate()
        let frame = try await f.dispatch("survivor", body: body, session: survivor)
        #expect(f.outbound.contentFrames("survivor", survivor) == 1)

        await f.loop.routeCoordinatorCancel("held", reason: .init(code: "client_gone_post", paid: true))
        try await Task.sleep(for: .milliseconds(200))
        #expect(f.h.engine.cancelledIndices.isEmpty, "a cancel for the forgotten id stops nothing")

        try await f.dispatch("survivor", body: body, session: survivor, ciphertext: frame)
        #expect(f.outbound.accepted("survivor") == 1 && f.h.engine.submittedCount == 1,
                "a copy of the survivor's frame gets no answer")

        await f.loop.routeCoordinatorCancel("survivor", reason: .init(code: "client_gone_post", paid: true))
        #expect(await resumeEventually { f.h.engine.cancelledIndices == [0] }, "a cancel for the new id stops it")
        #expect(await resumeEventually { f.outbound.terminals("survivor") == 1 }, "and it ends under the new id")
        #expect(f.outbound.terminals("held") == 0)
        await f.h.remove()
    }

    /// The dispatch that took a held answer is not resumed again: a second disconnect cancels its generation.
    @Test func aSecondDisconnectAfterAnAttachCancelsTheGeneration() async throws {
        let (f, _, body, _) = try await heldRequest()
        let survivor = NodeKeyPair.generate()
        try await f.dispatch("survivor", body: body, session: survivor)
        #expect(f.outbound.contentFrames("survivor", survivor) == 1)
        await f.loop.handleCoordinatorDisconnected()
        #expect(await resumeEventually { f.h.engine.cancelledIndices == [0] })
        #expect(await f.loop.state.resumableRequests.isEmpty)
        try #require(await resumeEventually { await f.loop.resumableRequests.isEmpty })
        #expect(f.outbound.terminals("survivor") == 0, "nothing goes to the dead connection")
        await f.h.remove()
    }

    /// At most as many requests are held as this Mac runs at once (and never more than 64): the newest. The
    /// registration lists them newest first.
    @Test func theHeldSetIsCappedAndListedNewestFirst() async throws {
        let f = try await Fixture.make(slots: 16)
        let cap = await f.loop.resumableRequestCap
        let session = NodeKeyPair.generate()
        let resumeIDs = (0...cap).map { String(format: "%064lx", $0 + 1) }
        for (index, resumeID) in resumeIDs.enumerated() {
            try await f.dispatchReachingEngine("r\(index)", body: try Fixture.body(resumeID: resumeID), session: session)
            f.h.engine.token(index)
            try #require(await resumeEventually { f.outbound.contentFrames("r\(index)", session) == 1 })
        }
        let newestFirst = Array(resumeIDs.reversed().prefix(cap))
        #expect(await f.loop.state.resumableRequests == newestFirst, "listed newest first, at most the cap")
        await f.loop.handleCoordinatorDisconnected()
        #expect(await resumeEventually { f.h.engine.cancelledIndices == [0] }, "the oldest one over the cap is cancelled")
        #expect(await f.loop.state.resumableRequests == newestFirst)
        await f.h.remove()
    }

    /// A request whose kept output passes the cap is no longer resumable: cancelled at the disconnect as before.
    @Test func aRequestOverTheOutputCapIsCancelledAtTheDisconnect() async throws {
        let f = try await Fixture.make(slots: 8)
        await f.loop.setRequestResumeMaxBufferedBytesForTesting(1)
        let session = NodeKeyPair.generate()
        try await f.dispatchReachingEngine("large", body: try Fixture.body(), session: session)
        f.h.engine.token(0)
        try #require(await resumeEventually { f.outbound.contentFrames("large", session) == 1 },
                     "a live request over the cap still streams")
        await f.loop.handleCoordinatorDisconnected()
        #expect(await resumeEventually { f.h.engine.cancelledIndices == [0] })
        #expect(await f.loop.state.resumableRequests.isEmpty)
        await f.h.remove()
    }

    /// The response path itself: past the cap, a live request still sends but can no longer be held, and a held
    /// one is dropped and stops.
    @Test func theResponsePathDropsItsOutputPastTheCap() throws {
        let provider = NodeKeyPair.generate()
        let session = NodeKeyPair.generate()
        func route() throws -> ResumableResponse {
            let route = ResumableResponse(requestId: "r", send: SendHandle { _ in }, maxBufferedBytes: 10)
            route.start(sealer: ResponseFrameSealer(
                keyPair: provider, sharedKey: try provider.precomputeSharedKey(recipientPublicKey: session.publicKeyBytes)))
            return route
        }
        let live = try route()
        #expect(live.emit("12345678901") == .sent)
        #expect(!live.hold(), "past the cap while live: never held")

        let held = try route()
        #expect(held.emit("12345") == .sent)
        #expect(held.hold())
        #expect(held.emit("123456") == .dropped, "past the cap while held: the generation stops")
        #expect(!held.isHeld)
    }

    // MARK: - The checks themselves

    @Test func theResumeIDIsSixtyFourLowercaseHexCharacters() throws {
        func probe(_ value: Any?) throws -> String? {
            var object: [String: Any] = ["model": "m"]
            if let value { object[RequestResume.sealedBodyMember] = value }
            return try JSONDecoder().decode(
                RequestResume.BodyProbe.self, from: JSONSerialization.data(withJSONObject: object)).value
        }
        #expect(RequestResume.sealedBodyMember == "_darkbloom_resume_id")
        #expect(try probe(Self.resumeID) == Self.resumeID)
        #expect(try probe(nil) == nil)
        #expect(try probe(Self.resumeID.uppercased()) == nil)
        #expect(try probe(String(Self.resumeID.dropLast())) == nil)
        #expect(try probe(Self.resumeID + "0") == nil)
        #expect(try probe(String(repeating: "g", count: 64)) == nil)
        #expect(try probe(42) == nil)
        #expect(ProviderLoop.decodeInboundChatRequestResumeID(Self.resumeID) == Self.resumeID)
    }

    @Test func theAttachChecksEachCondition() {
        let body = Data("{\"model\":\"m\"}".utf8)
        let outer = RequestResume.OuterFields(model: "m", cacheScope: "s", prefixCacheProtocol: nil,
            cacheReceiptBoundaryMode: nil, cacheRepeatedPrefixTokens: nil, toolSchemaMetadataProtocol: 1,
            gemmaPromptContract: nil)
        let held = RequestResume.Identity(resumeID: Self.resumeID, body: body, sessionKey: Data(repeating: 1, count: 32),
                                          outer: outer)
        func request(body: Data = body, key: UInt8 = 2, outer: RequestResume.OuterFields = outer) -> RequestResume.Identity {
            .init(resumeID: Self.resumeID, body: body, sessionKey: Data(repeating: key, count: 32), outer: outer)
        }
        func refusal(_ request: RequestResume.Identity, nonce: String? = nil,
                     signature: CoordinatorSignatureCheck = .notChecked, cluster: Bool = false) -> RequestResume.Refusal? {
            RequestResume.refusal(held: held, request: request, cacheReceiptNonce: nonce, signature: signature,
                                  clusterRequest: cluster)
        }
        #expect(refusal(request()) == nil)
        #expect(refusal(request(), signature: .verified) == nil)
        #expect(refusal(request(body: Data("{\"model\":\"m\" }".utf8))) == .body, "a byte of difference")
        #expect(refusal(request(key: 1)) == .sameSessionKey)
        var otherOuter = outer
        otherOuter.cacheRepeatedPrefixTokens = 0
        #expect(refusal(request(outer: otherOuter)) == .outerFields)
        #expect(refusal(request(), nonce: "n") == .receiptNonce)
        #expect(refusal(request(), signature: .unsigned) == .unsigned)
        #expect(refusal(request(), cluster: true) == .clusterRequest)
        #expect(held.bodyDigest.count == 32, "only the digest of the body is kept")
    }

    @Test func theDigestComparisonIsLengthCheckedAndExact() {
        let a = Data(repeating: 7, count: 32)
        var b = a
        #expect(RequestResume.constantTimeEqual(a, b))
        b[31] ^= 1
        #expect(!RequestResume.constantTimeEqual(a, b))
        #expect(!RequestResume.constantTimeEqual(a, a.prefix(31)))
    }
}

// MARK: - Fixture

private struct Fixture {
    static let scope = "resume-tenant"
    let h: MeFirstGiveWayTests.Harness
    let outbound = ResumeOutbound()
    var loop: ProviderLoop { h.loop }

    static func make(slots: Int) async throws -> Fixture {
        Fixture(h: try await MeFirstGiveWayTests.harness(meFirst: false, slots: slots))
    }

    static func body(resumeID: String? = RequestResumeTests.resumeID, content: String = "fixture") throws -> Data {
        var object: [String: Any] = [
            "model": MeFirstGiveWayTests.model, "messages": [["role": "user", "content": content]],
            "max_tokens": 8, "stream": true, "reasoning_parser": "none",
        ]
        if let resumeID { object[RequestResume.sealedBodyMember] = resumeID }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// The coordinator's frame for `body`, sealed with `session` (or the given `ciphertext`), through the handler.
    /// Returns the ciphertext.
    @discardableResult
    func dispatch(_ id: String, body: Data, session: NodeKeyPair, scope: String? = Fixture.scope, nonce: String? = nil,
                  gemma: Int? = nil, signature: CoordinatorSignatureCheck = .notChecked,
                  ciphertext: Data? = nil) async throws -> Data {
        let providerKey = await loop.keyPair.publicKeyBytes
        let sealed = try ciphertext ?? session.encrypt(recipientPublicKey: providerKey, plaintext: body)
        await loop.handleInferenceRequest(
            requestId: id, ciphertext: sealed, senderPublicKey: session.publicKeyBytes,
            cacheReceiptNonce: nonce, authenticatedCacheScope: scope, gemmaPromptContract: gemma,
            coordinatorSignature: signature, send: SendHandle(outbound.record))
        return sealed
    }

    /// `dispatch`, for a request that runs as new: it is in the engine when this returns.
    @discardableResult
    func dispatchReachingEngine(_ id: String, body: Data, session: NodeKeyPair, scope: String? = Fixture.scope,
                                nonce: String? = nil, gemma: Int? = nil,
                                signature: CoordinatorSignatureCheck = .notChecked,
                                ciphertext: Data? = nil) async throws -> Data {
        let submitted = h.engine.submittedCount
        let sealed = try await dispatch(id, body: body, session: session, scope: scope, nonce: nonce, gemma: gemma,
                                        signature: signature, ciphertext: ciphertext)
        let engine = h.engine
        try #require(await resumeEventually { engine.submittedCount == submitted + 1 }, "\(id) reached the engine")
        return sealed
    }
}

/// Everything the loop sends the coordinator, in order.
private final class ResumeOutbound: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [OutboundMessage] = []
    func record(_ message: OutboundMessage) { lock.withLock { messages.append(message) } }
    private var all: [OutboundMessage] { lock.withLock { messages } }

    func chunks(_ id: String) -> [EncryptedPayload] {
        all.compactMap {
            if case .inferenceChunk(let request, _, let encrypted?) = $0, request == id { return encrypted }
            return nil
        }
    }

    /// The plaintext of every chunk of `id`, nil when `receiver` cannot open one of them.
    func frames(_ id: String, _ receiver: NodeKeyPair) -> [String]? {
        var frames: [String] = []
        for chunk in chunks(id) {
            guard let raw = try? receiver.decryptPayload(chunk), let frame = String(data: raw, encoding: .utf8)
            else { return nil }
            frames.append(frame)
        }
        return frames
    }

    /// The chunks of `id` that carried generated text.
    func contentFrames(_ id: String, _ receiver: NodeKeyPair) -> Int {
        (frames(id, receiver) ?? []).filter { $0.contains(#""content":"a""#) }.count
    }

    func accepted(_ id: String) -> Int {
        all.filter { if case .inferenceAccepted(let request) = $0 { return request == id } else { return false } }.count
    }

    func terminals(_ id: String) -> Int {
        all.filter {
            switch $0 {
            case .inferenceComplete(let request, _, _, _, _, _, _), .inferenceError(let request, _, _): return request == id
            default: return false
            }
        }.count
    }

    func completion(_ id: String) -> (usage: UsageInfo, responseHash: String?, encryptedUsage: EncryptedPayload?)? {
        for case .inferenceComplete(let request, let usage, _, _, let hash, _, let sealed) in all where request == id {
            return (usage, hash, sealed)
        }
        return nil
    }
}

/// Polls `condition` for up to 5 s of real time.
private func resumeEventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while await !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

private extension ProviderLoop {
    /// The resume id `decodeInboundChatRequest` reads from a body that carries `resumeID`.
    static func decodeInboundChatRequestResumeID(_ resumeID: String) -> String? {
        let body = try? JSONSerialization.data(withJSONObject: [
            "model": "m", "messages": [["role": "user", "content": "x"]], RequestResume.sealedBodyMember: resumeID,
        ])
        return body.flatMap { try? decodeInboundChatRequest($0).extensions.resumeID }
    }
}
#endif
