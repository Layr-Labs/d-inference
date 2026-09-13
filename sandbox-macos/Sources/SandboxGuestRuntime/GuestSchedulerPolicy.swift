import Darwin
import Foundation
import SandboxGuestProtocol
import SandboxRuntime

/// Persistent root schedulers must never restart tenant work after UID cleanup.
/// The two controls are independent: disallow submissions and unload execution.
enum GuestSchedulerPolicy {
    static let labels = ["com.vix.cron", "com.apple.atrun"]
    static let directory = URL(fileURLWithPath: "/private/var/at")

    static func provision() async throws {
        try GuestConfiguration.requireVirtualizedRoot()
        _ = try GuestConfiguration.signedExecutable()
        try requireSystemAlias()
        try GuestSchedulerFiles.provision(in: directory, ownerUID: 0, initialOwnerUID: 1)
        for label in labels {
            let disabled = try await launchctl(["disable", "system/" + label])
            guard disabled.exitCode == 0 else { throw GuestProtocolError.invalidConfiguration }
            // An absent service is already stopped. Verify absence separately,
            // never infer it from bootout's version-dependent failure code.
            _ = try await launchctl(["bootout", "system/" + label])
        }
        try await validate()
    }

    static func validate() async throws {
        try requireSystemAlias()
        try GuestSchedulerFiles.validate(in: directory, ownerUID: 0)
        let disabled = try await launchctl(["print-disabled", "system"])
        guard disabled.exitCode == 0, !disabled.standardOutputTruncated,
              explicitlyDisabled(String(decoding: disabled.standardOutput, as: UTF8.self))
        else { throw GuestProtocolError.invalidConfiguration }
        for label in labels {
            let status = try await launchctl(["print", "system/" + label])
            guard serviceAbsent(status, label: label) else { throw GuestProtocolError.invalidConfiguration }
        }
    }

    static func explicitlyDisabled(_ output: String) -> Bool {
        for label in labels {
            let matching = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("\"" + label + "\"") }
            guard matching.count == 1,
                  matching[0] == "\"" + label + "\" => disabled"
                    || matching[0] == "\"" + label + "\" => true"
            else { return false }
        }
        return true
    }

    static func serviceAbsent(_ result: SandboxProcessResult, label: String) -> Bool {
        result.exitCode == 113 && !result.standardErrorTruncated && !result.standardOutputTruncated
            && String(decoding: result.standardError, as: UTF8.self).split(separator: "\n")
                .contains(Substring("Could not find service \"\(label)\" in domain for system"))
    }

    private static func launchctl(_ arguments: [String]) async throws -> SandboxProcessResult {
        try await SandboxProcessRunner().run(executable: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: arguments, timeoutSeconds: 5, maximumOutputBytes: 65536)
    }

    private static func requireSystemAlias() throws {
        // Apple's immutable system alias is not a general symlink allowance.
        guard try FileManager.default.destinationOfSymbolicLink(atPath: "/usr/lib/cron") == "../../var/at"
        else { throw GuestProtocolError.invalidConfiguration }
    }
}
