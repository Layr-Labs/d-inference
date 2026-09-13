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
        bootSecurity: BootSecuritySnapshot = .init(macOSMajorVersion: 26, sip: .enabled),
        contention: LocalContentionSnapshot = .empty
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
            bootSecurity: bootSecurity,
            contention: contention
        )
    }

    private func check(_ checks: [DoctorCheck], _ name: String) -> DoctorCheck? {
        checks.first { $0.name == name }
    }

    @Test("check backbone includes local posture but leaves Secure Boot to MDM")
    func stableBackbone() {
        #expect(checks(hardware: hardware).map(\.name) == [
            "hardware", "metal gpu", "config", "huggingface cache", "local mlx models",
            "macos", "sip", "rdma", "authenticated root", "hardened runtime", "debugger",
            "binary hash", "competing inference",
        ])
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

    @Test("competing inference warns on ollama port or known process hints")
    func competingInferenceDiagnosis() {
        let clear = checks(hardware: hardware, contention: .empty)
        #expect(check(clear, "competing inference")?.status == .pass)

        let ollama = checks(
            hardware: hardware,
            contention: .init(ollamaPortListening: true, competingProcessHints: ["ollama"])
        )
        #expect(check(ollama, "competing inference")?.status == .warn)
        #expect(check(ollama, "competing inference")?.detail.contains("11434") == true)

        let llama = checks(
            hardware: hardware,
            contention: .init(ollamaPortListening: false, competingProcessHints: ["llama-server"])
        )
        #expect(check(llama, "competing inference")?.status == .warn)
        #expect(check(llama, "competing inference")?.detail.contains("llama-server") == true)
    }
}
