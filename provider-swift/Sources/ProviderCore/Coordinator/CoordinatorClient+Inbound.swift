// CoordinatorClient inbound dispatch: decode a coordinator text frame and turn it
// into a CoordinatorEvent (inference, cancel, attestation, load/prefetch, desired-models).

import Foundation
import Network

extension CoordinatorClient {
    /// An already-resumed old timer must not poison a replacement connection.
    /// The nonce check and refusal run without an actor suspension between them.
    internal func expireMemberNegotiation(nonce: String, now: ContinuousClock.Instant = .now) {
        guard !Task.isCancelled, !sessionRegistered,
              let current = memberNegotiation, current.nonce == nonce,
              now >= current.deadline else { return }
        // Still open at the end of its window: a coordinator that knows the
        // role has acknowledged or closed by now. One that answered the
        // registration as an ordinary provider's does not know the role; one
        // that answered nothing at all stays a refusal.
        if memberOrdinaryAnswer { memberRoleUnsupported = true }
        refuseMemberNegotiation()
    }
    internal func refuseMemberNegotiation() {
        memberRoleFailure = true
        sessionRegistered = false
        memberNegotiation = nil
        detachNativePairMember()
        nwConnection?.cancel()
    }

    /// Send a pre-encoded JSON frame on the current connection, if any. The
    /// receive path's rejections (missing/invalid encrypted body) are
    /// low-frequency, so routing them straight to the live NWConnection — rather
    /// than through the outbound stream — keeps them adjacent to the decode that
    /// produced them, matching the old direct `ws.send` on this path.
    private func sendOnCurrentConnection(_ json: String, identifier: String) {
        guard let connection = nwConnection else { return }
        sendTextFrame(json, on: connection, identifier: identifier)
    }

    private func rejectInvalidInferenceRequest(requestId: String, profile: RequestProfileBuilder,
        serviceReservationID: String?) {
        refuseInferenceBeforeDispatch(requestId: requestId,
            failure: InferenceFailure(code: .invalidRequest, statusCode: 400),
            profile: profile.wireObject(), serviceReservationID: serviceReservationID)
    }

    /// Refuse an inference request on the receive path. This frame never
    /// enters the provider request pipeline, so no later bridge submission can
    /// acquire service for its attempt: its reservation is released at once.
    private func refuseInferenceBeforeDispatch(requestId: String, failure: InferenceFailure,
        profile: InferenceProfile? = nil, serviceReservationID: String?) {
        sendOnCurrentConnection(
            encodeInferenceError(requestId: requestId, failure: failure, profile: profile),
            identifier: "inference_error")
        if let id = ServiceReservationLifetime.normalizedID(serviceReservationID) {
            outboundRouter.yield(.serviceReservationReleased(serviceReservationID: id))
        }
    }

