import Foundation
import SandboxGuestProtocol
import SandboxRuntime

/// gui/UID is launchctl's alias for that UID's login/ASID domain. Only the
/// fixed tenant domains are addressed; cleanup never targets system or root.
enum GuestTenantDomains {
    static let domains = ["gui/2001", "user/2001"]
    struct Removal: Sendable { let userDomainBootedOut: Bool }
    enum VerificationFailure: String, Error, Sendable {
        case unknownDomain = "unknown_domain"
        case inspectionUnproven = "domain_inspection_unproven"
        case loginDomainNotAbsent = "login_domain_not_absent"
        case userDomainRemovalUnproven = "user_domain_removal_unproven"
        case userDomainFormatUnproven = "user_domain_format_unproven"
    }

    static func remove() async throws -> Removal {
        var userDomainBootedOut = false
        for domain in domains {
            let status = try await command(["print", domain])
            if absent(status, domain: domain) { continue }
            guard status.exitCode == 0 else { throw GuestProtocolError.cleanupUncertain }
            let removed = try await command(["bootout", domain])
            if domain == "user/2001", removed.exitCode == 0 { userDomainBootedOut = true }
            if removed.exitCode != 0 {
                guard absent(try await command(["print", domain]), domain: domain)
                else { throw GuestProtocolError.cleanupUncertain }
            }
        }
        return Removal(userDomainBootedOut: userDomainBootedOut)
    }

    static func verifyQuiescent(after removal: Removal) async throws {
        for domain in domains {
            let result = try await command(["print", domain])
            if let failure = verificationFailure(result, domain: domain, after: removal) { throw failure }
        }
    }

    static func quiescent(_ result: SandboxProcessResult, domain: String, after removal: Removal) -> Bool {
        verificationFailure(result, domain: domain, after: removal) == nil
    }

    static func verificationFailure(_ result: SandboxProcessResult, domain: String,
                                    after removal: Removal) -> VerificationFailure? {
        guard domains.contains(domain) else { return .unknownDomain }
        if absent(result, domain: domain) { return nil }
        guard result.exitCode == 0, !result.standardOutputTruncated, !result.standardErrorTruncated else {
            return .inspectionUnproven
        }
        guard domain == "user/2001" else { return .loginDomainNotAbsent }
        guard removal.userDomainBootedOut else { return .userDomainRemovalUnproven }
        guard GuestEmptyUserDomain.matches(result) else { return .userDomainFormatUnproven }
        return nil
    }

    static func absent(_ result: SandboxProcessResult, domain: String) -> Bool {
        guard domains.contains(domain), result.exitCode == 112,
              !result.standardErrorTruncated, !result.standardOutputTruncated else { return false }
        let identity = domain == "gui/2001" ? "user gui: 2001" : "uid: 2001"
        return String(decoding: result.standardError, as: UTF8.self).split(separator: "\n")
            .contains(Substring("Could not find domain for " + identity))
    }

    private static func command(_ arguments: [String]) async throws -> SandboxProcessResult {
        try await SandboxProcessRunner().run(executable: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: arguments, timeoutSeconds: 5, maximumOutputBytes: 65536)
    }
}
