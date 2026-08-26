import Foundation
import ProviderCore
import Testing
@testable import darkbloom

@Suite("doctor checks (pure)")
struct DoctorChecksTests {
    private let hardware = HardwareInfo(
        machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
        memoryGb: 128, memoryAvailableGb: 124,
        cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
        gpuCores: 40, memoryBandwidthGbs: 546
    )

    private func checks(
        hardware: HardwareInfo? = nil,
        configFileExists: Bool = true,
        models: [ModelInfo] = [],
        bootSecurity: BootSecuritySnapshot = .init(macOSMajorVersion: 26, sip: .enabled)
    ) -> [DoctorCheck] {
        buildDoctorChecks(
            snapshot: RuntimeSnapshot(
                configPath: URL(fileURLWithPath: "/tmp/darkbloom-doctor-test.json"),
                configFileExists: configFileExists,
                config: ProviderConfig(
                    provider: ProviderSettings(name: "doctor-unit-test", memoryReserveGB: 1),
                    backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 1),
                    coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)
                ),
                hardware: hardware,
                hardwareError: nil,
                models: models
            ),
            bootSecurity: bootSecurity
        )
    }

    private func check(_ checks: [DoctorCheck], _ name: String) -> DoctorCheck? {
        checks.first { $0.name == name }
    }

    @Test("check backbone includes local posture but leaves Secure Boot to MDM")
    func stableBackbone() {
        #expect(checks(hardware: hardware).map(\.name) == [
            "hardware", "metal gpu", "config", "install location", "huggingface cache",
            "local mlx models", "macos", "sip", "rdma", "authenticated root",
            "hardened runtime", "debugger", "binary hash",
        ])
    }

    /// A provider running from its live layout must not be told it is
    /// stranded; the test binary itself is the live case. The transient case
    /// is pinned in `InstallLocationTests` against synthetic paths, because
    /// the check reads the RUNNING executable and a test cannot move itself.
    @Test("install location passes for a normally-installed binary")
    func installLocationCheck() {
        let check = check(checks(hardware: hardware), "install location")
        #expect(check?.status == .pass)
        #expect(check?.detail == "live install layout")
    }

    @Test("snapshot checks retain their existing status mapping")
    func snapshotChecks() {
        let present = checks(hardware: hardware)
        #expect(check(present, "hardware")?.detail == "Apple M4 Max, 128 GB RAM, 40 GPU cores")
        #expect(check(present, "config")?.status == .pass)
        #expect(check(present, "local mlx models")?.status == .warn)

        let missing = checks(configFileExists: false)
        #expect(check(missing, "hardware")?.status == .fail)
        #expect(check(missing, "config")?.status == .warn)
    }

    @Test("macOS and SIP warnings share the compact action guide")
    func bootSecurityWarnings() {
        let posture = BootSecuritySnapshot(macOSMajorVersion: 25, sip: .disabled)
        let result = checks(hardware: hardware, bootSecurity: posture)
        #expect(check(result, "macos")?.status == .warn)
        #expect(check(result, "sip")?.status == .warn)

        let guide = bootSecurityActionGuide(posture)
        #expect(guide?.contains("Software Update") == true)
        #expect(guide?.contains("csrutil enable") == true)
        #expect(bootSecurityActionGuide(.init(macOSMajorVersion: 26, sip: .enabled)) == nil)
    }

    @Test("describeMDMEnrollment maps every state")
    func mdmDescriptions() {
        #expect(describeMDMEnrollment(.enrolledDarkbloom(serverURL: "https://mdm.example")) == "yes (darkbloom)")
        #expect(describeMDMEnrollment(.enrolledOtherMDM(serverURL: "https://other.example"))
            == "other MDM (https://other.example)")
        #expect(describeMDMEnrollment(.notEnrolled) == "no")
        #expect(describeMDMEnrollment(.checkFailed) == "unknown (profiles tool failed)")
    }

    @Test("CheckStatus markers and boot verdict mapping are stable")
    func statusMarkers() {
        #expect(CheckStatus.pass.marker == "[PASS]")
        #expect(CheckStatus.warn.marker == "[WARN]")
        #expect(CheckStatus.fail.marker == "[FAIL]")
        #expect(CheckStatus(.pass) == .pass)
        #expect(CheckStatus(.warn) == .warn)
    }
}
