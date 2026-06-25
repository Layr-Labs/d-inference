import Foundation

// MARK: - Secure Boot Status

/// The macOS Secure Boot posture, detected sudo-free.
///
/// `system_profiler SPiBridgeDataType` exposes `ibridge_secure_boot`, the
/// authoritative sudo-free Secure Boot level (Full / Reduced-Medium /
/// Permissive-No Security). On the provider's minimum supported OS — macOS 26
/// (Tahoe) — this data type is reliably populated and authoritative on BOTH
/// Apple Silicon (verified on M4 Max / Mac16,5 / arm64, which reports
/// `ibridge_secure_boot == "Full Security"`) AND Intel T2. It is the single
/// source of truth; there is no sudo-free proxy fallback.
///
/// `unavailable` covers the cases where the level genuinely can't be read —
/// an absent/empty `SPiBridgeDataType` (anomalous on Tahoe), a `system_profiler`
/// failure, or a localized level string we don't recognize. These warn locally;
/// the coordinator's MDM trust path remains the hard enforcement layer.
public enum SecureBootStatus: Sendable, Equatable {
    /// Provably Full Security: `ibridge_secure_boot == "Full Security"` from
    /// `system_profiler SPiBridgeDataType`. The only posture the gate and the
    /// signed attestation accept.
    case fullSecurity
    /// A confident downgrade below Full Security: `ibridge_secure_boot` reports
    /// Reduced Security (Apple Silicon) or Medium Security (Intel T2). Any
    /// `boot-args` downgrade is already reflected in this level, so there is no
    /// separate boot-args signal to track.
    case reduced
    /// Secure boot effectively off: `ibridge_secure_boot` reports Permissive or
    /// No Security.
    case permissiveOrDisabled
    /// The posture could not be determined.
    case unavailable(reason: String)

    /// True only when the machine *provably* reports Full Security
    /// (`ibridge_secure_boot == "Full Security"`).
    public var isFullSecurity: Bool {
        self == .fullSecurity
    }

    /// The single source of truth for the boolean the provider reports to the
    /// coordinator as `secure_boot_enabled` AND for whether the local gate
    /// accepts the Secure Boot protection. True only for provable Full Security;
    /// any confident downgrade or an unreadable posture reports false.
    public var attestsSecureBoot: Bool {
        switch self {
        case .fullSecurity:
            return true
        case .reduced, .permissiveOrDisabled, .unavailable:
            return false
        }
    }

    /// True when detection is *confident* the machine is NOT at an acceptable
    /// posture (a reported Reduced/Medium/Permissive/No-Security downgrade).
    /// `unavailable` is deliberately excluded: it is not a confirmed downgrade.
    public var isConfidentlyNotFullSecurity: Bool {
        switch self {
        case .reduced, .permissiveOrDisabled:
            return true
        case .fullSecurity, .unavailable:
            return false
        }
    }
}

// MARK: - SPiBridgeDataType Parser

/// Pure parser for the `system_profiler SPiBridgeDataType` report. Accepts
/// either the JSON document (preferred, via `-json`) or the plain-text report,
/// so it is resilient to either invocation and trivially unit-testable.
///
/// `SPiBridgeDataType` is populated — and `ibridge_secure_boot` is authoritative
/// — on the provider's minimum supported OS (macOS 26 / Tahoe) on BOTH Apple
/// Silicon and Intel T2. If the array is empty/absent (anomalous on Tahoe, or a
/// sandboxed `system_profiler`), `spiBridgeStatus` returns `nil` and the caller
/// maps that to `.unavailable`.
public enum SecureBootStatusParser {
    /// Classify a `SPiBridgeDataType` result, or `nil` when the array is
    /// empty/unavailable (anomalous on Tahoe, or a command failure).
    public static func spiBridgeStatus(_ result: SecurityCommandResult) -> SecureBootStatus? {
        guard result.terminationStatus == 0 else { return nil }
        return spiBridgeStatus(result.stdout)
    }

    /// Classify a `SPiBridgeDataType` document, or `nil` when no
    /// `ibridge_secure_boot` level is present (empty/absent report).
    public static func spiBridgeStatus(_ output: String) -> SecureBootStatus? {
        guard let level = spiBridgeSecureBootLevel(in: output) else { return nil }
        return classify(level: level)
    }

    /// Extract the raw boot-security level (`ibridge_secure_boot`, or the text
    /// after "Secure Boot:") from a `SPiBridgeDataType` report, or `nil` when
    /// absent.
    public static func spiBridgeSecureBootLevel(in output: String) -> String? {
        if let level = secureBootLevelFromJSON(output) {
            return level
        }
        return secureBootLevelFromText(output)
    }

    /// Classify a raw boot-security level string (the value of
    /// `ibridge_secure_boot`, or the text after "Secure Boot:").
    ///
    /// `system_profiler` localizes these values on non-English Macs, and the
    /// strings are not forceable to English. We therefore positively recognize
    /// only the known English values and treat anything else as `unavailable`
    /// (unavailable, not a false downgrade) so a correctly configured
    /// non-English Mac never gets misclassified as downgraded.
    public static func classify(level rawValue: String) -> SecureBootStatus {
        let normalized = rawValue.lowercased().filter { !$0.isWhitespace }
        switch normalized {
        case "fullsecurity":
            return .fullSecurity
        case "reducedsecurity", "mediumsecurity":
            return .reduced
        case "permissivesecurity", "nosecurity":
            return .permissiveOrDisabled
        default:
            let display = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return .unavailable(
                reason: "unrecognized boot security level \"\(display)\" "
                    + "(system_profiler localizes this on non-English Macs)"
            )
        }
    }

    // MARK: - Extraction

    private static func secureBootLevelFromJSON(_ output: String) -> String? {
        guard let data = output.data(using: .utf8),
              let report = try? JSONDecoder().decode(SystemProfilerBridgeReport.self, from: data)
        else {
            return nil
        }
        return report.SPiBridgeDataType
            .compactMap { nonEmpty($0.secureBoot) }
            .first
    }

    private static func secureBootLevelFromText(_ output: String) -> String? {
        for line in output.components(separatedBy: .newlines) {
            // Match the human-readable "Secure Boot: <level>" row. The JSON key
            // is `ibridge_secure_boot` (no space before the colon), so this only
            // fires on the text report, not on a JSON document.
            guard let colon = line.range(of: ":"),
                  line[..<colon.lowerBound].localizedCaseInsensitiveContains("Secure Boot")
            else {
                continue
            }
            if let value = nonEmpty(String(line[colon.upperBound...])) {
                return value
            }
        }
        return nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Minimal SPiBridgeDataType decoding

    private struct SystemProfilerBridgeReport: Decodable {
        let SPiBridgeDataType: [SystemProfilerBridgeRecord]
    }

    private struct SystemProfilerBridgeRecord: Decodable {
        let secureBoot: String?

        enum CodingKeys: String, CodingKey {
            case secureBoot = "ibridge_secure_boot"
        }
    }
}
