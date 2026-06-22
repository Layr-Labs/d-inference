import Testing
import Foundation
import ProviderCore

@testable import darkbloom

/// Unit tests for the pure `doctor` building blocks: `buildDoctorChecks` (the
/// snapshot-driven local readiness checks), `describeMDMEnrollment`, and the
/// `CheckStatus` markers. Only the snapshot-DRIVEN checks (hardware/config/
/// model count) and the deterministic check backbone are asserted, so the suite
/// is independent of the host's Metal/SIP/codesign state.
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
                backend: BackendSettings(continuousBatching: true, idleTimeoutMins: 0, maxModelSlots: 1),
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

    private func check(_ checks: [DoctorCheck], _ name: String) -> DoctorCheck? {
        checks.first { $0.name == name }
    }

    // MARK: - check backbone (deterministic regardless of host state)

    @Test("buildDoctorChecks always emits the same ordered check backbone")
    func stableBackbone() {
        let checks = buildDoctorChecks(snapshot: snapshot(hardware: sampleHardware, configFileExists: true))
        #expect(checks.map(\.name) == [
            "hardware", "metal gpu", "config", "huggingface cache", "local mlx models",
            "sip", "rdma", "secure boot", "authenticated root", "hardened runtime",
            "debugger", "binary hash",
        ])
    }

    // MARK: - hardware check (snapshot-driven)

    @Test("hardware present -> pass with chip/memory/gpu detail")
    func hardwarePresent() {
        let checks = buildDoctorChecks(snapshot: snapshot(hardware: sampleHardware, configFileExists: true))
        let hw = check(checks, "hardware")
        #expect(hw?.status == .pass)
        #expect(hw?.detail == "Apple M4 Max, 128 GB RAM, 40 GPU cores")
    }

    @Test("hardware nil -> fail with default detail when no error is attached")
    func hardwareMissing() {
        let checks = buildDoctorChecks(snapshot: snapshot(hardware: nil, configFileExists: true))
        let hw = check(checks, "hardware")
        #expect(hw?.status == .fail)
        #expect(hw?.detail == "hardware detection failed")
    }

    // MARK: - config check (snapshot-driven)

    @Test("config file presence drives pass/warn")
    func configStatus() {
        let present = buildDoctorChecks(snapshot: snapshot(hardware: sampleHardware, configFileExists: true))
        #expect(check(present, "config")?.status == .pass)
        #expect(check(present, "config")?.detail == "loaded")

        let missing = buildDoctorChecks(snapshot: snapshot(hardware: sampleHardware, configFileExists: false))
        #expect(check(missing, "config")?.status == .warn)
        #expect(check(missing, "config")?.detail == "missing, defaults are in memory only")
    }

    // MARK: - local model count check (snapshot-driven)

    @Test("empty model set -> warn '0 discovered'")
    func noModelsWarns() {
        let checks = buildDoctorChecks(snapshot: snapshot(hardware: sampleHardware, configFileExists: true, models: []))
        let models = check(checks, "local mlx models")
        #expect(models?.status == .warn)
        #expect(models?.detail == "0 discovered")
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
}
