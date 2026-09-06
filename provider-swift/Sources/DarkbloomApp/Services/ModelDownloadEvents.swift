import Foundation

// MARK: - Download events

/// App-facing download event, parsed from the CLI's
/// `darkbloom models download --json` NDJSON stream.
enum ModelDownloadStreamEvent: Equatable, Sendable {
    /// Cumulative bytes on disk for one file (a resumed `.part` prefix is
    /// included, so values never restart at zero for a resumed download).
    /// `total` is nil when the size is unknown (legacy CDN path).
    case progress(file: String, bytes: Int64, total: Int64?)
    case verifying
    case done
    /// The CLI's terminal `{"event":"error",…}` line. The stream also ends
    /// non-zero, so this arrives at most once and always as the last event.
    case error(String)
}

// MARK: - NDJSON parsing

enum ModelDownloadNDJSON {
    private struct EventLine: Decodable {
        let event: String
        let file: String?
        let bytes: Int64?
        let total: Int64?
        let message: String?
    }

    /// Parse one stdout line. Returns nil for blank, malformed, or
    /// unknown-event lines: the stream tolerates noise (stderr bleed on a
    /// shared fd, forward-compatible future events) instead of dying.
    static func parse(_ line: String) -> ModelDownloadStreamEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}"),
              let data = trimmed.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(EventLine.self, from: data)
        else { return nil }

        switch decoded.event {
        case "progress":
            guard let file = decoded.file, let bytes = decoded.bytes else { return nil }
            return .progress(file: file, bytes: bytes, total: decoded.total)
        case "verifying":
            return .verifying
        case "done":
            return .done
        case "error":
            return .error(decoded.message ?? "The download failed.")
        default:
            return nil
        }
    }
}
