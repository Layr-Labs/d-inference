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
    /// `profiles status` could not be run (or produced no output) — the state
    /// is UNKNOWN, which is distinct from "not enrolled": unenroll must not
    /// tell an enrolled user there is nothing to remove, and doctor must not
    /// assert non-enrollment, just because the tool transiently failed.
    case checkFailed

    public var isDarkbloom: Bool {
        if case .enrolledDarkbloom = self { return true }
        return false
    }

    /// The other build environment (dev or production) whose coordinator
    /// issued this profile. That install owns it: this install never treats
    /// it as its own enrollment and never offers to remove it.
    public var otherInstall: BuildEnvironment? {
        guard case .enrolledOtherMDM(let serverURL) = self,
            let host = URL(string: serverURL)?.host?.lowercased()
        else { return nil }
        return BuildEnvironment.allCases.first { $0 != .current && mdmHost(of: $0) == host }
    }
}

/// Text for a profile that this install does not own: the other install's
/// Darkbloom profile is named with the command that manages it.
public func describeOtherMDM(_ state: MDMEnrollmentState) -> String {
    guard case .enrolledOtherMDM(let serverURL) = state else { return "" }
    if let other = state.otherInstall {
        return "the \(other.cliName) provider's Darkbloom MDM profile (\(serverURL)); manage it with `\(other.cliName) enroll` / `\(other.cliName) unenroll`"
    }
    return "another MDM (\(serverURL))"
}

/// Host of the coordinator that serves an environment's enrollment profiles.
func mdmHost(of environment: BuildEnvironment) -> String? {
    URL(string: environment.coordinatorHTTPURL)?.host?.lowercased()
}

/// MDM hosts that are ours: the build environment's coordinator host and
/// these suffixes. The enrollment profile's ServerURL is built from the
/// coordinator base URL (coordinator/api/enroll.go), so the host of the
/// configured coordinator is also accepted via `expectedHosts`. The other
/// build environment's coordinator host is never ours: that install owns it.
let darkbloomMDMHostSuffixes = [".darkbloom.dev", ".darkbloom.ai"]
let retiredDarkbloomMDMHosts = ["api.dev.darkbloom.xyz"]

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
    expectedHosts: [String] = [],
    environment: BuildEnvironment = .current
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

    // A stale coordinator config must not re-authorize a retired host through
    // expectedHosts after its DNS or infrastructure is no longer ours.
    if retiredDarkbloomMDMHosts.contains(host) {
        return .enrolledOtherMDM(serverURL: serverURL)
    }

    if expectedHosts.contains(where: { !$0.isEmpty && $0.lowercased() == host }) {
        return .enrolledDarkbloom(serverURL: serverURL)
    }
    let otherHosts = BuildEnvironment.allCases.filter { $0 != environment }.compactMap(mdmHost(of:))
    if otherHosts.contains(host) {
        return .enrolledOtherMDM(serverURL: serverURL)
    }
    let ours = host == mdmHost(of: environment)
        || darkbloomMDMHostSuffixes.contains(where: { host.hasSuffix($0) })
    return ours
        ? .enrolledDarkbloom(serverURL: serverURL)
        : .enrolledOtherMDM(serverURL: serverURL)
}

/// Query this Mac's MDM enrollment state via `profiles status -type enrollment`
/// (works unprivileged). `coordinatorURL` (http(s):// or ws(s)://) contributes
/// its host to the set of accepted Darkbloom MDM hosts.
///
/// When the tool itself fails (spawn error, non-zero exit with no output)
/// the result is `.checkFailed`, NOT `.notEnrolled` — callers choose: enroll
/// proceeds to a download (idempotent, can't brick), unenroll/doctor say the
/// state is unknown instead of asserting non-enrollment.
public func checkMDMEnrollment(coordinatorURL: String? = nil) -> MDMEnrollmentState {
    checkMDMEnrollment(coordinatorURL: coordinatorURL, runner: .live)
}

func checkMDMEnrollment(
    coordinatorURL: String? = nil,
    runner: SecurityCommandRunner
) -> MDMEnrollmentState {
    let result: SecurityCommandResult
    do {
        result = try runner.run("/usr/bin/profiles", ["status", "-type", "enrollment"])
    } catch {
        logger.debug("profiles status failed to launch: \(error)")
        return .checkFailed
    }
    let output = result.stdout
    if result.terminationStatus != 0
        && output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        logger.debug("profiles status exited \(result.terminationStatus) with no output")
        return .checkFailed
    }

    var expectedHosts: [String] = []
    if let coordinatorURL, let host = URL(string: coordinatorURL)?.host {
        expectedHosts.append(host)
    }
    let state = parseMDMEnrollmentStatus(output, expectedHosts: expectedHosts)
    logger.debug("MDM enrollment state: \(state)")
    return state
}
