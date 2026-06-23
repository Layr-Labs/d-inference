import Testing
import Foundation
import ProviderCore

@testable import darkbloom

/// Unit tests for the pure `doctor` building blocks: `buildDoctorChecks` (the
/// snapshot-driven local readiness checks), `describeMDMEnrollment`, and the
/// `CheckStatus` markers. The boot-security inputs (SIP + Secure Boot) are
/// injected via `BootSecuritySnapshot`, so the suite is independent of the
/// host's Metal/SIP/Secure-Boot/codesign state.
@Suite("doctor checks (pure)")
struct DoctorChecksTests {

    private func snapshot(
        hardware: HardwareInfo?,
        hardwareError: Error? = nil,
        configFileExists: Bool,
        models: [ModelInfo] = []
    ) -> RuntimeSnapshot {
        RuntimeSnapshot(
            configPath: URL(fileURLWithPath: "/tmp/darkbloom-doctor-test.json"),
            configFileExists: configFileExists,
            config: ProviderConfig(
                provider: ProviderSettings(name: "doctor-unit-test", memoryReserveGB: 1),
                backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 1),
                coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)
            ),
            hardware: hardware,
            hardwareError: hardwareError,
            models: models
        )
    }

    private let sampleHardware = HardwareInfo(
        machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
        memoryGb: 128, memoryAvailableGb: 124,
        cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
        gpuCores: 40, memoryBandwidthGbs: 546
    )

    /// Deterministic "everything is fully on" boot-security input so the
    /// host-independent checks below never spawn `csrutil` / `system_profiler`.
    private let fullSecurity = BootSecuritySnapshot(sip: .enabled, secureBoot: .fullSecurity)

    private func check(_ checks: [DoctorCheck], _ name: String) -> DoctorCheck? {
        checks.first { $0.name == name }
    }

    // MARK: - check backbone (deterministic regardless of host state)

    @Test("buildDoctorChecks always emits the same ordered check backbone")
    func stableBackbone() {
        let checks = buildDoctorChecks(
            snapshot: snapshot(hardware: sampleHardware, configFileExists: true),
            bootSecurity: fullSecurity)
        #expect(checks.map(\.name) == [
            "hardware", "metal gpu", "config", "huggingface cache", "local mlx models",
            "macos", "sip", "rdma", "secure boot", "authenticated root", "hardened runtime",
            "debugger", "binary hash",
        ])
    }

    // MARK: - hardware check (snapshot-driven)

    @Test("hardware present -> pass with chip/memory/gpu detail")
    func hardwarePresent() {
        let checks = buildDoctorChecks(
            snapshot: snapshot(hardware: sampleHardware, configFileExists: true),
            bootSecurity: fullSecurity)
        let hw = check(checks, "hardware")
        #expect(hw?.status == .pass)
        #expect(hw?.detail == "Apple M4 Max, 128 GB RAM, 40 GPU cores")
    }

    @Test("hardware nil -> fail with default detail when no error is attached")
    func hardwareMissing() {
        let checks = buildDoctorChecks(
            snapshot: snapshot(hardware: nil, configFileExists: true),
            bootSecurity: fullSecurity)
        let hw = check(checks, "hardware")
        #expect(hw?.status == .fail)
        #expect(hw?.detail == "hardware detection failed")
    }

    // MARK: - config check (snapshot-driven)

    @Test("config file presence drives pass/warn")
    func configStatus() {
        let present = buildDoctorChecks(
            snapshot: snapshot(hardware: sampleHardware, configFileExists: true),
            bootSecurity: fullSecurity)
        #expect(check(present, "config")?.status == .pass)
        #expect(check(present, "config")?.detail == "loaded")

        let missing = buildDoctorChecks(
            snapshot: snapshot(hardware: sampleHardware, configFileExists: false),
            bootSecurity: fullSecurity)
        #expect(check(missing, "config")?.status == .warn)
        #expect(check(missing, "config")?.detail == "missing, defaults are in memory only")
    }

    // MARK: - local model count check (snapshot-driven)

    @Test("empty model set -> warn '0 discovered'")
    func noModelsWarns() {
        let checks = buildDoctorChecks(
            snapshot: snapshot(hardware: sampleHardware, configFileExists: true, models: []),
            bootSecurity: fullSecurity)
        let models = check(checks, "local mlx models")
        #expect(models?.status == .warn)
        #expect(models?.detail == "0 discovered")
    }

    // MARK: - SIP check (injected boot-security snapshot)

    private func sipCheck(_ sip: SIPStatus) -> DoctorCheck? {
        check(
            buildDoctorChecks(
                snapshot: snapshot(hardware: sampleHardware, configFileExists: true),
                bootSecurity: BootSecuritySnapshot(sip: sip, secureBoot: .fullSecurity)),
            "sip")
    }

    @Test("SIP fully enabled -> PASS")
    func sipEnabledPasses() {
        let c = sipCheck(.enabled)
        #expect(c?.status == .pass)
        #expect(c?.detail == "enabled (full protection)")
    }

    @Test("SIP disabled -> FAIL")
    func sipDisabledFails() {
        let c = sipCheck(.disabled)
        #expect(c?.status == .fail)
        #expect(c?.detail == "disabled")
    }

    @Test("SIP custom configuration -> FAIL, treated as not fully enabled")
    func sipCustomConfigFails() {
        let c = sipCheck(.enabledWithCustomConfiguration(disabledProtections: ["Kext Signing"]))
        #expect(c?.status == .fail)
        #expect(c?.detail.contains("NOT fully enabled") == true)
    }

    @Test("SIP undeterminable -> WARN (not a hard failure)")
    func sipUnavailableWarns() {
        let c = sipCheck(.unavailable(reason: "csrutil missing"))
        #expect(c?.status == .warn)
    }

    // MARK: - macOS version check (injected boot-security snapshot)

    private func macOSCheck(_ majorVersion: Int) -> DoctorCheck? {
        check(
            buildDoctorChecks(
                snapshot: snapshot(hardware: sampleHardware, configFileExists: true),
                bootSecurity: BootSecuritySnapshot(
                    macOSMajorVersion: majorVersion, sip: .enabled, secureBoot: .fullSecurity)),
            "macos")
    }

    @Test("macOS 26 (Tahoe) -> PASS")
    func macOSTahoePasses() {
        let c = macOSCheck(26)
        #expect(c?.status == .pass)
        #expect(c?.detail.contains("26") == true)
    }

    @Test("macOS 25 (Sequoia) -> FAIL with the Tahoe upgrade hint")
    func macOSBelowFloorFails() {
        let c = macOSCheck(25)
        #expect(c?.status == .fail)
        #expect(c?.detail.contains("Tahoe") == true)
    }

    // MARK: - Secure Boot check (injected boot-security snapshot)

    private func secureBootCheck(_ status: SecureBootStatus) -> DoctorCheck? {
        check(
            buildDoctorChecks(
                snapshot: snapshot(hardware: sampleHardware, configFileExists: true),
                bootSecurity: BootSecuritySnapshot(sip: .enabled, secureBoot: status)),
            "secure boot")
    }

    @Test("Secure Boot Full Security (SPiBridge: Apple Silicon or Intel T2) -> PASS")
    func secureBootFullPasses() {
        let c = secureBootCheck(.fullSecurity)
        #expect(c?.status == .pass)
        #expect(c?.detail == "Full Security")
    }

    @Test("Secure Boot Reduced (SPiBridge reports Reduced/Medium) -> FAIL")
    func secureBootReducedFails() {
        let c = secureBootCheck(.reduced)
        #expect(c?.status == .fail)
        // The detail names the authoritative field it came from, not a platform.
        #expect(c?.detail.contains("ibridge_secure_boot") == true)
        #expect(c?.detail.contains("Reduced/Medium") == true)
    }

    @Test("Secure Boot Permissive / No Security -> FAIL")
    func secureBootPermissiveFails() {
        let c = secureBootCheck(.permissiveOrDisabled)
        #expect(c?.status == .fail)
    }

    @Test("Secure Boot undeterminable -> WARN (not a hard failure)")
    func secureBootUnavailableWarns() {
        let c = secureBootCheck(.unavailable(reason: "no controller"))
        #expect(c?.status == .warn)
    }

    // MARK: - Combined, deduped boot-security guide (bootSecurityActionGuide)

    @Test("all protections pass -> no action guide")
    func actionGuideNilWhenAllPass() {
        let guide = bootSecurityActionGuide(BootSecuritySnapshot(sip: .enabled, secureBoot: .fullSecurity))
        #expect(guide == nil)
    }

    @Test("macOS-only failure -> guide has the Software Update section only")
    func actionGuideMacOSOnly() {
        let guide = bootSecurityActionGuide(
            BootSecuritySnapshot(macOSMajorVersion: 25, sip: .enabled, secureBoot: .fullSecurity))
        #expect(guide?.contains("Software Update") == true)
        #expect(guide?.contains("csrutil enable") == false)
        #expect(guide?.contains("Startup Security Utility") == false)
    }

    @Test("SIP-only failure -> guide has the csrutil section, not Secure Boot")
    func actionGuideSIPOnly() {
        let guide = bootSecurityActionGuide(BootSecuritySnapshot(sip: .disabled, secureBoot: .fullSecurity))
        #expect(guide?.contains("csrutil enable") == true)
        #expect(guide?.contains("Startup Security Utility") == false)
    }

    @Test("Secure-Boot-only failure -> guide has Startup Security Utility, not csrutil")
    func actionGuideSecureBootOnly() {
        let guide = bootSecurityActionGuide(
            BootSecuritySnapshot(sip: .enabled, secureBoot: .permissiveOrDisabled))
        #expect(guide?.contains("Startup Security Utility") == true)
        #expect(guide?.contains("csrutil enable") == false)
    }

    @Test("all fail -> ONE combined guide with a single shared footer (dedup)")
    func actionGuideAllFailDeduped() {
        let guide = bootSecurityActionGuide(
            BootSecuritySnapshot(macOSMajorVersion: 25, sip: .disabled, secureBoot: .reduced))
        #expect(guide?.contains("Software Update") == true)
        #expect(guide?.contains("csrutil enable") == true)
        #expect(guide?.contains("Startup Security Utility") == true)
        // The verification footer must appear exactly ONCE, not once per section.
        let footer = "re-run 'darkbloom doctor'"
        let count = (guide ?? "").components(separatedBy: footer).count - 1
        #expect(count == 1)
    }

    // MARK: - describeMDMEnrollment (pure mapping)

    @Test("describeMDMEnrollment maps every state")
    func mdmDescriptions() {
        #expect(describeMDMEnrollment(.enrolledDarkbloom(serverURL: "https://mdm.example")) == "yes (darkbloom)")
        #expect(describeMDMEnrollment(.enrolledOtherMDM(serverURL: "https://other.example"))
            == "other MDM (https://other.example)")
        #expect(describeMDMEnrollment(.notEnrolled) == "no")
        #expect(describeMDMEnrollment(.checkFailed) == "unknown (profiles tool failed)")
    }

    // MARK: - CheckStatus markers

    @Test("CheckStatus markers are stable")
    func statusMarkers() {
        #expect(CheckStatus.pass.marker == "[PASS]")
        #expect(CheckStatus.warn.marker == "[WARN]")
        #expect(CheckStatus.fail.marker == "[FAIL]")
    }

    @Test("CheckStatus maps from boot-security verdicts")
    func statusFromVerdict() {
        #expect(CheckStatus(.pass) == .pass)
        #expect(CheckStatus(.warn) == .warn)
        #expect(CheckStatus(.fail) == .fail)
    }
}
