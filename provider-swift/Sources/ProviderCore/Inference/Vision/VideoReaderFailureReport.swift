// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon

/// Reports each failed `AVAssetReader` pass of a media decode (MLX-Swift-LM's
/// `VideoReaderRetry` over a video or audio track, and the Super video reader)
/// as one WARN `engine_health` event and one provider log line. Both carry the
/// track's medium, the reader status and the domain and code of its errors
/// only, never media bytes, frames, samples or prompt content.
enum VideoReaderFailureReport {
    private static let logger = ProviderLogger(
        subsystem: BuildEnvironment.current.serviceLogSubsystem, category: "video-reader")

    /// Operation `video_reader_failed` or `audio_reader_failed`, by the track's medium.
    static func event(_ failure: VideoReaderFailure, retrying: Bool) -> TelemetryEvent {
        let medium = failure.medium.rawValue
        return TelemetryEvent(
            source: .provider, severity: .warn, kind: .engineHealth,
            message: retrying
                ? "\(medium) reader pass failed; decoding again with a new reader"
                : "\(medium) reader pass failed again; the \(medium) is refused"
        ).withFields([
            "component": .string("engine"),
            "operation": .string("\(medium)_reader_failed"),
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
            logger.warning("\(failure.medium.rawValue) reader pass failed (retrying: \(retrying)): \(failure)")
            emit(event(failure, retrying: retrying))
        }, operation: operation)
    }
}
