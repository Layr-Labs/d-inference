import Foundation
import ProviderCore

/// Device-wide `devicecheckd` / App Attest evidence from the unified log, for
/// `darkbloom doctor` (printed) and `darkbloom report` (appended to the
/// user-initiated upload). Not attributable to Darkbloom; never collected or sent automatically.
///
/// Only a closed set of patterns and their numeric codes is kept per line;
/// the raw message text, key identifiers and paths are never retained.
enum DeviceCheckEvidence {
    static let window = "2h"
    static let predicate = #"process == "devicecheckd" OR subsystem == "com.apple.appattest""#
    static let timeoutSeconds: TimeInterval = 30
    static let maxEvents = 200
    static let scopeDisclaimer = "Device-wide observations; not attributable to Darkbloom."

    /// Closed pattern set. `code` patterns capture one signed integer.
    enum Pattern: String, CaseIterable, Codable, Sendable {
        case secKeyCreateSignatureFailed = "SecKeyCreateSignature failed"
        case cryptoTokenKitCode = "CryptoTokenKit Code"
        case aksError = "AKSError"
        case shouldFetchCDHash = "Should fetch CD hash"
        case invalidKey = "invalidKey"
        case unknownSystemFailure = "unknownSystemFailure"

        /// Regex applied to the message; group 1 (when present) is the code.
        var regex: String {
            switch self {
            case .secKeyCreateSignatureFailed: return #"SecKeyCreateSignature failed"#
            case .cryptoTokenKitCode: return #"Domain=CryptoTokenKit Code=(-?\d+)"#
            case .aksError: return #"AKSError=(-?\d+)"#
            case .shouldFetchCDHash: return #"Should fetch CD hash"#
            case .invalidKey: return #"invalidKey"#
            case .unknownSystemFailure: return #"unknownSystemFailure"#
            }
        }

        var expression: NSRegularExpression? { try? NSRegularExpression(pattern: regex) }
    }

    struct Match: Codable, Sendable, Equatable {
        let pattern: Pattern
        let code: Int32?
    }

    struct Event: Codable, Sendable, Equatable {
        let timestamp: String
        let category: String?
        let messageType: String?
        let matches: [Match]

        enum CodingKeys: String, CodingKey {
            case timestamp, category, matches
            case messageType = "message_type"
        }
    }

    enum Outcome: Sendable, Equatable {
        case collected([Event])
        /// `log show` could not open the log store (standard, non-admin account).
        case accessDenied
        case failed(String)
    }

    static let accessDeniedFix =
        "macOS lets only administrator accounts read the system log: run `darkbloom doctor` / `darkbloom report` "
        + "from an administrator account, or `sudo darkbloom report` if this account is allowed to use sudo."

    // MARK: - Collection

    static func arguments() -> [String] {
        ["show", "--last", window, "--style", "ndjson", "--predicate", predicate]
    }

    /// Runs `/usr/bin/log show` with a timeout. Never throws.
    static func collect(runner: (_ arguments: [String]) throws -> (status: Int32, stdout: Data, stderr: String) = liveRun) -> Outcome {
        let result: (status: Int32, stdout: Data, stderr: String)
        do { result = try runner(arguments()) } catch { return .failed("log show did not complete: \(error)") }
        if isAccessDenied(status: result.status, stderr: result.stderr) { return .accessDenied }
        guard result.status == 0 else { return .failed("log show exited \(result.status)") }
        return .collected(extract(ndjson: result.stdout))
    }

    static func isAccessDenied(status: Int32, stderr: String) -> Bool {
        // `log show` exits 77 (EX_NOPERM) with "Operation not permitted".
        status == 77 || stderr.localizedCaseInsensitiveContains("Operation not permitted")
    }

    private static func liveRun(_ arguments: [String]) throws -> (status: Int32, stdout: Data, stderr: String) {
        try runLog(arguments)
    }

    // MARK: - Rendering

    static func summary(_ events: [Event]) -> String {
        guard !events.isEmpty else { return scopeDisclaimer + " No devicecheckd/App Attest failure patterns in the collected log tail (up to \(window))." }
        var counts: [Pattern: Int] = [:]
        var codes: [Pattern: Set<Int32>] = [:]
        for event in events {
            for match in event.matches {
                counts[match.pattern, default: 0] += 1
                if let code = match.code { codes[match.pattern, default: []].insert(code) }
            }
        }
        let parts = Pattern.allCases.compactMap { pattern -> String? in
            guard let count = counts[pattern] else { return nil }
            let list = codes[pattern].map { " (" + $0.sorted().map(String.init).joined(separator: ", ") + ")" } ?? ""
            return "\(pattern.rawValue) ×\(count)\(list)"
        }
        return scopeDisclaimer + " Collected log tail (up to \(window)): " + parts.joined(separator: "; ")
    }

    static func doctorDiagnostic(_ outcome: Outcome) -> Diagnostic {
        switch outcome {
        case .collected(let events):
            return Diagnostic(section: .appAttest, name: "devicecheckd log",
                              level: events.isEmpty ? .pass : .warn, message: summary(events),
                              fix: events.isEmpty ? nil : "run `darkbloom report` to send this evidence to support.")
        case .accessDenied:
            return Diagnostic(section: .appAttest, name: "devicecheckd log", level: .warn,
                              message: "macOS denied access to the unified log (Operation not permitted), so devicecheckd evidence is unavailable.",
                              fix: accessDeniedFix)
        case .failed(let reason):
            return Diagnostic(section: .appAttest, name: "devicecheckd log", level: .warn,
                              message: "devicecheckd evidence unavailable: \(reason).")
        }
    }


    /// NDJSON lines appended to `darkbloom report`. Only closed fields.
    static func reportLines(_ outcome: Outcome) -> Data {
        struct Line: Encodable {
            let source = "darkbloom.devicecheck_evidence"
            let scope = "device_wide"
            let attribution = "not_attributable_to_darkbloom"
            let status: String
            let event: Event?
        }
        let lines: [Line]
        switch outcome {
        case .collected(let events):
            lines = events.isEmpty ? [Line(status: "no_matches", event: nil)] : events.map { Line(status: "match", event: $0) }
        case .accessDenied:
            lines = [Line(status: "access_denied", event: nil)]
        case .failed:
            lines = [Line(status: "unavailable", event: nil)]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = Data()
        for line in lines {
            guard let encoded = try? encoder.encode(line) else { continue }
            data.append(encoded)
            data.append(UInt8(ascii: "\n"))
        }
        return data
    }
}
