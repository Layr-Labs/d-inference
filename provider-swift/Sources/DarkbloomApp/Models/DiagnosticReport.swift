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
