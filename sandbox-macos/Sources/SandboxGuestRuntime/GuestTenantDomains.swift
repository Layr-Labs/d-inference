import Foundation
import SandboxGuestProtocol
import SandboxRuntime

/// gui/UID is launchctl's alias for that UID's login/ASID domain. Only the
/// fixed tenant domains are addressed; cleanup never targets system or root.
enum GuestTenantDomains {
    static let domains = ["gui/2001", "user/2001"]
    typealias Command = @Sendable ([String]) async throws -> SandboxProcessResult
    typealias Pause = @Sendable () async throws -> Void
    private enum RetiredState: Sendable { case absent, bootedOut }
    enum VerificationFailure: String, Error, Sendable {
        case inspectionUnproven = "domain_inspection_unproven"
        case removalUnproven = "domain_removal_unproven"
        case loginDomainNotAbsent = "login_domain_not_absent"
    }

    static func remove(run: Command = command, pause: Pause = delay) async throws {
        // On qualified macOS, querying gui/UID returns 125 while a Background
        // user domain exists. Retire that domain first; do not interpret 125
        // as absence. A successful GUI removal can leave a user domain behind.
        _ = try await remove(domain: "user/2001", run: run, pause: pause)
        if try await remove(domain: "gui/2001", run: run, pause: pause) == .bootedOut {
            _ = try await remove(domain: "user/2001", run: run, pause: pause)
        }
    }

    private static func remove(domain: String, run: Command, pause: Pause) async throws -> RetiredState {
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
            return .pending(.removalUnproven)
        }
        return removed ? .bootedOut : .absent
    }

    static func verifyLoginDomainAbsent(run: Command = command, pause: Pause = delay) async throws {
        // After remove() succeeds, do not print user/UID again: print recreates its domain
        // and asynchronously loads Apple services, even if its output is empty.
        // The caller checks zero live tenant processes after this GUI check.
        _ = try await stabilize(pause: pause) {
            let result = try await run(["print", "gui/2001"])
            if absent(result, domain: "gui/2001") { return .complete(true) }
            return .pending(result.exitCode == 0 ? .loginDomainNotAbsent : .inspectionUnproven)
        }
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
