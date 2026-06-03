import Foundation

/// Severity of a single diagnostic check, mirroring the operator-facing marker.
public enum DiagnosticLevel: String, Sendable, Equatable, Codable {
    case pass
    case warn
    case fail

    public var marker: String {
        switch self {
        case .pass: return "[PASS]"
        case .warn: return "[WARN]"
        case .fail: return "[FAIL]"
        }
    }
}

/// The sections of a diagnostic report, ordered by causal reading order
/// (hardware → security → attestation key → trust → traffic → runtime →
/// connectivity → version → billing). Operators read top-to-bottom.
public enum DiagnosticSection: Int, Sendable, Equatable, CaseIterable {
    case hardware
    case security
    case attestationKey
    case trust
    case traffic
    case runtime
    case connectivity
    case version
    case billing

    public var title: String {
        switch self {
        case .hardware: return "HARDWARE & GPU"
        case .security: return "SECURITY POSTURE"
        case .attestationKey: return "ATTESTATION KEY (Secure Enclave)"
        case .trust: return "COORDINATOR TRUST   (why you are / aren't earning)"
        case .traffic: return "TRAFFIC READINESS   (can this box actually serve?)"
        case .runtime: return "RUNTIME (live)"
        case .connectivity: return "CONNECTIVITY"
        case .version: return "VERSION"
        case .billing: return "BILLING"
        }
    }
}

/// A single operator-facing diagnostic: what was checked, the verdict, a
/// plain-language message, and an optional concrete fix line.
public struct Diagnostic: Sendable, Equatable {
    public let section: DiagnosticSection
    public let name: String
    public let level: DiagnosticLevel
    public let message: String
    /// Concrete next step the operator can take. nil for passing checks.
    public let fix: String?

    public init(section: DiagnosticSection, name: String, level: DiagnosticLevel, message: String, fix: String? = nil) {
        self.section = section
        self.name = name
        self.level = level
        self.message = message
        self.fix = fix
    }
}

/// Plain-language explanation + suggested fix for a low-level signal (a
/// coordinator reason string or an OSStatus code). Pure value type so the
/// mapping catalogs are unit-testable on any platform.
public struct DiagnosticAdvice: Sendable, Equatable {
    public let message: String
    public let fix: String?

    public init(message: String, fix: String? = nil) {
        self.message = message
        self.fix = fix
    }
}
