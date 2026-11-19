import Foundation
import Testing
@testable import ProviderCore

@Suite("authenticated root in the boot-security posture")
struct AuthenticatedRootPostureTests {
    private func snapshot(_ authenticatedRoot: Bool?) -> BootSecuritySnapshot {
        BootSecuritySnapshot(macOSMajorVersion: 27, sip: .enabled, sipConfiguration: SIPConfiguration(rawValue: 0),
                             secureBoot: .full, authenticatedRoot: authenticatedRoot)
    }

    private struct Command: Hashable, CustomStringConvertible {
        let executable: String
        let arguments: [String]
        var description: String { ([executable] + arguments).joined(separator: " ") }
    }

    private static let rootStatus = Command(executable: "/usr/bin/csrutil", arguments: ["authenticated-root", "status"])
    private static let sealInfo = Command(executable: "/usr/sbin/diskutil", arguments: ["info", "/"])
    private static let sipStatus = Command(executable: "/usr/bin/csrutil", arguments: ["status"])
    private static let secureBootReport = Command(executable: "/usr/sbin/system_profiler",
                                                  arguments: ["-json", "SPiBridgeDataType"])

    private struct UnexpectedCommand: Error {}

    /// Answers only the exact commands (executable and argument list) the reading may run, and records them in order.
    /// A known command without an answer times out; any other command fails the test at once.
    private final class Commands: @unchecked Sendable {
        let answers: [Command: SecurityCommandResult]
        private(set) var ran: [Command] = []

        init(_ answers: [Command: SecurityCommandResult?]) {
            self.answers = answers.compactMapValues { $0 }
        }

        var runner: SecurityCommandRunner {
            SecurityCommandRunner { executable, arguments in
                let command = Command(executable: executable, arguments: arguments)
                self.ran.append(command)
                let known = [AuthenticatedRootPostureTests.rootStatus, AuthenticatedRootPostureTests.sealInfo,
                             AuthenticatedRootPostureTests.sipStatus, AuthenticatedRootPostureTests.secureBootReport]
                guard known.contains(command) else {
                    Issue.record("unexpected command: \(command)")
                    throw UnexpectedCommand()
                }
                guard let answer = self.answers[command] else { throw SecurityCommandRunner.CommandError.timedOut }
                return answer
            }
        }
    }

    private func reading(_ csrutil: SecurityCommandResult?, diskutil: SecurityCommandResult? = nil) -> (Bool?, [Command]) {
        let commands = Commands([Self.rootStatus: csrutil, Self.sealInfo: diskutil])
        return (authenticatedRootPolicy(runner: commands.runner), commands.ran)
    }

    private static func out(_ stdout: String, status: Int32 = 0, stderr: String = "") -> SecurityCommandResult {
        SecurityCommandResult(terminationStatus: status, stdout: stdout, stderr: stderr)
    }

    @Test("off refuses Darkbloom serving and names the fix; on or unread doesn't")
    func refusal() throws {
        let off = snapshot(false)
        #expect(off.authenticatedRootVerdict == .fail)
        let refusal = try #require(off.servingRefusals.first)
        #expect(off.servingRefusals.count == 1)
        #expect(refusal.kind == .authenticatedRoot)
        #expect(refusal.name == "Authenticated root")
        #expect(refusal.fix.contains("csrutil authenticated-root enable"))

        #expect(snapshot(true).servingRefusals.isEmpty)
        #expect(snapshot(true).authenticatedRootVerdict == .pass)
        // Unread is a doctor warning, never a refusal.
        #expect(snapshot(nil).servingRefusals.isEmpty)
        #expect(snapshot(nil).authenticatedRootVerdict == .warn)
        // A snapshot built without a reading is unread, never a guessed "enabled".
        #expect(BootSecuritySnapshot(macOSMajorVersion: 27, sip: .enabled).authenticatedRoot == nil)
    }

