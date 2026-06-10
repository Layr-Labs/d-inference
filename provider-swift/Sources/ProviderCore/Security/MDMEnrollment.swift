import Foundation
import Logging

/// MDM enrollment state of this Mac, as reported by
/// `profiles status -type enrollment` — the authoritative, current source.
///
/// Darkbloom vs foreign matters because macOS allows exactly ONE MDM
/// enrollment per device: a Mac managed by a corporate MDM cannot enroll in
/// Darkbloom's MicroMDM, and an unenrolled Mac must never be told it is
/// "already enrolled" (the pre-0.6.2 heuristics did exactly that from stale
/// profile residue, locking providers out of re-enrollment).
public enum MDMEnrollmentState: Equatable, Sendable {
    case notEnrolled
    case enrolledDarkbloom(serverURL: String)
    case enrolledOtherMDM(serverURL: String)

    public var isDarkbloom: Bool {
        if case .enrolledDarkbloom = self { return true }
        return false
    }
}

/// MDM hosts that are always ours, regardless of the locally configured
/// coordinator (prod + dev). The enrollment profile's ServerURL is built from
/// the coordinator base URL (coordinator/api/enroll.go), so the host of the
/// configured coordinator is also accepted via `expectedHosts`.
let darkbloomMDMHostSuffixes = [".darkbloom.dev", ".darkbloom.xyz", ".darkbloom.ai"]
let darkbloomMDMHosts = ["api.darkbloom.dev", "api.dev.darkbloom.xyz"]

private let logger = Logger(label: "darkbloom.MDMEnrollment")

/// Parse `profiles status -type enrollment` output into an enrollment state.
///
/// Output shapes (macOS 14–26):
///   Enrolled via DEP: No
///   MDM enrollment: Yes (User Approved)
///   MDM server: https://api.darkbloom.dev/mdm/connect
/// or, when not enrolled:
///   Enrolled via DEP: No
///   MDM enrollment: No
///
/// Only the `MDM enrollment:` line decides enrolled-vs-not — in particular the
/// `Enrolled via DEP:` line must NOT (substring "enrolled" was a false-positive
/// source in the old heuristic).
public func parseMDMEnrollmentStatus(
    _ output: String,
    expectedHosts: [String] = []
) -> MDMEnrollmentState {
    var enrolled = false
    var serverURL: String?

    for rawLine in output.split(separator: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        let lower = line.lowercased()
        if lower.hasPrefix("mdm enrollment:") {
            let value = line.dropFirst("mdm enrollment:".count)
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            enrolled = value.hasPrefix("yes")
        } else if lower.hasPrefix("mdm server:") {
            serverURL = line.dropFirst("mdm server:".count)
                .trimmingCharacters(in: .whitespaces)
        }
    }

    guard enrolled else { return .notEnrolled }

    guard let serverURL, let host = URL(string: serverURL)?.host?.lowercased() else {
        // Enrolled but the server is unreadable: claiming "Darkbloom" here would
        // resurrect the old skip-enrollment bug, so report it as foreign and let
        // the operator inspect System Settings.
        return .enrolledOtherMDM(serverURL: serverURL ?? "<unknown>")
    }

    let ours = darkbloomMDMHosts.contains(host)
        || darkbloomMDMHostSuffixes.contains(where: { host.hasSuffix($0) })
        || expectedHosts.contains(where: { !$0.isEmpty && $0.lowercased() == host })
    return ours
        ? .enrolledDarkbloom(serverURL: serverURL)
        : .enrolledOtherMDM(serverURL: serverURL)
}

/// Query this Mac's MDM enrollment state via `profiles status -type enrollment`
/// (works unprivileged). `coordinatorURL` (http(s):// or ws(s)://) contributes
/// its host to the set of accepted Darkbloom MDM hosts.
///
/// Fails toward `.notEnrolled`: letting `enroll` proceed to a profile download
/// is harmless (installing is idempotent), whereas a false "already enrolled"
/// permanently blocks re-enrollment.
public func checkMDMEnrollment(coordinatorURL: String? = nil) -> MDMEnrollmentState {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/profiles")
    process.arguments = ["status", "-type", "enrollment"]

    let outPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = Pipe()

    do {
        try process.run()
    } catch {
        logger.debug("profiles status failed to launch: \(error)")
        return .notEnrolled
    }
    process.waitUntilExit()

    let output = String(
        data: outPipe.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    ) ?? ""

    var expectedHosts: [String] = []
    if let coordinatorURL, let host = URL(string: coordinatorURL)?.host {
        expectedHosts.append(host)
    }
    let state = parseMDMEnrollmentStatus(output, expectedHosts: expectedHosts)
    logger.debug("MDM enrollment state: \(state)")
    return state
}
