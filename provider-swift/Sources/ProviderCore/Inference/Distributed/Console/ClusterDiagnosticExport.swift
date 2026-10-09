import Foundation
import Darwin

/// One file an operator can attach to a report: what the console observed and
/// what it did, with everything that identifies the Mac, its user or its peer
/// removed. Nothing is collected for it; it holds only what the screen already
/// showed.
public enum ClusterDiagnosticExport {
    public static let schemaName = "darkbloom_cluster_diagnostic_export_v1"
    /// Lines of session output kept, newest last.
    static let sessionOutputLines = 200

    public struct Activity: Encodable, Sendable, Equatable {
        public let time: String
        public let title: String
        public let failed: Bool
        public let lines: [String]

        public init(time: String, title: String, failed: Bool, lines: [String]) {
            self.time = time; self.title = title; self.failed = failed; self.lines = lines
        }
    }

    public struct Input: Sendable {
        public let snapshot: ClusterConsoleSnapshot
        public let activity: [Activity]
        public let sessionState: String
        public let sessionOutput: [String]
        public let darkbloomVersion: String

        public init(snapshot: ClusterConsoleSnapshot, activity: [Activity], sessionState: String,
                    sessionOutput: [String], darkbloomVersion: String) {
            self.snapshot = snapshot; self.activity = activity; self.sessionState = sessionState
            self.sessionOutput = sessionOutput; self.darkbloomVersion = darkbloomVersion
        }
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// Something recognizable survived redaction, so nothing was written.
        case redactionIncomplete([String])
        case notWritten(String)

        public var description: String {
            switch self {
            case .redactionIncomplete(let found):
                return "The export was not written: after redaction it still contained \(found.joined(separator: ", "))."
            case .notWritten(let reason): return "The export was not written: \(reason)"
            }
        }
    }

    private struct Document: Encodable {
        let schema = ClusterDiagnosticExport.schemaName
        let createdAt: String
        let darkbloomVersion: String
        let redaction = "Network addresses, host names, user names, serial numbers, keys, fingerprints, credentials and home-directory paths were removed or replaced with a placeholder in angle brackets. Digests of public files are unchanged."
        let snapshot: ClusterConsoleSnapshot
        let sessionState: String
        let sessionOutput: [String]
        let activity: [Activity]
    }

    /// The redacted document as bytes. Throws when redaction left something
    /// recognizable or broke the document, instead of returning it.
    public static func render(_ input: Input, redaction: ClusterDiagnosticRedaction, createdAt: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let document = Document(createdAt: createdAt, darkbloomVersion: input.darkbloomVersion, snapshot: input.snapshot,
            sessionState: input.sessionState, sessionOutput: Array(input.sessionOutput.suffix(sessionOutputLines)),
            activity: input.activity)
        let redacted = redaction.redact(String(decoding: try encoder.encode(document), as: UTF8.self))
        let residue = redaction.residue(in: redacted)
        guard residue.isEmpty else { throw Failure.redactionIncomplete(residue) }
        let bytes = Data((redacted + "\n").utf8)
        guard (try? JSONSerialization.jsonObject(with: bytes)) != nil else {
            throw Failure.notWritten("redaction left a document that is not JSON")
        }
        return bytes
    }

    /// Writes `darkbloom-cluster-diagnostics-<UTC stamp>.json`, owner-only,
    /// into `directory`, and never replaces a file that is already there.
    public static func write(_ input: Input, redaction: ClusterDiagnosticRedaction, directory: URL,
                             now: Date = Date()) throws -> URL {
        let created = ClusterConsoleText.timestamp(now)
        let bytes = try render(input, redaction: redaction, createdAt: created)
        let stamp = created.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "")
        let destination = directory.appendingPathComponent("darkbloom-cluster-diagnostics-\(stamp).json")
        let descriptor = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw Failure.notWritten(errno == EEXIST ? "a file with this second's name already exists; try again"
                : "the file could not be created in the current directory (errno \(errno))")
        }
        defer { Darwin.close(descriptor) }
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress! + offset, bytes.count - offset) }
            if written < 0 && errno == EINTR { continue }
            guard written > 0 else {
                _ = unlink(destination.path)
                throw Failure.notWritten("writing failed (errno \(errno))")
            }
            offset += written
        }
        return destination
    }
}
