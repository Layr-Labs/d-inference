import Testing
@testable import ProviderCore

enum SIPStatusFixtures {
    /// `csrutil status` after `csrutil enable --without debug --without dtrace` on macOS 11 and later.
    static let modernCustom = """
    System Integrity Protection status: unknown (Custom Configuration).

    Configuration:
    \tApple Internal: disabled
    \tKext Signing: enabled
    \tFilesystem Protections: enabled
    \tDebugging Restrictions: disabled
    \tDTrace Restrictions: disabled
    \tNVRAM Protections: enabled
    \tBaseSystem Verification: enabled
    \tBoot-arg Restrictions: enabled
    \tKernel Integrity Protections: enabled
    \tAuthenticated Root Requirement: enabled

    This is an unsupported configuration, likely to break in the future and leave your machine in an unknown state.
    """
}

/// The `csrutil status` fallback, used when the kernel's SIP configuration
/// can't be read, and the protections `doctor` names from it.
@Suite("csrutil status parsing")
struct SIPStatusParserTests {
    @Test("macOS 11+ \"unknown (Custom Configuration)\" is a custom configuration naming what is off")
    func modernCustomOutput() {
        let status = SIPStatusParser.parse(SIPStatusFixtures.modernCustom)
        #expect(status == .enabledWithCustomConfiguration(
            disabledProtections: ["Debugging Restrictions", "DTrace Restrictions"]))
        #expect(status.summary.contains("Debugging Restrictions, DTrace Restrictions"))
        #expect(!status.isFullyEnabled)
    }

    @Test("Apple Internal is a permission: \"enabled\" is the relaxation")
    func appleInternalPolarity() {
        let internalOn = SIPStatusFixtures.modernCustom
            .replacingOccurrences(of: "Apple Internal: disabled", with: "Apple Internal: enabled")
        #expect(SIPStatusParser.parse(internalOn) == .enabledWithCustomConfiguration(
            disabledProtections: ["Apple Internal", "Debugging Restrictions", "DTrace Restrictions"]))
    }
}
