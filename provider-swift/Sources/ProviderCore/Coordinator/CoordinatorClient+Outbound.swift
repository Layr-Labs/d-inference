// CoordinatorClient outbound encoding: encode OutboundMessage values (incl. inference
// errors) to wire JSON, with encode-failure accounting.

import Foundation
import Network
#if canImport(os)
import os
#endif

extension CoordinatorClient {
    // MARK: - Outbound Encoding

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

    internal func encodeInferenceError(requestId: String, error: String, statusCode: UInt16, errorReason: String? = nil) -> String {
        let message = ProviderMessage.inferenceError(ProviderMessage.InferenceError(
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
               let json = String(data: data, encoding: .utf8) {
                return json
            }
            return "{\"type\":\"inference_error\",\"request_id\":\"\",\"error\":\"encode_failed\",\"status_code\":500}"
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
