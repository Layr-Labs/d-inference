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

    /// The redacted document as bytes. Every string in it is redacted as the
    /// text it is, before it is written as JSON, so no rule has to see through
    /// JSON's own quoting. Throws when the second look still recognizes
    /// something, instead of returning it.
    public static func render(_ input: Input, redaction: ClusterDiagnosticRedaction, createdAt: String) throws -> Data {
        try render(input, redaction: redaction, createdAt: createdAt, marking: redaction.marked)
    }

    /// `marking` is the redactor's own `marked` everywhere but in the check
    /// that proves the second look refuses what a faulty first one lets by.
    static func render(_ input: Input, redaction: ClusterDiagnosticRedaction, createdAt: String,
                       marking: (String) -> String) throws -> Data {
        let document = Document(createdAt: createdAt, darkbloomVersion: input.darkbloomVersion, snapshot: input.snapshot,
            sessionState: input.sessionState, sessionOutput: Array(input.sessionOutput.suffix(sessionOutputLines)),
            activity: input.activity)
        return try redactedDocument(try JSONSerialization.jsonObject(with: JSONEncoder().encode(document)), redaction: redaction, marking: marking)
    }

    /// A JSON document with every string in it redacted as the text it is; throws when the second look still
    /// recognizes something. Field names are the schema's own and stay as they are, and so does a schema's name.
    static func redactedDocument(_ document: Any, redaction: ClusterDiagnosticRedaction, marking: (String) -> String) throws -> Data {
        var residue = Set<String>()
        func redacted(_ value: Any) -> Any {
            switch value {
            case let text as String:
                let marked = marking(text)
                residue.formUnion(redaction.residue(inMarked: marked))
                return ClusterDiagnosticRedaction.named(marked)
            case let list as [Any]: return list.map(redacted)
            // Field names are this schema's own and stay as they are, and so
            // does a schema's name, which no user's name may rewrite.
            case let object as [String: Any]:
                return Dictionary(uniqueKeysWithValues: object.map { ($0.key, $0.key == "schema" ? $0.value : redacted($0.value)) })
            default: return value
            }
        }
        let tree = redacted(document)
        guard residue.isEmpty else { throw Failure.redactionIncomplete(residue.sorted()) }
        var bytes = try JSONSerialization.data(withJSONObject: tree, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        bytes.append(10)
        return bytes
    }

    /// Writes `darkbloom-cluster-diagnostics-<UTC stamp>.json`, owner-only,
    /// into `directory`, and never replaces a file that is already there.
    public static func write(_ input: Input, redaction: ClusterDiagnosticRedaction, directory: URL,
                             now: Date = Date()) throws -> URL {
        let created = ClusterConsoleText.timestamp(now)
        let bytes = try render(input, redaction: redaction, createdAt: created)
        return try writeFile(bytes, directory: directory, created: created, place: "the current directory")
    }

    /// `darkbloom-cluster-diagnostics-<UTC stamp>.json`, owner-only, created in `directory` and never replacing a file
    /// (nor following a link) that is already there.
    static func writeFile(_ bytes: Data, directory: URL, created: String, place: String) throws -> URL {
        let stamp = created.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "")
        let destination = directory.appendingPathComponent("darkbloom-cluster-diagnostics-\(stamp).json")
        let descriptor = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw Failure.notWritten(errno == EEXIST ? "a file with this second's name already exists; try again"
                : "the file could not be created in \(place) (errno \(errno))")
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

// MARK: - The onboarding's diagnostics file

extension ClusterDiagnosticExport {
    public static let onboardingSchemaName = "darkbloom_cluster_onboarding_diagnostics_v1"

    /// What `d` saves after a start that did not finish: each Mac's last error and this Mac's own reports (the JSON of
    /// `cluster status` and `doctor`, by section name), redacted exactly as the console's export is: every string on
    /// its own, and refused when the second look still recognizes something. A section that is not JSON is left out.
    public static func renderOnboarding(lastErrors: [String], sections: [String: Data], redaction: ClusterDiagnosticRedaction,
                                        createdAt: String) throws -> Data {
        try renderOnboarding(lastErrors: lastErrors, sections: sections, redaction: redaction, createdAt: createdAt, marking: redaction.marked)
    }

    static func renderOnboarding(lastErrors: [String], sections: [String: Data], redaction: ClusterDiagnosticRedaction,
                                 createdAt: String, marking: (String) -> String) throws -> Data {
        var document: [String: Any] = ["schema": onboardingSchemaName, "createdAt": createdAt, "lastErrors": lastErrors,
            "redaction": "Network addresses, host names, user names, serial numbers, keys, fingerprints, credentials and home-directory paths were removed or replaced with a placeholder in angle brackets."]
        for (name, data) in sections where !["schema", "createdAt", "lastErrors", "redaction"].contains(name) {
            if let value = try? JSONSerialization.jsonObject(with: data) { document[name] = value }
        }
        return try redactedDocument(document, redaction: redaction, marking: marking)
    }

    /// Writes the onboarding's diagnostics file into the home folder itself, owner-only, never replacing a file. Not
    /// into Desktop, Documents or Downloads: macOS guards those with a prompt to the terminal app the first time, a
    /// permission the person never agreed to give for this.
    public static func writeOnboarding(lastErrors: [String], sections: [String: Data], redaction: ClusterDiagnosticRedaction,
                                       home: URL, now: Date = Date()) throws -> URL {
        let created = ClusterConsoleText.timestamp(now)
        let bytes = try renderOnboarding(lastErrors: lastErrors, sections: sections, redaction: redaction, createdAt: created)
        return try writeFile(bytes, directory: home, created: created, place: "the home folder")
    }
}