    @Test("only csrutil's exact answer decides, before diskutil is asked")
    func reading() {
        for (stdout, expected) in [("Authenticated Root status: enabled\n", true), ("Authenticated Root status: enabled", true),
                                   ("Authenticated Root status: enabled.\n", true), ("Authenticated Root status: disabled\n", false),
                                   ("Authenticated Root status: disabled.", false)] {
            let answered = reading(Self.out(stdout), diskutil: Self.out("Sealed: Yes\n"))
            #expect(answered.0 == expected, "\(stdout.debugDescription)")
            #expect(answered.1 == [Self.rootStatus], "an explicit answer is final; a seal never overrides it")
        }
    }

    @Test("any other csrutil answer is unread, and only a sealed volume confirms it")
    func ambiguousAnswersAreUnread() {
        let unclear: [(String, SecurityCommandResult)] = [
            ("both words", Self.out("Authenticated Root status: enabled\nAuthenticated Root status: disabled\n")),
            ("an extra line", Self.out("Authenticated Root status: enabled\nwarning: the root volume is disabled for updates\n")),
            ("a blank line first", Self.out("\nAuthenticated Root status: disabled\n")),
            ("two newlines after", Self.out("Authenticated Root status: disabled\n\n")),
            ("padding", Self.out(" Authenticated Root status: disabled\n")),
            ("an error that exits 0", Self.out("csrutil: failed to read the configuration; it may be disabled\n")),
            ("localized", Self.out("Statut de la racine authentifiée : désactivé\n")),
            ("a nonzero exit carrying status text", Self.out("Authenticated Root status: disabled\n", status: 1)),
            ("anything on stderr", Self.out("Authenticated Root status: disabled\n", stderr: "csrutil: note\n")),
            ("whitespace on stderr", Self.out("Authenticated Root status: disabled\n", stderr: " \n")),
            ("undecodable stderr", SecurityCommandResult(terminationStatus: 0, stdout: "Authenticated Root status: disabled\n",
                                                         stderr: "", wroteToStderr: true)),
            ("a negation", Self.out("Authenticated Root status: not disabled\n")),
            ("empty", Self.out("")),
        ]
        for (name, answer) in unclear {
            let unread = reading(answer)
            #expect(unread.0 == nil, "\(name)")
            #expect(unread.1 == [Self.rootStatus, Self.sealInfo], "\(name): csrutil first, then diskutil")
            #expect(reading(answer, diskutil: Self.out("   Sealed:                    Yes\n")).0 == true, "\(name): a seal confirms")
        }
        // A seal only confirms: macOS can say "Broken" for a healthy seal, so nothing but "Yes" counts.
        for sealed in ["Broken", "No", "yes", "Yes (with changes)", ""] {
            #expect(reading(nil, diskutil: Self.out("   Sealed:  \(sealed)\n")).0 == nil, "Sealed: \(sealed)")
        }
        #expect(reading(nil, diskutil: Self.out("   Sealed:  Yes\n")).0 == true)
        #expect(reading(nil, diskutil: Self.out("   Sealed:  Yes\n", status: 1)).0 == nil)
        // A timed-out or failed command is unread.
        #expect(reading(nil, diskutil: nil).0 == nil)
    }

    @Test("the command runner reports undecodable stderr as written, and keeps stdout's strict decoding")
    func undecodableOutput() throws {
        let runner = SecurityCommandRunner.bounded(timeout: 10)
        let stderr = try runner.run("/bin/sh", ["-c", "printf '\\377' >&2"])
        #expect(stderr.stderr.isEmpty && stderr.wroteToStderr, "undecodable stderr decodes to empty but counts as written")
        #expect(!(try runner.run("/bin/sh", ["-c", "true"])).wroteToStderr)
        // Stdout that doesn't decode stays empty, as the older readings expect, even with a recognizable status in it.
        let stdout = try runner.run("/bin/sh", ["-c", "printf 'Authenticated Root status: enabled\\n\\377'"])
        #expect(stdout.stdout.isEmpty)
    }

