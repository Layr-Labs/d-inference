// CoordinatorClient inbound dispatch: decode a coordinator text frame and turn it
// into a CoordinatorEvent (inference, cancel, attestation, load/prefetch, desired-models).

import Foundation
import Network

extension CoordinatorClient {
    /// Send a pre-encoded JSON frame on the current connection, if any. The
    /// receive path's rejections (missing/invalid encrypted body) are
    /// low-frequency, so routing them straight to the live NWConnection — rather
    /// than through the outbound stream — keeps them adjacent to the decode that
    /// produced them, matching the old direct `ws.send` on this path.
    private func sendOnCurrentConnection(_ json: String, identifier: String) {
        guard let connection = nwConnection else { return }
        sendTextFrame(json, on: connection, identifier: identifier)
    }

    internal func handleIncomingFrame(
        _ data: Data,
        receivedAt: ContinuousClock.Instant
    ) async {
        let parsed: CoordinatorMessage
        do {
            parsed = try CoordinatorClientCodec.decodeIncomingMessage(from: data)
        } catch {
            logger.warning("Failed to parse coordinator message")
            return
        }

        switch parsed {
        case .inferenceRequest(let request):
            let requestId = request.requestId
            // The receive callback anchored this before executor scheduling,
            // UTF-8 materialization, JSON parsing, logging, validation, or
            // base64 decoding. Downstream work must not restart the clock.
            let firstContentDeadline = request.firstContentBudgetMs.map {
                FirstContentDeadline(
                    relativeBudgetMilliseconds: $0,
                    receivedAt: receivedAt)
            }
            logger.info("Received inference request: \(requestId)")

            guard let encrypted = request.encryptedBody else {
                logger.error("Rejecting plaintext inference request: \(requestId)")
                let errorResponse = encodeInferenceError(
                    requestId: requestId,
                    failure: InferenceFailure(code: .invalidRequest, statusCode: 400)
                )
                sendOnCurrentConnection(errorResponse, identifier: "inference_error")
                return
            }

            // Decode the wire form here so consumers don't have to. NaCl box
            // wire format is `base64(nonce ‖ tag ‖ body)`; we strip base64
            // once and pass raw bytes upstream. Same for the sender's
            // ephemeral pubkey (32 bytes).
            guard let cipherBytes = Data(base64Encoded: encrypted.ciphertext) else {
                logger.error("Rejecting inference request \(requestId): ciphertext is not valid base64")
                let errorResponse = encodeInferenceError(
                    requestId: requestId,
                    failure: InferenceFailure(code: .invalidRequest, statusCode: 400)
                )
                sendOnCurrentConnection(errorResponse, identifier: "inference_error")
                return
            }
            let senderKeyBytes = Data(base64Encoded: encrypted.ephemeralPublicKey)
            if senderKeyBytes == nil || senderKeyBytes?.count != 32 {
                logger.error("Rejecting inference request \(requestId): invalid ephemeral public key")
                let errorResponse = encodeInferenceError(
                    requestId: requestId,
                    failure: InferenceFailure(code: .invalidRequest, statusCode: 400)
                )
                sendOnCurrentConnection(errorResponse, identifier: "inference_error")
                return
            }

            eventContinuation?.yield(.inferenceRequest(
                requestId: requestId,
                ciphertext: cipherBytes,
                senderPublicKey: senderKeyBytes,
                cacheReceiptNonce: request.cacheReceiptNonce,
                cacheScope: request.cacheScope,
                prefixCacheProtocol: request.prefixCacheProtocol,
                toolSchemaMetadataProtocol: request.toolSchemaMetadataProtocol,
                firstContentDeadline: firstContentDeadline,
                receivedAt: receivedAt
            ))

        case .cancel(let cancel):
            let requestId = cancel.requestId
            logger.info("Received cancel for: \(requestId)")
            eventContinuation?.yield(.cancel(requestId: requestId))

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
                refusingNewWork: state.refusingNewWork))
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
            logger.info("Trust status from coordinator: level=\(ts.trustLevel) status=\(ts.status) reason=\(ts.reason)")
            eventContinuation?.yield(.trustStatus(
                trustLevel: ts.trustLevel,
                status: ts.status,
                reason: ts.reason
            ))
        }
    }

}
