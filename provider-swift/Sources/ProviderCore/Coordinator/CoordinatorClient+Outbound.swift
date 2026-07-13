// CoordinatorClient outbound encoding: encode OutboundMessage values (incl. inference
// errors) to wire JSON, with encode-failure accounting.

import Foundation
import Network

#if canImport(os)
import os
#endif

extension CoordinatorClient {
    // MARK: - Outbound Encoding

    internal func allowsOutbound(_ message: OutboundMessage) -> Bool {
        if case .historicalProviderTerminal(let replay) = message {
            do {
                try v2Negotiation.validateHistoricalTerminal(replay)
                return true
            } catch {
                logger.warning("Rejected historical protocol-v2 terminal: \(error)")
                return false
            }
        }
        guard let v2 = CoordinatorClientCodec.v2ControlMessage(from: message) else {
            return true
        }
        do {
            try v2Negotiation.validate(v2)
            return true
        } catch {
            logger.warning("Rejected protocol-v2 outbound message: \(error)")
            return false
        }
    }

    /// Sends one already-sealed protocol-v2 frame with a WebSocket binary
    /// opcode. The complete bounded frame and its current session identity are
    /// validated before the transport is consulted.
    public func sendProtocolV2BinaryFrame(_ wire: Data) async throws {
        guard wire.count <= maximumV2BinaryFrameLength else {
            throw V2ProtocolError.ciphertextTooLarge(
                actual: wire.count - v2BinaryHeaderLength,
                maximum: maximumV2CiphertextLength
            )
        }
        let frame = try V2BinaryFrame.decode(wire)
        try v2Negotiation.validateOutboundBinary(frame.header)
        guard let connection = nwConnection else {
            throw CoordinatorError.noActiveConnection
        }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(
            identifier: "v2-binary",
            metadata: [metadata]
        )
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: wire,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(
                            throwing: CoordinatorError.connectionClosed(error)
                        )
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    /// Sends one protocol-v2 control frame and waits until Network.framework
    /// has accepted it. The prepared start path uses this completion-aware
    /// boundary so a direct binary response can never overtake `start_ack`.
    public func sendProtocolV2ControlMessage(
        _ message: OutboundMessage
    ) async throws {
        guard let v2 = CoordinatorClientCodec.v2ControlMessage(from: message) else {
            throw CoordinatorError.encodingFailed
        }
        try v2Negotiation.validate(v2)
        let data = try CoordinatorClientCodec.encodeOutboundMessage(message)
        try await sendProtocolV2TextData(data, identifier: "v2-control")
    }

    /// Completion-aware replay path for terminals whose original process or
    /// WebSocket session is no longer current. Every replay is validated by the
    /// sole historical-session exception before it reaches the transport.
    public func sendProtocolV2HistoricalTerminal(
        _ replay: V2HistoricalTerminalReplay
    ) async throws {
        try v2Negotiation.validateHistoricalTerminal(replay)
        let data = try CoordinatorClientCodec.encodeOutboundMessage(
            .historicalProviderTerminal(replay)
        )
        try await sendProtocolV2TextData(
            data,
            identifier: "v2-historical-terminal"
        )
    }

    /// Sends the typed rejection for a historical terminal ACK. The response
    /// intentionally carries the ACK's historical attempt identity, so it uses
    /// the narrow stable-provider exception instead of the normal current-
    /// session control validator.
    public func sendProtocolV2HistoricalStructuredError(
        _ error: V2StructuredError
    ) async throws {
        try v2Negotiation.validateHistoricalStructuredError(error)
        let data = try CoordinatorClientCodec.encodeOutboundMessage(
            .structuredError(error)
        )
        try await sendProtocolV2TextData(
            data,
            identifier: "v2-historical-structured-error"
        )
    }

    private func sendProtocolV2TextData(
        _ data: Data,
        identifier: String
    ) async throws {
        guard let connection = nwConnection else {
            throw CoordinatorError.noActiveConnection
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(
            identifier: identifier,
            metadata: [metadata]
        )
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(
                            throwing: CoordinatorError.connectionClosed(error)
                        )
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    /// Encode an outbound message to its wire JSON string.
    ///
    /// `nonisolated`: the codec is a pure static function with no actor state,
    /// so encoding can run inline on the caller's task without hopping to the
    /// CoordinatorClient actor. This matters on the inference-chunk hot path
    /// where every token previously paid an actor-scheduling round-trip —
    /// under concurrent load those round-trips serialize and inflate
    /// inter-token latency (the WS write-loop bottleneck).
    nonisolated internal func encodeOutbound(_ msg: OutboundMessage) -> String {
        do {
            return try CoordinatorClientCodec.encodeOutboundMessageString(msg)
        } catch {
            recordEncodeFailure("outbound", error)
            return "{}"
        }
    }

    internal func encodeInferenceError(
        requestId: String, error: String, statusCode: UInt16, errorReason: String? = nil
    ) -> String {
        let message = ProviderMessage.inferenceError(
            ProviderMessage.InferenceError(
            requestId: requestId,
            error: error,
            statusCode: statusCode,
            errorReason: errorReason
        ))
        do {
            let data = try ProviderProtocolCodec.encodeProviderMessage(message)
            guard let json = String(data: data, encoding: .utf8) else {
                throw CoordinatorError.encodingFailed
            }
            return json
        } catch let encodeError {
            recordEncodeFailure("inference_error", encodeError)
            // Surface a parseable, correctly-typed error for THIS request rather
            // than an empty `{}` the coordinator can't attribute or act on.
            var fallback: [String: Any] = [
                "type": "inference_error",
                "request_id": requestId,
                "error": error,
                "status_code": Int(statusCode),
            ]
            if let errorReason { fallback["error_reason"] = errorReason }
            if let data = try? JSONSerialization.data(withJSONObject: fallback),
                let json = String(data: data, encoding: .utf8)
            {
                return json
            }
            return
                "{\"type\":\"inference_error\",\"request_id\":\"\",\"error\":\"encode_failed\",\"status_code\":500}"
        }
    }

    /// A never-should-happen outbound-encode failure must not silently ship a
    /// corrupt/empty payload: record it at error severity and via protocol
    /// telemetry so the drift is observable instead of invisible.
    nonisolated internal func recordEncodeFailure(_ operation: String, _ error: Error) {
        logger.error("Outbound encode failed (\(operation)): \(error.localizedDescription)")
        TelemetryClient.shared.emit(
            kind: .protocolError,
            severity: .error,
            message: "outbound encode failed",
            fields: [
                "operation": .string(operation),
                "error": .string(error.localizedDescription),
            ]
        )
    }

}
