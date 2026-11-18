import Testing
@testable import ProviderCore

@Suite("a sandbox the provider didn't set up")
struct ProcessSandboxTests {
    @Test("sandbox_check's answer: 1 is sandboxed, 0 is not, anything else is unknown")
    func sandboxCheckAnswers() {
        #expect(ProcessSandbox(sandboxCheckResult: 1) == .sandboxed)
        #expect(ProcessSandbox(sandboxCheckResult: 0) == .notSandboxed)
        #expect(ProcessSandbox(sandboxCheckResult: -1) == .unknown)
        #expect(ProcessSandbox(sandboxCheckResult: 2) == .unknown)
    }

    @Test("host probe: the check answers for this process")
    func liveCheck() {
        #expect(ProcessSandbox.current() != .unknown)
    }

    @Test("inside a sandbox the provider didn't set up, Darkbloom serving is refused and named")
    func sandboxedRefuses() throws {
        // SIP at its default and Secure Boot unread: on their own, only a warning.
        let sandboxed = BootSecuritySnapshot(macOSMajorVersion: 27, sip: .enabled,
                                             sipConfiguration: SIPConfiguration(rawValue: 0), secureBoot: .unknown,
                                             processSandbox: .sandboxed)
        #expect(sandboxed.processSandboxVerdict == .fail)
        let refusal = try #require(sandboxed.servingRefusals.first)
        #expect(sandboxed.servingRefusals.count == 1)
        #expect(refusal.name == "Process sandbox")
        #expect(refusal.detail.contains("sandbox"))
        #expect(refusal.fix.contains("outside"))
        #expect(sandboxed.issues.map(\.name) == ["Process sandbox"])

        // Every other refusal is still named alongside it.
        let both = BootSecuritySnapshot(macOSMajorVersion: 27, sip: .enabled,
                                        sipConfiguration: SIPConfiguration(rawValue: 0x24), secureBoot: .unknown,
                                        processSandbox: .sandboxed)
        #expect(both.servingRefusals.map(\.name) == ["System Integrity Protection (SIP)", "Process sandbox"])
    }

    @Test("not sandboxed: nothing changes; an unanswered check only warns")
    func notSandboxed() {
        let plain = BootSecuritySnapshot(macOSMajorVersion: 27, sip: .enabled,
                                         sipConfiguration: SIPConfiguration(rawValue: 0), secureBoot: .unknown,
                                         processSandbox: .notSandboxed)
        #expect(plain.servingRefusals.isEmpty)
        #expect(plain.processSandboxVerdict == .pass)
        #expect(plain.secureBootVerdict == .warn)

        let unchecked = BootSecuritySnapshot(macOSMajorVersion: 27, sip: .enabled,
                                             sipConfiguration: SIPConfiguration(rawValue: 0), secureBoot: .full,
                                             processSandbox: .unknown)
        #expect(unchecked.servingRefusals.isEmpty)
        #expect(unchecked.processSandboxVerdict == .warn)

        // A snapshot built without the field is not sandboxed.
        #expect(BootSecuritySnapshot(macOSMajorVersion: 27, sip: .enabled).processSandbox == .notSandboxed)
    }
}
