import Foundation
import Testing
@testable import ProviderCore

/// Unit tests for the Secure Boot detection layer, the macOS-version + SIP +
/// Secure Boot gate policy, and the shared enable guidance.
///
/// Detection runs through an injected `SecurityCommandRunner` fed REAL shapes of
/// `system_profiler SPiBridgeDataType`, which carries `ibridge_secure_boot`
/// (Full / Reduced-Medium / Permissive-No Security). On the provider's minimum
/// OS — macOS 26 (Tahoe) — this array is reliably populated and authoritative on
/// BOTH Apple Silicon (verified on M4 Max / Mac16,5 / arm64) AND Intel T2. When
/// it is empty/absent the posture is `.unavailable` (a WARN, never a downgrade).
///
/// Nothing here depends on the host's actual macOS / SIP / Secure Boot state.
@Suite("boot security gate")
struct BootSecurityTests {

    // MARK: - Fixtures

    private func ok(_ stdout: String) -> SecurityCommandResult {
        SecurityCommandResult(terminationStatus: 0, stdout: stdout)
    }

    /// A populated `system_profiler -json SPiBridgeDataType` document reporting
    /// the given `ibridge_secure_boot` level. This array is populated on BOTH
    /// Intel T2 AND Apple Silicon (Tahoe), so this minimal shape stands in for
    /// either platform's report.
    private func spiBridge(_ secureBoot: String) -> String {
        """
        {
          "SPiBridgeDataType" : [
            {
              "ibridge_sb_sip" : "Enabled",
              "ibridge_sb_ssv" : "Enabled",
              "ibridge_secure_boot" : "\(secureBoot)"
            }
          ]
        }
        """
    }

    /// An EMPTY `system_profiler -json SPiBridgeDataType` array. This is
    /// anomalous on Tahoe (the minimum supported OS); detection maps it to
    /// `.unavailable` (warn), never a false downgrade.
    private let emptyBridge = #"{ "SPiBridgeDataType" : [ ] }"#

    /// The EXACT real `system_profiler -json SPiBridgeDataType` captured on Apple
    /// Silicon (M4 Max / Mac16,5 / arm64, macOS darwin 25.5.0). The array is
    /// POPULATED, with `ibridge_secure_boot == "Full Security"` — direct proof
    /// that this data type is NOT Intel-T2-only and NOT empty on Apple Silicon.
    /// Detection must parse this as `.fullSecurity`.
    private let realAppleSiliconBridgeJSON = """
    {
      "SPiBridgeDataType" : [
        {
          "ibridge_boot_uuid" : "A904AC62-589E-450B-8829-96ADA16DE3DC",
          "ibridge_build" : "mBoot-18000.120.36",
          "ibridge_extra_boot_policies" : " ",
          "ibridge_model_identifier_top" : "Mac16,5",
          "ibridge_sb_boot_args" : "Enabled",
          "ibridge_sb_ctrr" : "Enabled",
          "ibridge_sb_device_mdm" : "Yes",
          "ibridge_sb_manual_mdm" : "No",
          "ibridge_sb_other_kext" : "No",
          "ibridge_sb_sip" : "Enabled",
          "ibridge_sb_ssv" : "Enabled",
          "ibridge_secure_boot" : "Full Security"
        }
      ]
    }
    """

    /// The EXACT real plain-text `system_profiler SPiBridgeDataType` captured on
    /// the same Apple Silicon machine — the text form the parser must also accept
    /// (when the JSON document is unavailable).
    private let realAppleSiliconBridgeText = """
    Controller:
          Model Identifier: Mac16,5
          Firmware Version: mBoot-18000.120.36
          Boot UUID: A904AC62-589E-450B-8829-96ADA16DE3DC
          Boot Policy:
            Secure Boot: Full Security
            System Integrity Protection: Enabled
            Signed System Volume: Enabled
            Kernel CTRR: Enabled
            Boot Arguments Filtering: Enabled
            Allow All Kernel Extensions: No
            User Approved Privileged MDM Operations: No
            DEP Approved Privileged MDM Operations: Yes
    """

