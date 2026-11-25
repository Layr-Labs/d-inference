import Foundation

/// MDM enrollment state of this Mac, as reported by
/// `profiles status -type enrollment` — the authoritative, current source.
///
/// Darkbloom no longer uses MDM: App Attest is the only verification. This
/// state finds a retired Darkbloom profile so the operator can be told to
/// remove it, and tells it apart from a foreign MDM (an employer's), which
/// must never be offered for removal. macOS allows exactly ONE MDM
/// enrollment per device.
public enum MDMEnrollmentState: Equatable, Sendable {
    case notEnrolled
    case enrolledDarkbloom(serverURL: String)
    case enrolledOtherMDM(serverURL: String)
    /// `profiles status` could not be run (or produced no output) — the state
    /// is UNKNOWN, which is distinct from "not enrolled": unenroll must not
    /// tell an enrolled user there is nothing to remove just because the tool
    /// transiently failed.
    case checkFailed

    public var isDarkbloom: Bool {
        if case .enrolledDarkbloom = self { return true }
        return false
    }

    /// The other build environment (dev or production) whose coordinator
    /// issued this profile. That install owns it: this install never treats
    /// it as its own enrollment and never offers to remove it.
    public var otherInstall: BuildEnvironment? {
        // An escaped server (see parseMDMEnrollmentStatus) is no install's.
        guard case .enrolledOtherMDM(let serverURL) = self, !serverURL.contains("\\u{"),
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
        return "the \(other.cliName) provider's Darkbloom MDM profile (\(serverURL)); remove it with `\(other.cliName) unenroll`"
    }
    return "another MDM (\(serverURL))"
}

/// Host of the coordinator that served an environment's enrollment profiles.
func mdmHost(of environment: BuildEnvironment) -> String? {
    URL(string: environment.coordinatorHTTPURL)?.host?.lowercased()
}

/// MDM hosts that are ours: the build environment's coordinator host and
/// these suffixes, a fixed list. A configured coordinator URL never adds a
/// host: an employer's MDM must not become "Darkbloom's" through a config, or
/// it would be offered for removal. The other build environment's coordinator
/// host is never ours: that install owns it.
let darkbloomMDMHostSuffixes = [".darkbloom.dev", ".darkbloom.ai"]
let retiredDarkbloomMDMHosts = ["api.dev.darkbloom.xyz"]

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
    environment: BuildEnvironment = .current
) -> MDMEnrollmentState {
    var enrolled = false
    var serverURL: String?
    var serverLines = 0

    for rawLine in output.split(separator: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        let lower = line.lowercased()
        if lower.hasPrefix("mdm enrollment:") {
            let value = line.dropFirst("mdm enrollment:".count)
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            enrolled = value.hasPrefix("yes")
        } else if lower.hasPrefix("mdm server:") {
            serverLines += 1
            serverURL = (serverURL.map { $0 + " " } ?? "") + line.dropFirst("mdm server:".count)
                .trimmingCharacters(in: .whitespaces)
        }
    }

    guard enrolled else { return .notEnrolled }

    // The server text is printed back to the operator. A control, format or
    // line-separator character (ESC, CR, a bidi override, U+2028) could rewrite
    // the line that names the profile, so such a server is never ours and is
    // shown escaped. macOS reports one server; two lines (one smuggled in a
    // server string) are not ours either.
    if let raw = serverURL, serverLines > 1 || raw.unicodeScalars.contains(where: unsafeForDisplay.contains) {
        return .enrolledOtherMDM(serverURL: escapingControlCharacters(raw))
    }

    guard let serverURL, let url = URL(string: serverURL), url.scheme?.lowercased() == "https",
          let host = url.host?.lowercased() else {
        // Enrolled but the server is unreadable or not https (every Darkbloom
        // profile was): claiming "Darkbloom" here would offer an unidentified
        // profile for removal, so report it as foreign and let the operator
        // inspect System Settings.
        return .enrolledOtherMDM(serverURL: serverURL ?? "<unknown>")
    }

    // A retired host's DNS or infrastructure may no longer be ours.
    if retiredDarkbloomMDMHosts.contains(host) {
        return .enrolledOtherMDM(serverURL: serverURL)
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

/// Scalars that can move the cursor or reorder a terminal line.
private let unsafeForDisplay = CharacterSet.controlCharacters.union(.newlines)

/// `text` with each control, format or line-separator scalar written as `\u{XXXX}`.
func escapingControlCharacters(_ text: String) -> String {
    text.unicodeScalars.map { scalar in
        unsafeForDisplay.contains(scalar)
            ? "\\u{\(String(scalar.value, radix: 16, uppercase: true))}" : String(scalar)
    }.joined()
}

/// Query this Mac's MDM enrollment state via `profiles status -type enrollment`
/// (works unprivileged). Only the fixed Darkbloom hosts count as ours.
///
/// When the tool itself fails (spawn error, non-zero exit with no output)
/// the result is `.checkFailed`, NOT `.notEnrolled`: callers say the state is
/// unknown instead of asserting non-enrollment.
public func checkMDMEnrollment() -> MDMEnrollmentState {
    checkMDMEnrollment(runner: .live)
}

func checkMDMEnrollment(runner: SecurityCommandRunner) -> MDMEnrollmentState {
    let result: SecurityCommandResult
    do {
        result = try runner.run("/usr/bin/profiles", ["status", "-type", "enrollment"])
    } catch {
        return .checkFailed
    }
    let output = result.stdout
    if result.terminationStatus != 0
        && output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return .checkFailed
    }

    return parseMDMEnrollmentStatus(output)
}
