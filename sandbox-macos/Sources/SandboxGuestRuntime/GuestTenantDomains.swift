import Foundation
import SandboxGuestProtocol
import SandboxRuntime

/// gui/UID is launchctl's alias for that UID's login/ASID domain. Only the
/// fixed tenant domains are addressed; cleanup never targets system or root.
enum GuestTenantDomains {
    static let domains = ["gui/2001", "user/2001"]
    typealias Command = @Sendable ([String]) async throws -> SandboxProcessResult
    typealias Pause = @Sendable () async throws -> Void
    struct Removal: Sendable { let userDomainBootedOut: Bool }
    enum VerificationFailure: String, Error, Sendable {
        case unknownDomain = "unknown_domain"
        case inspectionUnproven = "domain_inspection_unproven"
        case removalUnproven = "domain_removal_unproven"
        case loginDomainNotAbsent = "login_domain_not_absent"
        case userDomainRemovalUnproven = "user_domain_removal_unproven"
        case userDomainFormatUnproven = "user_domain_format_unproven"
    }

    static func remove(run: Command = command, pause: Pause = delay) async throws -> Removal {
        var userDomainBootedOut = false
        for domain in domains {
            let removed = try await stabilize(pause: pause) {
                let status = try await run(["print", domain])
                if absent(status, domain: domain) { return .complete(false) }
                guard status.exitCode == 0, !status.standardOutputTruncated, !status.standardErrorTruncated else {
                    return .pending(.inspectionUnproven)
                }
                let removed = try await run(["bootout", domain])
                if removed.exitCode == 0, !removed.standardOutputTruncated, !removed.standardErrorTruncated {
                    return .complete(true)
                }
                if absent(try await run(["print", domain]), domain: domain) { return .complete(false) }
                return .pending(.removalUnproven)
            }
            if domain == "user/2001", removed { userDomainBootedOut = true }
        }
        return Removal(userDomainBootedOut: userDomainBootedOut)
    }

    static func verifyQuiescent(after removal: Removal, run: Command = command,
                                pause: Pause = delay) async throws {
        for domain in domains {
            _ = try await stabilize(pause: pause) {
                let result = try await run(["print", domain])
                if let failure = verificationFailure(result, domain: domain, after: removal) { return .pending(failure) }
                return .complete(true)
            }
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
            arguments: arguments, timeoutSeconds: 1, maximumOutputBytes: 65536)
    }

    private enum Observation { case complete(Bool), pending(VerificationFailure) }

    private static func stabilize(pause: Pause, observe: () async throws -> Observation) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var lastFailure = VerificationFailure.inspectionUnproven
        for attempt in 0..<8 {
            try Task.checkCancellation()
            switch try await observe() {
            case .complete(let value): return value
            case .pending(let failure): lastFailure = failure
            }
            guard attempt < 7, ContinuousClock.now < deadline else { break }
            try await pause()
        }
        throw lastFailure
    }

    private static func delay() async throws {
        try await Task.sleep(for: .milliseconds(50))
    }
}
