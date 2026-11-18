import Foundation
import Testing
@testable import ProviderCore

@Suite("authenticated root in the boot-security posture")
struct AuthenticatedRootPostureTests {
    private func snapshot(_ authenticatedRoot: Bool?) -> BootSecuritySnapshot {
        BootSecuritySnapshot(macOSMajorVersion: 27, sip: .enabled, sipConfiguration: SIPConfiguration(rawValue: 0),
                             secureBoot: .full, authenticatedRoot: authenticatedRoot)
    }

    private static let csrutil = "/usr/bin/csrutil"
    private static let diskutil = "/usr/sbin/diskutil"

    /// Answers only the exact commands the reading may run, and records them in order. `nil` makes that command
    /// unusable; any other command fails the test.
    private final class Commands: @unchecked Sendable {
        var csrutil: SecurityCommandResult?
        var diskutil: SecurityCommandResult?
        var csrutilStatus: SecurityCommandResult?
        private(set) var ran: [String] = []

        init(csrutil: SecurityCommandResult?, diskutil: SecurityCommandResult? = nil) {
            self.csrutil = csrutil
            self.diskutil = diskutil
        }

        var runner: SecurityCommandRunner {
            SecurityCommandRunner { path, arguments in
                let command = ([path] + arguments).joined(separator: " ")
                self.ran.append(command)
                let answer: SecurityCommandResult?
                switch command {
                case "\(AuthenticatedRootPostureTests.csrutil) authenticated-root status": answer = self.csrutil
                case "\(AuthenticatedRootPostureTests.diskutil) info /": answer = self.diskutil
                case "\(AuthenticatedRootPostureTests.csrutil) status": answer = self.csrutilStatus
                default:
                    Issue.record("unexpected command: \(command)")
                    answer = nil
                }
                guard let answer else { throw SecurityCommandRunner.CommandError.timedOut }
                return answer
            }
        }
    }

    private func reading(_ csrutil: SecurityCommandResult?, diskutil: SecurityCommandResult? = nil) -> (Bool?, [String]) {
        let commands = Commands(csrutil: csrutil, diskutil: diskutil)
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
        let csrutilOnly = ["\(Self.csrutil) authenticated-root status"]
        let disabled = reading(Self.out("Authenticated Root status: disabled\n"), diskutil: Self.out("Sealed: Yes\n"))
        #expect(disabled.0 == false)
        #expect(disabled.1 == csrutilOnly, "an explicit answer is final; a seal never overrides it")
        let enabled = reading(Self.out("Authenticated Root status: enabled\n"))
        #expect(enabled.0 == true)
        #expect(enabled.1 == csrutilOnly)
    }

    @Test("any other csrutil answer is unread, and only a sealed volume confirms it")
    func ambiguousAnswersAreUnread() {
        let both = ["\(Self.csrutil) authenticated-root status", "\(Self.diskutil) info /"]
        let unclear: [(String, SecurityCommandResult)] = [
            ("both words", Self.out("Authenticated Root status: enabled\nAuthenticated Root status: disabled\n")),
            ("an extra line", Self.out("Authenticated Root status: enabled\nwarning: the root volume is disabled for updates\n")),
            ("an error that exits 0", Self.out("csrutil: failed to read the configuration; it may be disabled\n")),
            ("localized", Self.out("Statut de la racine authentifiée : désactivé\n")),
            ("a nonzero exit carrying status text", Self.out("Authenticated Root status: disabled\n", status: 1)),
            ("anything on stderr", Self.out("Authenticated Root status: disabled\n", stderr: "csrutil: note\n")),
            ("a negation", Self.out("Authenticated Root status: not disabled\n")),
            ("empty", Self.out("")),
        ]
        for (name, answer) in unclear {
            let unread = reading(answer)
            #expect(unread.0 == nil, "\(name)")
            #expect(unread.1 == both, "\(name): diskutil is asked")
            #expect(reading(answer, diskutil: Self.out("   Sealed:                    Yes\n")).0 == true, "\(name): a seal confirms")
        }
        // A seal only confirms: macOS can say "Broken" for a healthy seal, so nothing but "Yes" counts.
        for sealed in ["Broken", "No", "Yes (with changes)", ""] {
            #expect(reading(nil, diskutil: Self.out("   Sealed:  \(sealed)\n")).0 == nil, "Sealed: \(sealed)")
        }
        #expect(reading(nil, diskutil: Self.out("   Sealed:  Yes\n")).0 == true)
        #expect(reading(nil, diskutil: Self.out("   Sealed:  Yes\n", status: 1)).0 == nil)
        // A timed-out or failed command is unread.
        #expect(reading(nil, diskutil: nil).0 == nil)
    }

    @Test("live(runner:) carries each reading into the snapshot")
    func liveCarriesTheReading() {
        for (answer, expected) in [(Self.out("Authenticated Root status: enabled\n"), Optional(true)),
                                   (Self.out("Authenticated Root status: disabled\n"), false),
                                   (Self.out("unexpected\n"), nil)] {
            let commands = Commands(csrutil: answer, diskutil: Self.out("   Sealed:  Broken\n"))
            commands.csrutilStatus = Self.out("System Integrity Protection status: enabled.\n")
            let snapshot = BootSecuritySnapshot.live(runner: commands.runner)
            #expect(snapshot.authenticatedRoot == expected)
            #expect(commands.ran.contains("\(Self.csrutil) authenticated-root status"))
        }
    }

    @Test("the live reading's commands have a deadline")
    func liveCommandsAreBounded() throws {
        #expect(BootSecuritySnapshot.commandTimeout <= 5)
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
        for (value, expected) in [(Optional(false), Optional(false)), (true, true), (nil, nil)] {
            let reported = capabilities.reportingBootSecurity(snapshot(value))
            let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(reported)) as? [String: Any])
            #expect(object["authenticated_root"] as? Bool == expected)
            #expect((object["authenticated_root"] == nil) == (expected == nil))
        }
    }
}