    @Test("live(runner:kernelSIP:) carries each reading into the snapshot")
    func liveCarriesTheReading() {
        let fullSecurity = Self.out(#"{"SPiBridgeDataType":[{"ibridge_secure_boot":"Full Security"}]}"#)
        for (answer, expected) in [(Self.out("Authenticated Root status: enabled\n"), Optional(true)),
                                   (Self.out("Authenticated Root status: disabled\n"), false),
                                   (Self.out("unexpected\n"), nil)] {
            let commands = Commands([Self.rootStatus: answer, Self.sealInfo: Self.out("   Sealed:  Broken\n"),
                                     Self.sipStatus: Self.out("System Integrity Protection status: enabled.\n"),
                                     Self.secureBootReport: fullSecurity])
            let snapshot = BootSecuritySnapshot.live(runner: commands.runner, kernelSIP: { SIPConfiguration(rawValue: 0) })
            #expect(snapshot.authenticatedRoot == expected)
            #expect(snapshot.secureBoot == .full)
            #expect(snapshot.sipAtDefault)
            #expect(commands.ran.contains(Self.rootStatus))
        }
    }

    @Test("SIP fails closed only without the kernel value; a timed-out csrutil says so")
    func sipFallbackTimeout() {
        let commands = Commands([Self.rootStatus: Self.out("Authenticated Root status: enabled\n"),
                                 Self.secureBootReport: Self.out(#"{"SPiBridgeDataType":[{"ibridge_secure_boot":"Full Security"}]}"#)])
        // `csrutil status` has no answer (it times out).
        let withKernel = BootSecuritySnapshot.live(runner: commands.runner, kernelSIP: { SIPConfiguration(rawValue: 0) })
        #expect(withKernel.sipAtDefault, "the kernel's default value decides; the timed-out fallback doesn't refuse")
        #expect(withKernel.servingRefusals.isEmpty)
        let withoutKernel = BootSecuritySnapshot.live(runner: commands.runner, kernelSIP: { nil })
        #expect(withoutKernel.servingRefusals.map(\.kind) == [.sip], "without the kernel value, SIP fails closed")
        #expect(withoutKernel.sipSummary.contains("did not answer in time"))
        guard case .unavailable(let reason) = SIPStatusChecker(runner: commands.runner).status() else {
            Issue.record("a timed-out csrutil status is unavailable"); return
        }
        #expect(reason == "`csrutil status` did not answer in time")
    }

    @Test("each boot-settings command has a deadline; SIP's fallback the longer one")
    func liveCommandsAreBounded() throws {
        #expect(BootSecuritySnapshot.commandTimeout <= 5)
        #expect(BootSecuritySnapshot.sipCommandTimeout >= 20)
        let started = ContinuousClock.now
        #expect(throws: SecurityCommandRunner.CommandError.self) {
            _ = try BootSecuritySnapshot.liveRunner.run("/bin/sleep", ["30"])
        }
        #expect(ContinuousClock.now - started < .seconds(BootSecuritySnapshot.commandTimeout + 5))
    }

    @Test("the registration reports it when read, and leaves it out when not")
    func report() throws {
        let capabilities = PrivacyCapabilities(textBackendInprocess: true, textProxyDisabled: true, sipEnabled: true,
                                               antiDebugEnabled: true, coreDumpsDisabled: true, envScrubbed: true)
        func encoded(_ snapshot: BootSecuritySnapshot) throws -> [String: Any] {
            let reported = capabilities.reportingBootSecurity(snapshot)
            return try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(reported)) as? [String: Any])
        }
        for (value, expected) in [(Optional(false), Optional(false)), (true, true)] {
            #expect(try encoded(snapshot(value))["authenticated_root"] as? Bool == expected)
        }
        // A snapshot built without a reading leaves the key out.
        #expect(try encoded(BootSecuritySnapshot(macOSMajorVersion: 27, sip: .enabled)).keys.contains("authenticated_root") == false)
        #expect(try encoded(snapshot(nil)).keys.contains("authenticated_root") == false)
    }
}
