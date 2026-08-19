import Foundation

/// Wire schema for `darkbloom doctor --json` — the single structured truth a
/// doctor run produces.
///
/// A doctor run gathers the SAME check arrays it always did (the operator
/// `Diagnostic`s plus the detailed `DoctorCheck`s); the human report and this
/// JSON document are two renderings of those arrays, never two independent
/// gathers. Assembly lives in the CLI (`DoctorJSONReportBuilder`) because the
/// detailed-check type is CLI-internal; the schema lives HERE, in ProviderCore
/// and pure-Foundation, so the encoding contract is visible to every consumer
/// and pinnable by a byte-stable golden test.
///
/// `schema` is 1. Readers (the macOS app) decode known fields and reject
/// forward schemas rather than mis-decode, matching the `DaemonState` rule.
public struct DoctorReport: Codable, Sendable, Equatable {
    public static let currentSchema = 1

    public let schema: Int
    /// Provider binary version that produced the report (`ProviderCore.version`).
    public let version: String
    /// Every check the run produced: the daemon banner, the operator
    /// diagnosis entries, then the detailed low-level checks — the same
    /// order the human report presents them.
    public let checks: [Check]
    /// Actionable fixes derived from checks carrying advice. nil (key
    /// omitted) when nothing needs fixing — healthy runs stay quiet.
    public let fixes: [Fix]?
    public let verdict: Verdict

    public init(
        version: String,
        checks: [Check],
        fixes: [Fix]?,
        verdict: Verdict
    ) {
        self.schema = Self.currentSchema
        self.version = version
        self.checks = checks
        self.fixes = fixes
        self.verdict = verdict
    }

    /// One diagnostic check: stable machine identity (`id` + `section`), a
    /// human title, the verdict, what was found (`detail`), and an optional
    /// next step (`advice`).
    public struct Check: Codable, Sendable, Equatable {
        /// Stable dotted slug, e.g. `trust.trust-level` or `metal-gpu`.
        /// Unique within one report (the builder de-duplicates).
        public let id: String
        /// `DiagnosticSection.wireID` — the app's section enum mirrors these.
        public let section: String
        public let title: String
        public let status: DiagnosticLevel
        public let detail: String
        /// Plain-language next step; nil when the check needs no action.
        public let advice: String?

        public init(
            id: String,
            section: String,
            title: String,
            status: DiagnosticLevel,
            detail: String,
            advice: String? = nil
        ) {
            self.id = id
            self.section = section
            self.title = title
            self.status = status
            self.detail = detail
            self.advice = advice
        }
    }

    public enum FixPriority: String, Codable, Sendable, Equatable {
        case urgent
        case recommended
    }

    /// A prioritized fix card: the check it resolves plus the advice text.
    /// UI-action routing is presentation — consumers map section/id to their
    /// own action vocabulary.
    public struct Fix: Codable, Sendable, Equatable {
        public let id: String
        /// `Check.id` this fix resolves.
        public let check: String
        public let title: String
        /// Same text as the originating check's `advice`.
        public let detail: String
        public let priority: FixPriority

        public init(id: String, check: String, title: String, detail: String, priority: FixPriority) {
            self.id = id
            self.check = check
            self.title = title
            self.detail = detail
            self.priority = priority
        }
    }

    /// Roll-up over the whole check list. Mirrors the CLI's exit-code
    /// threshold pre-`--strict`: any fail → fail, else any warn → warn.
    public struct Verdict: Codable, Sendable, Equatable {
        public let status: DiagnosticLevel
        public let failures: Int
        public let warnings: Int

        public init(status: DiagnosticLevel, failures: Int, warnings: Int) {
            self.status = status
            self.failures = failures
            self.warnings = warnings
        }
    }
}

public extension DiagnosticSection {
    /// Stable camelCase identifier used in `doctor --json` output. The macOS
    /// app's own `DiagnosticSection` mirrors these names one-to-one (it
    /// cannot link this module), and the CLI golden test pins every value.
    var wireID: String {
        switch self {
        case .hardware: return "hardware"
        case .security: return "security"
        case .attestationKey: return "attestationKey"
        case .attestationReadiness: return "attestationReadiness"
        case .trust: return "trust"
        case .traffic: return "traffic"
        case .runtime: return "runtime"
        case .connectivity: return "connectivity"
        case .version: return "version"
        case .billing: return "billing"
        }
    }
}
