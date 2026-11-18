import Foundation
import Testing
@testable import ProviderCore

@Suite("authenticated root in the boot-security posture")
struct AuthenticatedRootPostureTests {
    private func snapshot(_ authenticatedRoot: Bool?) -> BootSecuritySnapshot {
        BootSecuritySnapshot(macOSMajorVersion: 27, sip: .enabled, sipConfiguration: SIPConfiguration(rawValue: 0),
                             secureBoot: .full, authenticatedRoot: authenticatedRoot)
    }

    private func runner(_ csrutil: (Int32, String)?, diskutil: (Int32, String)? = nil) -> SecurityCommandRunner {
        SecurityCommandRunner { path, _ in
            switch path {
            case "/usr/bin/csrutil":
                guard let csrutil else { throw CocoaError(.executableNotLoadable) }
                return SecurityCommandResult(terminationStatus: csrutil.0, stdout: csrutil.1)
            default:
                guard let diskutil else { throw CocoaError(.executableNotLoadable) }
                return SecurityCommandResult(terminationStatus: diskutil.0, stdout: diskutil.1)
            }
        }
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
        // A snapshot built without the field reads enabled.
        #expect(BootSecuritySnapshot(macOSMajorVersion: 27, sip: .enabled).authenticatedRoot == true)
    }

    @Test("only csrutil's explicit answer decides; diskutil only confirms a seal")
    func reading() {
        #expect(authenticatedRootPolicy(runner: runner((0, "Authenticated Root status: disabled\n"))) == false)
        #expect(authenticatedRootPolicy(runner: runner((0, "Authenticated Root status: enabled\n"))) == true)
        // csrutil unusable: a sealed volume confirms it; anything else (macOS 26 can say "Broken" for a healthy
        // seal) stays unread rather than refusing a default Mac.
        #expect(authenticatedRootPolicy(runner: runner(nil, diskutil: (0, "   Sealed:  Yes\n"))) == true)
        #expect(authenticatedRootPolicy(runner: runner(nil, diskutil: (0, "   Sealed:  Broken\n"))) == nil)
        #expect(authenticatedRootPolicy(runner: runner(nil, diskutil: (0, "   Sealed:  No\n"))) == nil)
        #expect(authenticatedRootPolicy(runner: runner((1, ""), diskutil: (1, ""))) == nil)
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
