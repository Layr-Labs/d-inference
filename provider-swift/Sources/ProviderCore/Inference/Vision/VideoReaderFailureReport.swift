// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon

/// Reports each failed `AVAssetReader` pass of a media decode (MLX-Swift-LM's
/// `VideoReaderRetry`, and the Super video reader) as one WARN `engine_health`
/// event and one provider log line. Both carry the reader status and the
/// domain and code of its errors only, never media bytes, frames or prompt
/// content.
enum VideoReaderFailureReport {
    private static let logger = ProviderLogger(
        subsystem: BuildEnvironment.current.serviceLogSubsystem, category: "video-reader")

    static func event(_ failure: VideoReaderFailure, retrying: Bool) -> TelemetryEvent {
        TelemetryEvent(
            source: .provider, severity: .warn, kind: .engineHealth,
            message: retrying
                ? "video reader pass failed; decoding again with a new reader"
                : "video reader pass failed again; the video is refused"
        ).withFields([
            "component": .string("engine"),
            "operation": .string("video_reader_failed"),
            "retrying": .bool(retrying),
            "transient": .bool(failure.isTransient),
            "reader_status": .int(failure.status),
            "reader_error": .string(failure.description),
        ])
    }

    /// Runs `operation` with every failed reader pass in it reported to `emit`.
    static func reporting<Result>(
        to emit: @escaping @Sendable (TelemetryEvent) -> Void,
        isolation: isolated (any Actor)? = #isolation,
        _ operation: () async throws -> Result
    ) async rethrows -> Result {
        try await VideoReaderRetry.$failedPassObserver.withValue({ failure, retrying in
            logger.warning("video reader pass failed (retrying: \(retrying)): \(failure)")
            emit(event(failure, retrying: retrying))
        }, operation: operation)
    }
}