    /// A runner that serves the `system_profiler SPiBridgeDataType` probe — the
    /// only command the Secure Boot checker runs. Any other probe returns a
    /// non-zero "unexpected" result so a test fails loudly if detection calls a
    /// command it didn't stub.
    private func runner(systemProfiler: SecurityCommandResult) -> SecurityCommandRunner {
        SecurityCommandRunner { path, args in
            switch (path, args) {
            case ("/usr/sbin/system_profiler", ["-json", "SPiBridgeDataType"]):
                return systemProfiler
            default:
                return SecurityCommandResult(terminationStatus: 127, stderr: "unexpected probe: \(path) \(args)")
            }
        }
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var idx = haystack.startIndex
        while let found = haystack.range(of: needle, range: idx..<haystack.endIndex) {
            count += 1
            idx = found.upperBound
        }
        return count
    }

    // MARK: - SPiBridge path (populated SPiBridgeDataType → ibridge_secure_boot)

    @Test("SPiBridge: ibridge_secure_boot maps every level through the checker")
    func spiBridgeLevels() {
        func status(_ level: String) -> SecureBootStatus {
            SecureBootStatusChecker(runner: runner(systemProfiler: ok(spiBridge(level)))).status()
        }
        #expect(status("Full Security") == .fullSecurity)
        #expect(status("Medium Security") == .reduced)
        #expect(status("No Security") == .permissiveOrDisabled)
        // Intel T2 uses "Medium"/"No Security"; Apple Silicon uses
        // "Reduced"/"Permissive Security" — classify maps both vocabularies, so
        // the same SPiBridge path covers either platform's reported level.
        #expect(status("Reduced Security") == .reduced)
        #expect(status("Permissive Security") == .permissiveOrDisabled)
    }

    @Test("Apple Silicon: the REAL populated SPiBridge JSON → .fullSecurity (NOT empty/nil)")
    func appleSiliconFullSecurityViaSPiBridgeJSON() {
        // The exact JSON captured on M4 Max / Mac16,5 / arm64. A populated
        // SPiBridgeDataType on Apple Silicon MUST parse as Full Security.
        let checker = SecureBootStatusChecker(
            runner: runner(systemProfiler: ok(realAppleSiliconBridgeJSON)))
        #expect(checker.status() == .fullSecurity)
        #expect(checker.isFullSecurity())
        #expect(BootSecurityPolicy.secureBootVerdict(checker.status()) == .pass)
        #expect(checker.status().attestsSecureBoot)
        // The pure parser agrees on both the JSON and the plain-text shapes.
        #expect(SecureBootStatusParser.spiBridgeStatus(realAppleSiliconBridgeJSON) == .fullSecurity)
        #expect(SecureBootStatusParser.spiBridgeStatus(realAppleSiliconBridgeText) == .fullSecurity)
    }

    @Test("Apple Silicon: the REAL plain-text SPiBridge report → .fullSecurity")
    func appleSiliconFullSecurityViaSPiBridgeText() {
        let checker = SecureBootStatusChecker(
            runner: runner(systemProfiler: ok(realAppleSiliconBridgeText)))
        #expect(checker.status() == .fullSecurity)
        #expect(checker.isFullSecurity())
        #expect(BootSecurityPolicy.secureBootVerdict(checker.status()) == .pass)
    }

    @Test("Intel T2: verdict mapping — Full passes, Medium/No fail")
    func intelT2Verdicts() {
        func verdict(_ level: String) -> BootSecurityVerdict {
            BootSecurityPolicy.secureBootVerdict(
                SecureBootStatusChecker(runner: runner(systemProfiler: ok(spiBridge(level)))).status())
        }
        #expect(verdict("Full Security") == .pass)
        #expect(verdict("Medium Security") == .fail)
        #expect(verdict("No Security") == .fail)
    }

