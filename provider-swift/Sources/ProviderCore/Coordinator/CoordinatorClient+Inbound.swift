// CoordinatorClient inbound dispatch: decode a coordinator text frame and turn it
// into a CoordinatorEvent (inference, cancel, attestation, load/prefetch, desired-models).

import Foundation
import Network

#if canImport(os)
import os
#endif

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

    internal func handleIncomingText(_ text: String) async {
        guard let data = text.data(using: .utf8) else { return }

        let parsed: CoordinatorMessage
        do {
            parsed = try CoordinatorClientCodec.decodeIncomingMessage(
                from: data,
                negotiatedV2Session: v2Negotiation.session != nil
            )
        } catch {
            logger.warning("Failed to parse coordinator message: \(error.localizedDescription)")
            return
        }

        if case .registerAck(let acknowledgement) = parsed {
            do {
                let session = try v2Negotiation.accept(acknowledgement)
                if let session {
                    markRegistrationSucceeded()
                    guard publishV2SessionEvent(.negotiated(session)) else {
                        return
                    }
                    logger.info(
                        "Negotiated protocol v2.\(session.capabilities.protocolMinor) for session \(session.identity.sessionEpoch)"
                    )
                } else {
                    logger.info("Coordinator explicitly selected protocol v1")
                }
            } catch {
                logger.warning("Rejected protocol negotiation: \(error)")
            }
            return
        }

        if let command = CoordinatorClientCodec.v2ControlMessage(from: parsed) {
            do {
                try v2Negotiation.validate(command)
                guard let session = v2Negotiation.session else {
                    throw V2NegotiationError.commandBeforeNegotiation
                }
                let result = v2CommandContinuation.yield(
                    V2InboundCommand(
                        session: session,
                        command: command
                    ))
                if case .dropped(let dropped) = result,
                    dropped.session == session
                {
                    failCurrentV2SessionForInboundOverflow(kind: "control")
                }
            } catch {
                logger.warning("Rejected protocol-v2 command: \(error)")
            }
            return
        }

        switch parsed {
        case .inferenceRequest(let request):
            let requestId = request.requestId
            logger.info("Received inference request: \(requestId)")

            guard let encrypted = request.encryptedBody else {
                logger.error("Rejecting plaintext inference request: \(requestId)")
                let errorResponse = encodeInferenceError(
                    requestId: requestId,
                    error: "coordinator text request missing encrypted body",
                    statusCode: 400
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
                    error: "ciphertext is not valid base64",
                    statusCode: 400
                )
                sendOnCurrentConnection(errorResponse, identifier: "inference_error")
                return
            }
            let senderKeyBytes = Data(base64Encoded: encrypted.ephemeralPublicKey)
            if senderKeyBytes == nil || senderKeyBytes?.count != 32 {
                logger.error("Rejecting inference request \(requestId): invalid ephemeral public key")
                let errorResponse = encodeInferenceError(
                    requestId: requestId,
                    error: "invalid ephemeral_public_key",
                    statusCode: 400
                )
                sendOnCurrentConnection(errorResponse, identifier: "inference_error")
                return
            }

            eventContinuation?.yield(
                .inferenceRequest(
                requestId: requestId,
                ciphertext: cipherBytes,
                senderPublicKey: senderKeyBytes
            ))

        case .cancel(let cancel):
            let requestId = cancel.requestId
            logger.info("Received cancel for: \(requestId)")
            eventContinuation?.yield(.cancel(requestId: requestId))

        case .attestationChallenge(let challenge):
            logger.info("Received attestation challenge")
            eventContinuation?.yield(
                .attestationChallenge(
                nonce: challenge.nonce,
                timestamp: challenge.timestamp
            ))

        case .runtimeStatus(let status):
            if status.verified {
                logger.info("Runtime integrity verified by coordinator")
            } else {
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
            logger.info(
                "Received coordinator-driven prefetch for: \(pf.modelId) (priority=\(pf.priority))")
            eventContinuation?.yield(.prefetchModel(modelId: pf.modelId, priority: pf.priority))

        case .desiredModels(let dm):
            // Declarative desired-state. ProviderLoop reconciles each entry:
            // prefetch the desired build if missing, then hard-swap once verified.
            logger.info("Received desired_models from coordinator: \(dm.models.count) entr(ies)")
            eventContinuation?.yield(.desiredModels(entries: dm.models))

        case .trustStatus(let ts):
            logger.info(
                "Trust status from coordinator: level=\(ts.trustLevel) status=\(ts.status) reason=\(ts.reason)"
            )
            eventContinuation?.yield(
                .trustStatus(
                trustLevel: ts.trustLevel,
                status: ts.status,
                reason: ts.reason
            ))
        case .registerAck, .prepare, .start, .queryAttempt, .abort, .v2Cancel,
            .terminalAck, .coordinatorReplayFence:
            // Handled by the negotiated-v2 gates above.
            return
        }
        }

    internal func handleIncomingBinary(_ data: Data) async {
        guard data.count <= maximumV2BinaryFrameLength else {
            logger.warning(
                "Rejected oversized protocol-v2 binary frame: \(data.count) bytes"
            )
            return
        }
        do {
            let frame = try V2BinaryFrame.decode(data)
            try v2Negotiation.validateInboundBinary(frame.header)
            guard let session = v2Negotiation.session else {
                throw V2NegotiationError.commandBeforeNegotiation
            }
            let result = v2BinaryContinuation.yield(
                V2InboundBinaryFrame(
                    session: session,
                    frame: frame,
                    wire: data
                ))
            if case .dropped(let dropped) = result,
                dropped.session == session
            {
                failCurrentV2SessionForInboundOverflow(kind: "binary")
            }
        } catch {
            logger.warning("Rejected protocol-v2 binary frame: \(error)")
        }
    }

    internal func isCurrentV2Delivery(_ delivery: V2InboundCommand) -> Bool {
        do {
            try v2Negotiation.validate(delivery)
            return true
        } catch {
            logger.warning("Dropped queued protocol-v2 command from stale session: \(error)")
            return false
        }
    }

    internal func isCurrentV2Delivery(_ delivery: V2InboundBinaryFrame) -> Bool {
        do {
            try v2Negotiation.validate(delivery)
            return true
        } catch {
            logger.warning("Dropped queued protocol-v2 binary frame from stale session: \(error)")
            return false
        }
    }

    /// Losing a paid control or binary frame is not recoverable inside the
    /// current session. End its identity fence immediately and force the
    /// WebSocket to reconnect; queued deliveries then fail their second
    /// current-session validation instead of executing an incomplete history.
    private func failCurrentV2SessionForInboundOverflow(kind: String) {
        guard v2Negotiation.session != nil else { return }
        logger.error("Protocol-v2 \(kind) stream overflow; failing session closed")
        resetV2NegotiationForReconnect()
        nwConnection?.cancel()
    }

}
