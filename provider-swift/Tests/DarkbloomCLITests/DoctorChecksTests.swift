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

    @Test("hfCacheSourceSuffix names the env var that redirected the cache")
    func hfCacheSource() {
        #expect(hfCacheSourceSuffix(environment: [:]) == "")
        #expect(hfCacheSourceSuffix(environment: ["HF_HOME": "/v/hf"]) == " (via $HF_HOME)")
        #expect(hfCacheSourceSuffix(environment: ["HF_HUB_CACHE": "/v/hub"])
            == " (via $HF_HUB_CACHE)")
        #expect(hfCacheSourceSuffix(environment: ["HUGGINGFACE_HUB_CACHE": "/v/legacy"])
            == " (via $HUGGINGFACE_HUB_CACHE)")
        #expect(hfCacheSourceSuffix(environment: ["XDG_CACHE_HOME": "/v/xdg"])
            == " (via $XDG_CACHE_HOME)")

        // HF_HUB_CACHE wins, matching huggingface_hub precedence.
        #expect(
            hfCacheSourceSuffix(environment: [
                "HF_HOME": "/v/hf", "HF_HUB_CACHE": "/v/hub",
                "HUGGINGFACE_HUB_CACHE": "/v/legacy", "XDG_CACHE_HOME": "/v/xdg",
            ]) == " (via $HF_HUB_CACHE)"
        )

        // Blank values are not a redirect and fall through.
        #expect(hfCacheSourceSuffix(environment: ["HF_HOME": "  "]) == "")
        #expect(hfCacheSourceSuffix(environment: ["HF_HUB_CACHE": "", "HF_HOME": "/v/hf"])
            == " (via $HF_HOME)")
    }

    @Test("hfCacheCheck warns when the cache path is a regular file")
    func hfCacheCheckRejectsFile() throws {
        let base = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("doctor-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let file = base.appendingPathComponent("hub")
        try "not a directory".write(to: file, atomically: true, encoding: .utf8)

        let check = hfCacheCheck(
            environment: [ModelScanner.hfHubCacheEnvKey: file.path],
            homeDirectory: base
        )
        // A plain fileExists() check called this PASS while the scanner found
        // nothing.
        #expect(check.status == .warn)
        #expect(check.detail.contains("not a directory"))
        #expect(check.detail.contains("$HF_HUB_CACHE"))
    }

    @Test("hfCacheCheck warns when a missing cache path is configured")
    func hfCacheCheckMissingPath() throws {
        let base = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("doctor-missing-\(UUID().uuidString)", isDirectory: true)

        let check = hfCacheCheck(
            environment: [ModelScanner.hfHomeEnvKey: base.path],
            homeDirectory: base
        )
        #expect(check.status == .warn)
        #expect(check.detail.contains("not found"))
    }

    /// The upgrade hazard: an operator who exported HF_HOME for other tooling
    /// would silently advertise zero models.
    @Test("hfCacheCheck warns when the redirected cache is empty but home is not")
    func hfCacheCheckEmptyRedirect() throws {
        let root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("doctor-empty-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let redirected = root.appendingPathComponent("elsewhere", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(
            at: home.appendingPathComponent(".cache/huggingface/hub/models--acme--Tiny",
                                            isDirectory: true),
            withIntermediateDirectories: true)
        try fm.createDirectory(at: redirected.appendingPathComponent("hub", isDirectory: true),
                               withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let check = hfCacheCheck(
            environment: [ModelScanner.hfHomeEnvKey: redirected.path],
            homeDirectory: home
        )
        #expect(check.status == .warn)
        #expect(check.detail.contains("empty"))
        #expect(check.detail.contains("models are in"))

        // With models present in the redirected cache it passes.
        try fm.createDirectory(
            at: redirected.appendingPathComponent("hub/models--acme--Other", isDirectory: true),
            withIntermediateDirectories: true)
        let ok = hfCacheCheck(
            environment: [ModelScanner.hfHomeEnvKey: redirected.path],
            homeDirectory: home
        )
        #expect(ok.status == .pass)
        #expect(ok.detail.contains("(via $HF_HOME)"))
    }

    @Test("hfCacheCheck passes on the default cache with no env override")
    func hfCacheCheckDefault() throws {
        let home = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("doctor-default-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".cache/huggingface/hub", isDirectory: true),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let check = hfCacheCheck(environment: [:], homeDirectory: home)
        #expect(check.status == .pass)
        #expect(check.detail.hasSuffix(".cache/huggingface/hub"))
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