    @Test("SPiBridge: a localized level is unavailable (warn), never a false downgrade")
    func spiBridgeLocalizedLevelWarns() {
        // system_profiler localizes ibridge_secure_boot on non-English Macs; an
        // unrecognized value must WARN, not be misread as a downgrade.
        let status = SecureBootStatusChecker(
            runner: runner(systemProfiler: ok(spiBridge("Vollständige Sicherheit")))
        ).status()
        if case .unavailable = status {
            // expected — must NOT be classified as a downgrade
        } else {
            Issue.record("expected .unavailable for a localized boot security level")
        }
        #expect(BootSecurityPolicy.secureBootVerdict(status) == .warn)
        #expect(!status.isConfidentlyNotFullSecurity)
    }

    @Test("empty SPiBridge array → unavailable (WARN only, no lockout)")
    func emptySPiBridgeWarns() {
        // Anomalous on Tahoe, but if the array is empty we warn rather than block.
        let status = SecureBootStatusChecker(runner: runner(systemProfiler: ok(emptyBridge))).status()
        if case .unavailable = status {
            // expected
        } else {
            Issue.record("expected .unavailable for an empty SPiBridgeDataType array")
        }
        #expect(BootSecurityPolicy.secureBootVerdict(status) == .warn)
        #expect(!status.attestsSecureBoot)
    }

    @Test("system_profiler failure → unavailable, never a false pass/fail")
    func commandFailureUnavailable() {
        let status = SecureBootStatusChecker(runner: runner(
            systemProfiler: SecurityCommandResult(terminationStatus: 1, stderr: "system_profiler: boom"))
        ).status()
        if case .unavailable = status {
            // expected
        } else {
            Issue.record("expected .unavailable when system_profiler fails")
        }
        #expect(BootSecurityPolicy.secureBootVerdict(status) == .warn)
    }

    @Test("a throwing runner resolves to unavailable, never a false pass/fail")
    func throwingRunnerUnavailable() {
        struct Boom: Error {}
        let checker = SecureBootStatusChecker(runner: SecurityCommandRunner { _, _ in throw Boom() })
        if case .unavailable = checker.status() {
            // expected
        } else {
            Issue.record("expected .unavailable when the probe throws")
        }
        #expect(!checker.isFullSecurity())
    }

    // MARK: - Pure parser (SPiBridgeDataType: Apple Silicon AND Intel T2)

    @Test("parser spiBridgeStatus classifies a populated report and returns nil for an empty array")
    func parserSPiBridgeStatus() {
        #expect(SecureBootStatusParser.spiBridgeStatus(spiBridge("Full Security")) == .fullSecurity)
        #expect(SecureBootStatusParser.spiBridgeStatus(spiBridge("Medium Security")) == .reduced)
        #expect(SecureBootStatusParser.spiBridgeStatus(spiBridge("No Security")) == .permissiveOrDisabled)
        // An empty array → nil → the caller maps it to .unavailable (warn).
        #expect(SecureBootStatusParser.spiBridgeStatus(emptyBridge) == nil)
        #expect(SecureBootStatusParser.spiBridgeStatus("") == nil)
    }

    @Test("parser spiBridgeStatus parses the plain-text 'Secure Boot:' report when JSON is absent")
    func parserSPiBridgeText() {
        let text = """
        Controller:

              Boot Policy:
                Secure Boot: Full Security
                System Integrity Protection: Enabled
        """
        #expect(SecureBootStatusParser.spiBridgeStatus(text) == .fullSecurity)
        #expect(SecureBootStatusParser.spiBridgeStatus("      Secure Boot: Reduced Security\n") == .reduced)
    }

