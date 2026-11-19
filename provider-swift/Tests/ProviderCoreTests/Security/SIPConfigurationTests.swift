import Foundation
import Testing
@testable import ProviderCore

/// Darkbloom serves only with System Integrity Protection at Apple's default
/// configuration: no `CSR_ALLOW_*` bit set. Every documented flag, alone and
/// combined, must refuse serving, name what it turns off, and report the exact
/// value; only 0 passes.
@Suite("SIP configuration posture")
struct SIPConfigurationTests {
    /// `<sys/csr.h>`'s documented flags (CSR_VALID_FLAGS), by value.
    static let documentedFlags: [(bit: UInt32, flag: String)] = [
        (0x1, "CSR_ALLOW_UNTRUSTED_KEXTS"),
        (0x2, "CSR_ALLOW_UNRESTRICTED_FS"),
        (0x4, "CSR_ALLOW_TASK_FOR_PID"),
        (0x8, "CSR_ALLOW_KERNEL_DEBUGGER"),
        (0x10, "CSR_ALLOW_APPLE_INTERNAL"),
        (0x20, "CSR_ALLOW_UNRESTRICTED_DTRACE"),
        (0x40, "CSR_ALLOW_UNRESTRICTED_NVRAM"),
        (0x80, "CSR_ALLOW_DEVICE_CONFIGURATION"),
        (0x100, "CSR_ALLOW_ANY_RECOVERY_OS"),
        (0x200, "CSR_ALLOW_UNAPPROVED_KEXTS"),
        (0x400, "CSR_ALLOW_EXECUTABLE_POLICY_OVERRIDE"),
        (0x800, "CSR_ALLOW_UNAUTHENTICATED_ROOT"),
        (0x1000, "CSR_ALLOW_RESEARCH_GUESTS"),
    ]
    static let documentedBits: [UInt32] = documentedFlags.map { $0.bit }

    /// `sip` defaults to `csrutil status` on a default Mac: the kernel value
    /// decides, so even that text cannot make a non-default configuration pass.
    private func snapshot(_ raw: UInt32?, sip: SIPStatus = .enabled,
                          secureBoot: SecureBootPolicy = .full) -> BootSecuritySnapshot {
        BootSecuritySnapshot(macOSMajorVersion: 27, sip: sip,
                             sipConfiguration: raw.map(SIPConfiguration.init(rawValue:)), secureBoot: secureBoot)
    }

    private func csrutil(_ stdout: String) -> SecurityCommandRunner {
        SecurityCommandRunner { path, arguments in
            #expect(path == "/usr/bin/csrutil")
            #expect(arguments == ["status"])
            return SecurityCommandResult(terminationStatus: 0, stdout: stdout)
        }
    }

    @Test("the table matches <sys/csr.h>: every documented flag, once, in bit order")
    func tableMatchesHeader() {
        #expect(SIPConfiguration.documentedRelaxations.map(\.bit) == Self.documentedBits)
        #expect(SIPConfiguration.documentedRelaxations.map(\.flag) == Self.documentedFlags.map { $0.flag })
        #expect(Set(SIPConfiguration.documentedRelaxations.map(\.protection)).count == Self.documentedFlags.count)
        #expect(SIPConfiguration.documentedRelaxations.reduce(UInt32(0)) { $0 | $1.bit } == 0x1FFF)
    }

