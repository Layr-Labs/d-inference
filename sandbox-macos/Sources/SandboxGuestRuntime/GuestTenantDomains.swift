import Foundation
import SandboxGuestProtocol
import SandboxRuntime

/// gui/UID is launchctl's alias for that UID's login/ASID domain. Only the
/// fixed tenant domains are addressed; cleanup never targets system or root.
enum GuestTenantDomains {
    static let domains = ["gui/2001", "user/2001"]

    static func remove() async throws {
        for domain in domains {
            let status = try await command(["print", domain])
            if absent(status, domain: domain) { continue }
            guard status.exitCode == 0 else { throw GuestProtocolError.cleanupUncertain }
            let removed = try await command(["bootout", domain])
            if removed.exitCode != 0 {
                guard absent(try await command(["print", domain]), domain: domain)
                else { throw GuestProtocolError.cleanupUncertain }
            }
        }
    }

    static func verifyAbsent() async throws {
        for domain in domains {
            guard absent(try await command(["print", domain]), domain: domain)
            else { throw GuestProtocolError.cleanupUncertain }
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
            arguments: arguments, timeoutSeconds: 5, maximumOutputBytes: 65536)
    }
}