    @Test("parser spiBridgeStatus(result): a non-zero termination is not a usable report")
    func parserSPiBridgeCommandFailure() {
        #expect(SecureBootStatusParser.spiBridgeStatus(
            SecurityCommandResult(terminationStatus: 1, stdout: "", stderr: "system_profiler: boom")) == nil)
    }

    @Test("classify is whitespace- and case-insensitive")
    func classifyNormalizes() {
        #expect(SecureBootStatusParser.classify(level: "  full security ") == .fullSecurity)
        #expect(SecureBootStatusParser.classify(level: "FULLSECURITY") == .fullSecurity)
    }

    // MARK: - Status semantics

    @Test("attestsSecureBoot is the single source for gate-pass AND the attested bool")
    func attestsSecureBootMapping() {
        #expect(SecureBootStatus.fullSecurity.attestsSecureBoot)
        #expect(!SecureBootStatus.reduced.attestsSecureBoot)
        #expect(!SecureBootStatus.permissiveOrDisabled.attestsSecureBoot)
        #expect(!SecureBootStatus.unavailable(reason: "x").attestsSecureBoot)
    }

    @Test("isConfidentlyNotFullSecurity only fires on real downgrades")
    func confidenceFlag() {
        #expect(SecureBootStatus.reduced.isConfidentlyNotFullSecurity)
        #expect(SecureBootStatus.permissiveOrDisabled.isConfidentlyNotFullSecurity)
        #expect(!SecureBootStatus.fullSecurity.isConfidentlyNotFullSecurity)
        #expect(!SecureBootStatus.unavailable(reason: "x").isConfidentlyNotFullSecurity)
    }

    /// Pins the deliberate gate↔attestation split for an undeterminable posture:
    /// `start` proceeds locally (verdict `.warn`, no false lockout) but the
    /// attested `secure_boot_enabled` is false, so the coordinator still rejects.
    /// The WARNING text must say so, or operators are surprised by a rejection
    /// after a "successful" local start.
    @Test("unavailable warns locally (start proceeds) but does NOT attest Secure Boot (coordinator rejects)")
    func unavailableWarnsLocallyButDoesNotAttestSecureBoot() {
        let status = SecureBootStatus.unavailable(reason: "no ibridge_secure_boot level")

        // Local gate: warn → start proceeds (never a false lockout)…
        #expect(BootSecurityPolicy.secureBootVerdict(status) == .warn)
        // …but the attested boolean is false, so the coordinator stays untrusting.
        #expect(!status.attestsSecureBoot)

        // The same split holds through the attestation-feeding entry point: an
        // unreadable runner (every probe fails → unavailable) attests false.
        let unreadable = SecurityCommandRunner { _, _ in
            SecurityCommandResult(terminationStatus: 1, stderr: "unreadable")
        }
        #expect(!checkSecureBootEnabled(runner: unreadable))

        // The WARNING text tells the operator that proceeding locally is not
        // admission — the coordinator still requires confirmed Secure Boot.
        let warning = status.summary
        #expect(warning.contains("coordinator"))
        #expect(warning.contains("does not guarantee admission"))
    }

    // MARK: - Verdict mapping

    @Test("macOS verdict: Tahoe+ passes, anything below fails")
    func macOSVerdicts() {
        #expect(BootSecurityPolicy.macOSVerdict(26) == .pass)
        #expect(BootSecurityPolicy.macOSVerdict(27) == .pass)
        #expect(BootSecurityPolicy.macOSVerdict(25) == .fail)
        #expect(BootSecurityPolicy.macOSVerdict(15) == .fail)
        #expect(BootSecurityPolicy.minimumMacOSMajorVersion == 26)
    }

    @Test("macOS summary names the version and the Tahoe floor")
    func macOSSummaries() {
        let below = BootSecurityPolicy.macOSSummary(majorVersion: 25)
        #expect(below.contains("25"))
        #expect(below.contains("26"))
        #expect(below.contains("Tahoe"))
        let ok = BootSecurityPolicy.macOSSummary(majorVersion: 26)
        #expect(ok.contains("26"))
    }

    @Test("SIP verdict: only full passes; custom-config is a failure")
    func sipVerdicts() {
        #expect(BootSecurityPolicy.sipVerdict(.enabled) == .pass)
        #expect(BootSecurityPolicy.sipVerdict(.disabled) == .fail)
        #expect(BootSecurityPolicy.sipVerdict(
            .enabledWithCustomConfiguration(disabledProtections: ["Kext Signing"])) == .fail)
        #expect(BootSecurityPolicy.sipVerdict(.unavailable(reason: "x")) == .warn)
        #expect(BootSecurityPolicy.sipVerdict(.unrecognized(output: "?")) == .warn)
    }

    @Test("Secure Boot verdict: Full Security passes, downgrades fail, unknown warns")
    func secureBootVerdicts() {
        #expect(BootSecurityPolicy.secureBootVerdict(.fullSecurity) == .pass)
        #expect(BootSecurityPolicy.secureBootVerdict(.reduced) == .fail)
        #expect(BootSecurityPolicy.secureBootVerdict(.permissiveOrDisabled) == .fail)
        #expect(BootSecurityPolicy.secureBootVerdict(.unavailable(reason: "x")) == .warn)
    }

    // MARK: - SIP "custom configuration" summary

    @Test("SIP custom configuration is summarized as NOT fully enabled")
    func sipCustomConfigSummary() {
        let summary = SIPStatus.enabledWithCustomConfiguration(
            disabledProtections: ["Kext Signing", "Debugging Restrictions"]).summary
        #expect(summary.contains("NOT fully enabled"))
        #expect(summary.contains("Kext Signing"))
    }

    // MARK: - Preflight decision

    @Test("all protections fully on → no block, nothing to print")
    func preflightAllPass() {
        let decision = BootSecurityPolicy.preflightDecision(
            macOSMajorVersion: 26, sip: .enabled, secureBoot: .fullSecurity, allowInsecureOverride: false)
        #expect(decision == .ok)
        #expect(!decision.shouldBlock)
        #expect(decision.messageLines.isEmpty)
    }

    @Test("macOS below the Tahoe floor blocks and prints the upgrade guide")
    func preflightBelowMacOSFloorBlocks() {
        let decision = BootSecurityPolicy.preflightDecision(
            macOSMajorVersion: 25, sip: .enabled, secureBoot: .fullSecurity, allowInsecureOverride: false)
        #expect(decision.shouldBlock)
        let text = decision.messageLines.joined(separator: "\n")
        #expect(text.contains("Software Update"))
        #expect(text.contains("Tahoe"))
        // SIP and Secure Boot are fine here, so their sections are omitted.
        #expect(!text.contains("csrutil enable"))
        #expect(!text.contains("Startup Security Utility"))
    }

    @Test("escape hatch downgrades a below-floor macOS failure to a loud warning")
    func preflightMacOSOverrideDowngrades() {
        let decision = BootSecurityPolicy.preflightDecision(
            macOSMajorVersion: 25, sip: .enabled, secureBoot: .fullSecurity, allowInsecureOverride: true)
        #expect(!decision.shouldBlock)
        #expect(decision.overrodeBlock)
        let text = decision.messageLines.joined(separator: "\n")
        #expect(text.contains(BootSecurityPolicy.overrideEnvVar))
        #expect(text.contains("development only"))
    }

    @Test("SIP disabled blocks and prints the enable guide")
    func preflightSIPDisabledBlocks() {
        let decision = BootSecurityPolicy.preflightDecision(
            macOSMajorVersion: 26, sip: .disabled, secureBoot: .fullSecurity, allowInsecureOverride: false)
        #expect(decision.shouldBlock)
        let text = decision.messageLines.joined(separator: "\n")
        #expect(text.contains("csrutil enable"))
        #expect(text.contains("System Integrity Protection"))
        // Secure Boot and macOS are fine here, so those sections are omitted.
        #expect(!text.contains("Startup Security Utility"))
        #expect(!text.contains("Software Update"))
    }

    @Test("SIP custom configuration blocks (treated as not fully enabled)")
    func preflightSIPCustomBlocks() {
        let decision = BootSecurityPolicy.preflightDecision(
            macOSMajorVersion: 26,
            sip: .enabledWithCustomConfiguration(disabledProtections: ["Kext Signing"]),
            secureBoot: .fullSecurity,
            allowInsecureOverride: false)
        #expect(decision.shouldBlock)
        #expect(decision.messageLines.joined(separator: "\n").contains("NOT fully enabled"))
    }

    @Test("Secure Boot downgrade (permissiveOrDisabled) blocks and prints the Full Security guide")
    func preflightSecureBootDowngradeBlocks() {
        let decision = BootSecurityPolicy.preflightDecision(
            macOSMajorVersion: 26, sip: .enabled, secureBoot: .permissiveOrDisabled, allowInsecureOverride: false)
        #expect(decision.shouldBlock)
        let text = decision.messageLines.joined(separator: "\n")
        #expect(text.contains("Startup Security Utility"))
        #expect(text.contains("Full Security"))
        #expect(!text.contains("csrutil enable"))
    }

    @Test("undeterminable Secure Boot warns but does not block")
    func preflightUnavailableWarnsOnly() {
        let decision = BootSecurityPolicy.preflightDecision(
            macOSMajorVersion: 26, sip: .enabled, secureBoot: .unavailable(reason: "no level"),
            allowInsecureOverride: false)
        #expect(!decision.shouldBlock)
        #expect(!decision.overrodeBlock)
        #expect(!decision.messageLines.isEmpty)
        #expect(decision.messageLines.joined(separator: "\n").contains("WARNING"))
    }

    @Test("escape hatch downgrades a hard failure to a loud warning")
    func preflightOverrideDowngradesFailure() {
        let decision = BootSecurityPolicy.preflightDecision(
            macOSMajorVersion: 26, sip: .disabled, secureBoot: .reduced, allowInsecureOverride: true)
        #expect(!decision.shouldBlock)
        #expect(decision.overrodeBlock)
        let text = decision.messageLines.joined(separator: "\n")
        #expect(text.contains(BootSecurityPolicy.overrideEnvVar))
        #expect(text.contains("development only"))
    }

    // MARK: - Shared guidance content (single combined entry point)

    @Test("combined guide (macOS only) names Software Update and Tahoe")
    func macOSGuideContent() {
        let guide = BootSecurityGuidance.guide(includeMacOS: true, includeSIP: false, includeSecureBoot: false)
        #expect(guide.contains("Software Update"))
        #expect(guide.contains("Tahoe"))
        #expect(!guide.contains("csrutil enable"))
        #expect(!guide.contains("Startup Security Utility"))
    }

    @Test("combined guide (SIP only) contains the actionable csrutil command")
    func sipGuideContent() {
        let guide = BootSecurityGuidance.guide(includeMacOS: false, includeSIP: true, includeSecureBoot: false)
        #expect(guide.contains("csrutil enable"))
        #expect(guide.contains("Apple Silicon"))
        #expect(guide.contains("Intel"))
        #expect(!guide.contains("Startup Security Utility"))
        #expect(!guide.contains("Software Update"))
    }

    @Test("combined guide (Secure Boot only) names Startup Security Utility and Full Security")
    func secureBootGuideContent() {
        let guide = BootSecurityGuidance.guide(includeMacOS: false, includeSIP: false, includeSecureBoot: true)
        #expect(guide.contains("Startup Security Utility"))
        #expect(guide.contains("Full Security"))
        #expect(!guide.contains("csrutil enable"))
        // Boot-args remediation was removed (ibridge_secure_boot already reflects it).
        #expect(!guide.contains("boot-args"))
    }

    @Test("combined guide includes only requested sections with exactly one shared footer")
    func combinedGuideSectioning() {
        let all = BootSecurityGuidance.guide(includeMacOS: true, includeSIP: true, includeSecureBoot: true)
        #expect(all.contains("Software Update"))
        #expect(all.contains("csrutil enable"))
        #expect(all.contains("Startup Security Utility"))
        #expect(all.contains("Full Security"))
        // Dedup: the verification footer must appear exactly once even when all
        // sections are present (no doubled footer).
        #expect(occurrences(of: "re-run 'darkbloom doctor'", in: all) == 1)

        let sbOnly = BootSecurityGuidance.guide(includeMacOS: false, includeSIP: false, includeSecureBoot: true)
        #expect(!sbOnly.contains("csrutil enable"))
        #expect(sbOnly.contains("Startup Security Utility"))
    }
}