    internal func handleIncomingFrame(
        _ data: Data,
        receivedAt: ContinuousClock.Instant,
        profileAnchor: SuspendingClock.Instant = .now,
        connection: NWConnection? = nil
    ) async {
        // Native-pair public frames are consumed before the ordinary codec on
        // member connections; solo connections never carry them. One that
        // breaks the contract ends this connection.
        if config.executionRole == .clusterMember {
            do {
                let wall = Date().timeIntervalSince1970 * 1_000_000_000
                guard wall > 0, wall < Double(Int64.max) else { throw NativePairMemberError.deadline }
                if try consumeNativePairFrame(data, sourceConnection: connection,
                    receivedAt: DispatchTime.now().uptimeNanoseconds, wallUnixNanoseconds: Int64(wall)) { return }
            } catch {
                detachNativePairMember()
                connection?.cancel()
                return
            }
        }
        let parsed: CoordinatorMessage
        do {
            parsed = try CoordinatorClientCodec.decodeIncomingMessage(from: data)
        } catch {
            logger.warning("Failed to parse coordinator message")
            return
        }

        // A member that lost trust or runtime verification may not keep an
        // attachment: its session's native work is cancelled at once.
        if case .trustStatus(let status) = parsed, ["untrusted", "offline"].contains(status.status) { detachNativePairMember() }
        // Only the connected coordinator's latest `trust_status` says whether
        // it decays a stale decode rate (`DecodeRateIdleAge.coordinatorDecays`).
        if case .trustStatus(let status) = parsed {
            DecodeRateIdleAge.coordinatorDecays.update(features: status.coordinatorFeatures)
        }
        if case .runtimeStatus(let status) = parsed, !status.verified || !status.mismatches.isEmpty { detachNativePairMember() }
        // A coordinator that does not know the member role answers its
        // registration like any provider's (desired builds, challenges...).
        if config.executionRole == .clusterMember, memberNegotiation != nil, !sessionRegistered {
            if case .clusterMemberAccepted = parsed {} else { memberOrdinaryAnswer = true }
        }
        switch parsed {
        case .clusterMemberAccepted(let ack):
            guard config.executionRole == .clusterMember else { return }
            do {
                guard var negotiation = memberNegotiation else { throw ClusterMemberControlError.negotiationFailed }
                try negotiation.accept(ack)
                memberNegotiation = negotiation
                sessionRegistered = true
                try nativePairMemberAccepted()
                // The connection's first heartbeat goes at once, after the
                // attachment so it reports a resumed session's
                // `cluster_session`: the coordinator dispatches to the pair
                // only after a heartbeat from each member. The baseline
                // timer's first send is one interval after registration, the
                // session watch reports only a change, and the loop's
                // `.connected` heartbeat can wait behind disconnect cleanup in
                // its work queue.
                sendEventHeartbeat()
                eventContinuation?.yield(.connected)
            } catch { refuseMemberNegotiation() }

        case .modelsReplaceAck(let ack):
            completeModelReplacement(ack)
        case .modelsReplaceResumed(let ack):
            completeModelReplacementReadiness(ack)
        case .drainAck(let id):
            if drainAcknowledgements[id] != nil { eventContinuation?.yield(.drainAck(id)) }
        case .inferenceRequest(let request):
            let requestId = request.requestId
            // A member serving its pair slot (S09) hands the request to the
            // loop like any provider; every other member refuses it here.
            if config.executionRole == .clusterMember, state.memberPairSlotModel == nil {
                refuseInferenceBeforeDispatch(requestId: requestId,
                    failure: InferenceFailure(code: .modelUnavailable, statusCode: 503),
                    serviceReservationID: request.serviceReservationID)
                return
            }
            // The receive callback anchored this before executor scheduling,
            // UTF-8 materialization, JSON parsing, logging, validation, or
            // base64 decoding. Downstream work must not restart the clock.
            let firstContentDeadline = request.firstContentBudgetMs.map {
                FirstContentDeadline(
                    relativeBudgetMilliseconds: $0,
                    receivedAt: receivedAt)
            }
            // Profiler accumulator, created UNCONDITIONALLY (a request without
            // a first-content budget still gets a profile) and anchored on the
            // suspending instant taken in the receive callback.
            let profile = RequestProfileBuilder(
                suspendingAnchor: profileAnchor,
                continuousAnchor: receivedAt)
            logger.info("Received inference request: \(requestId)")

            guard let encrypted = request.encryptedBody else {
                logger.error("Rejecting plaintext inference request: \(requestId)")
                rejectInvalidInferenceRequest(requestId: requestId, profile: profile,
                    serviceReservationID: request.serviceReservationID)
                return
            }

            // Decode the wire form here so consumers don't have to. NaCl box
            // wire format is `base64(nonce ‖ tag ‖ body)`; we strip base64
            // once and pass raw bytes upstream. Same for the sender's
            // ephemeral pubkey (32 bytes).
            guard let cipherBytes = Data(base64Encoded: encrypted.ciphertext) else {
                logger.error("Rejecting inference request \(requestId): ciphertext is not valid base64")
                rejectInvalidInferenceRequest(requestId: requestId, profile: profile,
                    serviceReservationID: request.serviceReservationID)
                return
            }
            guard let senderKeyBytes = Data(base64Encoded: encrypted.ephemeralPublicKey),
                  senderKeyBytes.count == 32 else {
                logger.error("Rejecting inference request \(requestId): invalid ephemeral public key")
                rejectInvalidInferenceRequest(requestId: requestId, profile: profile,
                    serviceReservationID: request.serviceReservationID)
                return
            }
            if config.requestVerifier.checksRequests, let refusal = config.requestVerifier.check(
                request, senderPublicKey: senderKeyBytes, ciphertext: cipherBytes,
                recipientPublicKey: config.publicKey.flatMap { Data(base64Encoded: $0) },
                now: Date(), served: &servedSignedRequests) {
                logger.error("Rejecting inference request \(requestId): coordinator signature \(refusal.rawValue)")
                // A second copy of a request already served gets no answer:
                // an error or a release would end the copy being served.
                if refusal != .alreadyServed {
                    refuseInferenceBeforeDispatch(requestId: requestId,
                        failure: InferenceFailure(code: .encryptionFailure, statusCode: 502),
                        profile: profile.wireObject(), serviceReservationID: request.serviceReservationID)
                }
                return
            }

            // A repeat of a blind request already served gets no answer: an
            // answer would end the copy being served. Its checks run in full
            // in the handler.
            if let blind = request.blind, let pins = config.blindRequests?.pins,
               let ownKey = config.publicKey.flatMap({ Data(base64Encoded: $0) }),
               case .success(let signature) = CoordinatorRequestJWS.verify(
                   blind.signedRequest, pins: pins, requestID: requestId,
                   serviceReservationID: request.serviceReservationID, recipientPublicKey: ownKey,
                   senderPublicKey: senderKeyBytes, ciphertext: cipherBytes, now: Date()),
               !servedBlindRequests.admitBlindSignature(signature, now: Date()) {
                logger.error("Ignoring a repeat of blind request \(requestId)")
                return
            }

            eventContinuation?.yield(.inferenceRequest(
                requestId: requestId,
                ciphertext: cipherBytes,
                senderPublicKey: senderKeyBytes,
                cacheReceiptNonce: request.cacheReceiptNonce,
                cacheScope: request.cacheScope,
                prefixCacheProtocol: request.prefixCacheProtocol,
                cacheReceiptBoundaryMode: request.cacheReceiptBoundaryMode,
                cacheRepeatedPrefixTokens: request.cacheRepeatedPrefixTokens,
                toolSchemaMetadataProtocol: request.toolSchemaMetadataProtocol,
                firstContentDeadline: firstContentDeadline,
                receivedAt: receivedAt,
                profile: profile,
                serviceReservationID: request.serviceReservationID,
                promptWork: request.promptWork,
                gemmaPromptContract: request.gemmaPromptContract,
                frameCachePolicy: request.frameCachePolicy,
                blind: request.blind
            ))

        case .cancel(let cancel):
            let requestId = cancel.requestId
            logger.info("Received cancel for: \(requestId)")
            eventContinuation?.yield(.cancel(requestId: requestId, reason: cancel.reason))

        case .capacityProbe(let probe):
            // Routing v2: answer from the lock-free published snapshot — the
            // capacity payload of the last heartbeat this connection sent —
            // plus the advertised catalog and the TTFT tracker. No hop to the
            // ProviderLoop or engine actors, no inference, no model load, no
            // KV allocation: a probe storm costs this connection some JSON,
            // never admission or decode throughput.
            let published = state.publishedCapacity
            let slot = published?.slots.first { $0.model == probe.model }
            let ttft = state.ttftTracker.estimate(
                model: probe.model,
                warm: slot != nil,
                promptBucket: TTFTQuantileTracker.promptBucket(
                    forPromptTokens: probe.promptTokensBucket),
                batchBucket: TTFTQuantileTracker.batchBucket(
                    forActiveRequests: Int(slot?.numRunning ?? 0)))
            let quote = CapacityQuoteEngine.quote(CapacityQuoteEngine.Inputs(
                probe: probe,
                capacity: published,
                model: advertisedModelStore.models.first { $0.id == probe.model },
                ttft: ttft,
                visionLimits: VisionTowerBudget.liveLimits,
                refusingNewWork: state.refusingNewWork(forModel: probe.model)))
            do {
                let json = try ProviderProtocolCodec.encodeProviderMessageString(
                    .capacityQuote(quote))
                sendOnCurrentConnection(json, identifier: "capacity_quote")
            } catch {
                // A quote is advisory; the coordinator treats a missing one
                // as a timeout/demotion. Never tear anything down for it.
                logger.warning("Failed to encode capacity quote")
            }

        case .attestationChallenge(let challenge):
            logger.info(.attestationChallengeReceived)
            eventContinuation?.yield(.attestationChallenge(
                nonce: challenge.nonce,
                timestamp: challenge.timestamp
            ))

        case .appAttestShadow(let payload):
            guard let connection, nwConnection === connection, sessionRegistered, !shutdownRequested else { return }
            eventContinuation?.yield(.appAttestShadow(payload,
                reply: appAttestShadowReply(to: payload, on: connection)))

        case .appAttestResume(let challenge):
            if let connection { answerAppAttestResume(challenge, on: connection) }

        case .codeAttestationResumeChallenge(let challenge):
            eventContinuation?.yield(
                .codeAttestationResumeChallenge(challenge.codeChallenge))

        case .runtimeStatus(let status):
            if status.verified {
                logger.info(.runtimeIntegrityVerified)
            } else {
                logger.warning(.runtimeIntegrityFailed)
                logger.warning("Runtime integrity check FAILED -- \(status.mismatches.count) mismatch(es)")
                for m in status.mismatches {
                    logger.warning("  \(m.component): expected=\(m.expected), got=\(m.got)")
                }
                eventContinuation?.yield(.runtimeOutdated(mismatches: status.mismatches))
            }

        case .modelAutopilotControl(let control):
            eventContinuation?.yield(.modelAutopilotControl(control))
        case .modelAutopilot(let command):
            eventContinuation?.yield(.modelAutopilot(command))

        case .loadModel(let load):
            logger.info("Received coordinator-driven preload for: \(load.modelId)")
            eventContinuation?.yield(.loadModel(modelId: load.modelId))

        case .prefetchModel(let pf):
            // Background download-only request. Forwarded to ProviderLoop, which
            // downloads + verifies the build on disk (no GPU load) and replies
            // with prefetch_model_status messages.
            logger.info("Received coordinator-driven prefetch for: \(pf.modelId) (priority=\(pf.priority))")
            eventContinuation?.yield(.prefetchModel(modelId: pf.modelId, priority: pf.priority))

        case .desiredModels(let dm):
            // Declarative desired-state. ProviderLoop reconciles each entry:
            // prefetch the desired build if missing, then hard-swap once verified.
            logger.info("Received desired_models from coordinator: \(dm.models.count) entr(ies)")
            eventContinuation?.yield(.desiredModels(entries: dm.models))

        case .trustStatus(let ts):
            // ProviderLoop logs decision changes; periodic lease renewals
            // still reach the state file without duplicate log messages.
            eventContinuation?.yield(.trustStatus(
                trustLevel: ts.trustLevel,
                status: ts.status,
                reason: ts.reason,
                authorization: ts.authorization
            ))
        }
    }

}