    @Test("the default configuration (0) serves")
    func defaultServes() {
        let posture = snapshot(0)
        #expect(SIPConfiguration(rawValue: 0).isDefault)
        #expect(SIPConfiguration(rawValue: 0).relaxedProtections.isEmpty)
        #expect(posture.sipAtDefault)
        #expect(posture.sipVerdict == .pass)
        #expect(posture.servingRefusals.isEmpty)
        #expect(posture.sipSummary == "enabled (default configuration)")
        #expect(checkSIPEnabled(runner: csrutil("System Integrity Protection status: enabled.\n"),
                                configuration: SIPConfiguration(rawValue: 0)))
    }

    @Test("each documented flag alone refuses serving and is named", arguments: SIPConfigurationTests.documentedBits)
    func eachFlagAloneRefuses(_ bit: UInt32) throws {
        let configuration = SIPConfiguration(rawValue: bit)
        let relaxation = try #require(SIPConfiguration.documentedRelaxations.first { $0.bit == bit })
        #expect(!configuration.isDefault)
        #expect(configuration.relaxedProtections == [relaxation.protection])

        let posture = snapshot(bit)
        #expect(!posture.sipAtDefault)
        #expect(posture.sipVerdict == .fail)
        let refusal = try #require(posture.servingRefusals.first)
        #expect(posture.servingRefusals.count == 1)
        #expect(refusal.name == "System Integrity Protection (SIP)")
        #expect(refusal.detail.contains(relaxation.protection))
        #expect(refusal.detail.contains("0x" + String(bit, radix: 16)))
        #expect(refusal.fix.contains("csrutil enable"))

        // The signed self-report and the registration carry the refusal and the exact value.
        #expect(!checkSIPEnabled(runner: csrutil("System Integrity Protection status: enabled.\n"),
                                 configuration: configuration))
        let reported = sampleCapabilities.reportingBootSecurity(posture)
        #expect(reported.sipConfiguration == bit)
    }

    @Test("every pair of documented flags refuses serving and names both")
    func everyPairRefuses() {
        let flags = Self.documentedBits
        for (index, first) in flags.enumerated() {
            for second in flags[(index + 1)...] {
                let configuration = SIPConfiguration(rawValue: first | second)
                let names = SIPConfiguration.documentedRelaxations
                    .filter { $0.bit == first || $0.bit == second }.map(\.protection)
                #expect(configuration.relaxedProtections == names)
                #expect(snapshot(first | second).servingRefusals.count == 1)
                #expect(!checkSIPEnabled(runner: csrutil("System Integrity Protection status: enabled.\n"),
                                         configuration: configuration))
            }
        }
    }

    @Test("common combinations, undocumented bits and every bit refuse serving",
          arguments: [
              UInt32(0x46),        // csrutil enable --without fs --without debug --without nvram
              0x24,                // --without debug --without dtrace
              0x7F,                // CSR_DISABLE_FLAGS (csrutil disable)
              0x1FFF,              // CSR_VALID_FLAGS
              0x804,               // a debug exception with authenticated root off
              0x2000,              // the first undocumented bit
              0x8000_0000,         // the highest bit
              0xFFFF_FFFF,
          ])
    func combinationsRefuse(_ raw: UInt32) throws {
        let posture = snapshot(raw)
        #expect(posture.sipVerdict == .fail)
        let refusal = try #require(posture.servingRefusals.first)
        #expect(refusal.detail.contains("0x" + String(raw, radix: 16)))
        #expect(!SIPConfiguration(rawValue: raw).relaxedProtections.isEmpty)
        #expect(SIPConfiguration(rawValue: raw).relaxedProtections.count == raw.nonzeroBitCount)
    }

    @Test("undocumented bits are named by value, after the documented ones")
    func undocumentedBitsNamed() {
        #expect(SIPConfiguration(rawValue: 0x2004).relaxedProtections
                == ["Debugging Restrictions", "undocumented bit 0x2000"])
        #expect(SIPConfiguration(rawValue: 0x8000_0000).relaxedProtections == ["undocumented bit 0x80000000"])
    }

    @Test("authenticated root off adds its own command to the fix")
    func authenticatedRootFix() throws {
        let refusal = try #require(snapshot(0x804).servingRefusals.first)
        #expect(refusal.fix.contains("csrutil enable"))
        #expect(refusal.fix.contains("csrutil authenticated-root enable"))
        #expect(try #require(snapshot(0x4).servingRefusals.first).fix.contains("authenticated-root") == false)
    }

    @Test("the kernel value decides over csrutil's text")
    func kernelValueIsAuthoritative() {
        let custom = SIPStatus.enabledWithCustomConfiguration(disabledProtections: ["Debugging Restrictions"])
        #expect(snapshot(0, sip: custom).sipAtDefault)
        #expect(!snapshot(0x4, sip: .enabled).sipAtDefault)
    }

    @Test("without the kernel value only csrutil's plain \"enabled.\" serves")
    func csrutilFallback() throws {
        #expect(snapshot(nil, sip: .enabled).sipAtDefault)
        for status: SIPStatus in [
            .enabledWithCustomConfiguration(disabledProtections: ["Debugging Restrictions"]),
            .disabled, .unavailable(reason: "csrutil failed"), .unrecognized(output: "?"),
        ] {
            #expect(!snapshot(nil, sip: status).sipAtDefault)
            #expect(snapshot(nil, sip: status).servingRefusals.count == 1)
        }
        let custom = try #require(snapshot(nil, sip: .enabledWithCustomConfiguration(
            disabledProtections: ["Debugging Restrictions", "DTrace Restrictions"])).servingRefusals.first)
        #expect(custom.detail.contains("Debugging Restrictions, DTrace Restrictions"))
        #expect(custom.fix.contains("csrutil enable"))
        let unreadable = try #require(snapshot(nil, sip: .unavailable(reason: "csrutil failed")).servingRefusals.first)
        #expect(unreadable.fix.contains("csrutil status"))

        // The signed self-report follows the same fallback; a custom configuration is never "enabled".
        #expect(checkSIPEnabled(runner: csrutil("System Integrity Protection status: enabled.\n"), configuration: nil))
        #expect(!checkSIPEnabled(runner: csrutil(SIPStatusFixtures.modernCustom), configuration: nil))
        #expect(!checkSIPEnabled(runner: csrutil(
            "System Integrity Protection status: enabled (Custom Configuration).\n\nConfiguration:\n\tKext Signing: disabled\n"),
            configuration: nil))
    }

    @Test("Secure Boot: only an explicit downgrade refuses; an unreadable report is a warning")
    func secureBoot() throws {
        #expect(snapshot(0, secureBoot: .full).servingRefusals.isEmpty)
        #expect(snapshot(0, secureBoot: .full).secureBootVerdict == .pass)
        for policy: SecureBootPolicy in [.reduced, .permissive] {
            let refusal = try #require(snapshot(0, secureBoot: policy).servingRefusals.first)
            #expect(refusal.name == "Secure Boot")
            #expect(refusal.detail.contains(policy.summary))
            #expect(refusal.fix.contains("Full Security"))
            #expect(snapshot(0, secureBoot: policy).secureBootVerdict == .fail)
        }
        #expect(snapshot(0, secureBoot: .unknown).servingRefusals.isEmpty)
        #expect(snapshot(0, secureBoot: .unknown).secureBootVerdict == .warn)
        // A Mac with a SIP exception on Apple silicon is also in Permissive Security: both are named.
        #expect(snapshot(0x4, secureBoot: .permissive).servingRefusals.map(\.name)
                == ["System Integrity Protection (SIP)", "Secure Boot"])
    }

    @Test("system_profiler's JSON report maps to the policy; anything unexpected is unknown")
    func secureBootParsing() {
        func report(_ value: String) -> Data {
            Data(#"{"SPiBridgeDataType":[{"ibridge_sb_sip":"Enabled","ibridge_secure_boot":"\#(value)"}]}"#.utf8)
        }
        #expect(SecureBootPolicy.parse(systemProfilerJSON: report("Full Security")) == .full)
        #expect(SecureBootPolicy.parse(systemProfilerJSON: report("Reduced Security")) == .reduced)
        #expect(SecureBootPolicy.parse(systemProfilerJSON: report("Permissive Security")) == .permissive)
        #expect(SecureBootPolicy.parse(systemProfilerJSON: report("Medium Security")) == .reduced)
        #expect(SecureBootPolicy.parse(systemProfilerJSON: report("No Security")) == .permissive)
        #expect(SecureBootPolicy.parse(systemProfilerJSON: report("Sécurité maximale")) == .unknown)
        #expect(SecureBootPolicy.parse(systemProfilerJSON: Data(#"{"SPiBridgeDataType":[{}]}"#.utf8)) == .unknown)
        #expect(SecureBootPolicy.parse(systemProfilerJSON: Data("not json".utf8)) == .unknown)

        let failing = SecurityCommandRunner { _, _ in SecurityCommandResult(terminationStatus: 1) }
        #expect(SecureBootPolicy.current(runner: failing) == .unknown)
        let full = SecurityCommandRunner { path, arguments in
            #expect(path == "/usr/sbin/system_profiler")
            #expect(arguments == ["-json", "SPiBridgeDataType"])
            return SecurityCommandResult(terminationStatus: 0, stdout: String(decoding: report("Full Security"), as: UTF8.self))
        }
        #expect(SecureBootPolicy.current(runner: full) == .full)
    }

    @Test("registration reports the exact SIP value and the Secure Boot policy, unknown when unread")
    func registrationReport() throws {
        let reported = sampleCapabilities.reportingBootSecurity(snapshot(0x24, secureBoot: .permissive))
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(reported)) as? [String: Any])
        #expect(object["sip_configuration"] as? Int == 0x24)
        #expect(object["secure_boot"] as? String == "permissive")

        let unread = sampleCapabilities.reportingBootSecurity(snapshot(nil, secureBoot: .unknown))
        let unreadObject = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(unread)) as? [String: Any])
        #expect(unreadObject["sip_configuration"] == nil)
        #expect(unreadObject["secure_boot"] as? String == "unknown")

        let decoded = try JSONDecoder().decode(PrivacyCapabilities.self, from: JSONEncoder().encode(reported))
        #expect(decoded == reported)
    }

    @Test("host probe: the live kernel value is readable on this Mac (any value)")
    func liveReader() {
        #expect(SIPConfigurationReader.current() != nil)
    }

    private var sampleCapabilities: PrivacyCapabilities {
        PrivacyCapabilities(textBackendInprocess: true, textProxyDisabled: true, sipEnabled: true,
                            antiDebugEnabled: true, coreDumpsDisabled: true, envScrubbed: true)
    }
}
