import Foundation

enum DiagnosticVerdict: String, Hashable, Sendable {
    case healthy
    case attention
    case blocked

    var title: String {
        switch self {
        case .healthy: "Everything looks good"
        case .attention: "A few things need attention"
        case .blocked: "This Mac needs your help"
        }
    }
}

enum DiagnosticSeverity: Int, Hashable, Sendable {
    case passed = 0
    case warning = 1
    case failure = 2
}

enum DiagnosticSection: Int, CaseIterable, Hashable, Sendable {
    case hardware
    case security
    case attestationKey
    case attestationReadiness
    case trust
    case traffic
    case runtime
    case connectivity
    case version
    case billing
    /// Forward-compat bucket: a check whose section this build doesn't know
    /// (newer CLI) still surfaces — grouped last, not silently dropped.
    case other

    var title: String {
        switch self {
        case .hardware: "Hardware & GPU"
        case .security: "Security posture"
        case .attestationKey: "Secure Enclave key"
        case .attestationReadiness: "Attestation readiness"
        case .trust: "Network trust"
        case .traffic: "Traffic readiness"
        case .runtime: "Provider runtime"
        case .connectivity: "Connectivity"
        case .version: "Version"
        case .billing: "Usage reporting"
        case .other: "Other checks"
        }
    }

    /// Reverse of `DiagnosticSection.wireID` in ProviderCore
    /// (`Sources/ProviderCore/Diagnostics/DoctorReport.swift`). The two enums
    /// are kept in separate modules (the app cannot link ProviderCore), so
    /// the CLI's golden test pins the strings and this init pins the pairing.
    init(wireID: String) {
        self =
            switch wireID {
            case "hardware": .hardware
            case "security": .security
            case "attestationKey": .attestationKey
            case "attestationReadiness": .attestationReadiness
            case "trust": .trust
            case "traffic": .traffic
            case "runtime": .runtime
            case "connectivity": .connectivity
            case "version": .version
            case "billing": .billing
            default: .other
            }
    }
}

enum DiagnosticFixPriority: Int, Hashable, Sendable {
    case urgent = 0
    case recommended = 1
}

enum DiagnosticFixAction: Hashable, Sendable {
    case openEnrollment
    case openRecoveryInstructions
    case checkForUpdates
    case restartProvider
    case redownloadModel(modelID: String)
    case openNetworkSettings
    case openSupport
}

struct DiagnosticFix: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let detail: String
    let priority: DiagnosticFixPriority
    let action: DiagnosticFixAction
}

struct DiagnosticCheckSummary: Identifiable, Hashable, Sendable {
    let id: String
    let section: DiagnosticSection
    let title: String
    let severity: DiagnosticSeverity
    let message: String
    let fix: DiagnosticFix?
}

struct DiagnosticReport: Hashable, Sendable {
    let generatedAt: Date
    let checks: [DiagnosticCheckSummary]

    var overallVerdict: DiagnosticVerdict {
        if checks.contains(where: { $0.severity == .failure }) {
            return .blocked
        }
        if checks.contains(where: { $0.severity == .warning }) {
            return .attention
        }
        return .healthy
    }

    var prioritizedFixes: [DiagnosticFix] {
        checks
            .filter { $0.fix != nil }
            .sorted { lhs, rhs in
                guard let leftFix = lhs.fix, let rightFix = rhs.fix else {
                    return lhs.fix != nil
                }
                if leftFix.priority != rightFix.priority {
                    return leftFix.priority.rawValue < rightFix.priority.rawValue
                }
                if lhs.severity != rhs.severity {
                    return lhs.severity.rawValue > rhs.severity.rawValue
                }
                if lhs.section != rhs.section {
                    return lhs.section.rawValue < rhs.section.rawValue
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            .compactMap(\.fix)
    }

    var unresolvedChecks: [DiagnosticCheckSummary] {
        checks
            .filter { $0.severity != .passed }
            .sorted { lhs, rhs in
                if lhs.severity != rhs.severity {
                    return lhs.severity.rawValue > rhs.severity.rawValue
                }
                return lhs.section.rawValue < rhs.section.rawValue
            }
    }
}

// MARK: - Live report mapping (`darkbloom doctor --json`)

extension DiagnosticReport {
    /// Maps a decoded doctor report into the app's model. The CLI keeps the
    /// check NAMES (they double as support vocabulary — "what does `metal
    /// gpu` say?"), so titles are shown verbatim.
    init(doctor payload: DoctorJSONReport, generatedAt: Date = Date()) {
        let fixesByCheck = Dictionary(grouping: payload.fixes ?? [], by: \.check)
        self.init(
            generatedAt: generatedAt,
            checks: payload.checks.map { check in
                let section = DiagnosticSection(wireID: check.section)
                let severity = DiagnosticSeverity(status: check.status)
                let fix = fixesByCheck[check.id]?.first.map { fix in
                    DiagnosticFix(
                        id: fix.id,
                        title: fix.title,
                        detail: fix.detail,
                        priority: fix.priority == "urgent" ? .urgent : .recommended,
                        action: DiagnosticFixAction.route(
                            forFixTargeting: check.id, section: section, detail: fix.detail
                        )
                    )
                } ?? check.advice.map {
                    // Defensive: advice without a fix record still produces a
                    // card (the CLI always pairs them; a hand-rolled or
                    // skewed payload shouldn't drop operator guidance).
                    DiagnosticFix(
                        id: "fix-\(check.id)",
                        title: check.title,
                        detail: $0,
                        priority: severity == .failure ? .urgent : .recommended,
                        action: DiagnosticFixAction.route(
                            forFixTargeting: check.id, section: section, detail: $0
                        )
                    )
                }
                return DiagnosticCheckSummary(
                    id: check.id,
                    section: section,
                    title: check.title,
                    severity: severity,
                    message: check.detail,
                    fix: fix
                )
            }
        )
    }
}

extension DiagnosticSeverity {
    /// Doctor status strings → severities. Unknown (future) statuses surface
    /// as warnings — visible but non-blocking — rather than failing the
    /// decode of a whole report.
    init(status: String) {
        switch status {
        case "pass": self = .passed
        case "fail": self = .failure
        default: self = .warning // "warn", or anything newer
        }
    }
}

extension DiagnosticFixAction {
    /// Route a live fix to the app's action surface. The advice TEXT is the
    /// truth (rendered as the card's detail); this only picks which button
    /// appears, so it works from stable, low-cardinality signals: a few
    /// advice keywords, then the check's section.
    static func route(
        forFixTargeting checkID: String,
        section: DiagnosticSection,
        detail: String
    ) -> DiagnosticFixAction {
        let text = "\(checkID) \(detail)".lowercased()
        if text.contains("enroll") { return .openEnrollment }
        if text.contains("restart") || text.contains("stop && darkbloom start") {
            return .restartProvider
        }
        switch section {
        case .version: return .checkForUpdates
        case .security: return .openRecoveryInstructions
        case .connectivity: return .openNetworkSettings
        case .hardware, .attestationKey, .attestationReadiness, .trust,
             .traffic, .runtime, .billing, .other:
            return .openSupport
        }
    }
}
