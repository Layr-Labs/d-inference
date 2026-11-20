import DarkbloomFanProtocol
import DarkbloomProcessHardening
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
        contention: LocalContentionSnapshot = .empty,
        startupHardening: ProcessStartupHardening.Outcome? = StartupHardeningGateTests.clean,
        fanHelperVersion: String? = nil,
        servesDarkbloom: Bool = true
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
            contention: contention,
            startupHardening: startupHardening,
            fanHelperVersion: { fanHelperVersion },
            servesDarkbloom: servesDarkbloom
        )
    }

    @Test("doctor warns about an installed fan helper older than this build")
    func outdatedFanHelper() {
        #expect(check(checks(), "fan helper") == nil)
        #expect(check(checks(fanHelperVersion: FanIPC.helperVersion), "fan helper") == nil)
        let outdated = check(checks(fanHelperVersion: "1"), "fan helper")
        #expect(outdated?.status == .warn)
        #expect(outdated?.detail.contains("sudo \(BuildEnvironment.current.cliName) fan enable") == true)
    }

    private func check(_ checks: [DoctorCheck], _ name: String) -> DoctorCheck? {
        checks.first { $0.name == name }
    }

    @Test("doctor fails when this process kept a debugging handle it was started with")
    func startupHardening() {
        #expect(check(checks(), "startup hardening")?.status == .pass)
        for outcome in [nil, StartupHardeningGateTests.handlerLeft, StartupHardeningGateTests.removalRefused] {
            let line = check(checks(startupHardening: outcome), "startup hardening")
            #expect(line?.status == .fail)
            #expect(line?.detail.contains("will not serve") == true)
        }
    }

    @Test("check backbone includes local posture, Secure Boot included")
    func stableBackbone() {
        #expect(checks(hardware: hardware).map(\.name) == [
            "hardware", "metal gpu", "config", "huggingface cache", "local mlx models",
            "macos", "sip", "secure boot", "process sandbox", "rdma", "authenticated root", "hardened runtime",
            "debugger",
            "startup hardening", "binary hash", "competing inference",
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

    @Test("macOS warns, SIP not at its default fails; both share the compact action guide")
    func bootSecurityWarnings() {
        let posture = BootSecuritySnapshot(macOSMajorVersion: 25, sip: .disabled)
        let result = checks(hardware: hardware, bootSecurity: posture)
        #expect(check(result, "macos")?.status == .warn)
        #expect(check(result, "sip")?.status == .fail)

        let guide = bootSecurityActionGuide(posture)
        #expect(guide?.contains("Software Update") == true)
        #expect(guide?.contains("csrutil enable") == true)
        #expect(bootSecurityActionGuide(.init(macOSMajorVersion: 26, sip: .enabled)) == nil)
    }

    @Test("sip names the protections a custom configuration turns off; secure boot reads the policy")
    func exactBootSecurity() {
        let custom = BootSecuritySnapshot(macOSMajorVersion: 27, sip: .enabled,
                                          sipConfiguration: SIPConfiguration(rawValue: 0x24), secureBoot: .permissive)
        let refused = checks(hardware: hardware, bootSecurity: custom)
        #expect(check(refused, "sip")?.status == .fail)
        #expect(check(refused, "sip")?.detail
                == "not at the default configuration (0x24); off: Debugging Restrictions, DTrace Restrictions")
        #expect(check(refused, "secure boot")?.status == .fail)
        #expect(check(refused, "secure boot")?.detail.contains("Permissive Security") == true)

        let healthy = checks(hardware: hardware, bootSecurity: .init(
            macOSMajorVersion: 27, sip: .enabled, sipConfiguration: SIPConfiguration(rawValue: 0), secureBoot: .full))
        #expect(check(healthy, "sip")?.status == .pass)
        #expect(check(healthy, "sip")?.detail == "enabled (default configuration)")
        #expect(check(healthy, "secure boot")?.status == .pass)
        #expect(check(healthy, "secure boot")?.detail == "Full Security")

        let unread = checks(hardware: hardware, bootSecurity: .init(macOSMajorVersion: 27, sip: .enabled))
        #expect(check(unread, "secure boot")?.status == .warn)

        // Only me: the refusal keeps only Darkbloom serving off, so it warns.
        let onlyMe = checks(hardware: hardware, bootSecurity: custom, servesDarkbloom: false)
        #expect(check(onlyMe, "sip")?.status == .warn)
        #expect(check(onlyMe, "secure boot")?.status == .warn)
        #expect(check(onlyMe, "sip")?.detail == check(refused, "sip")?.detail)
    }

    @Test("process sandbox fails inside a sandbox the provider didn't set up; Only me warns")
    func processSandbox() {
        let sandboxed = BootSecuritySnapshot(macOSMajorVersion: 27, sip: .enabled,
                                             sipConfiguration: SIPConfiguration(rawValue: 0), processSandbox: .sandboxed)
        let refused = checks(hardware: hardware, bootSecurity: sandboxed)
        #expect(check(refused, "process sandbox")?.status == .fail)
        // Per process: the row says it is this command's.
        #expect(check(refused, "process sandbox")?.detail.hasPrefix("this command: running inside a sandbox") == true)
        #expect(check(checks(hardware: hardware, bootSecurity: sandboxed, servesDarkbloom: false),
                      "process sandbox")?.status == .warn)
        #expect(check(checks(hardware: hardware), "process sandbox")?.status == .pass)
        #expect(bootSecurityActionGuide(sandboxed)?.contains("Process sandbox: ") == true)
    }

    @Test("the running service's own hold: a row that fails, or warns on Only me, and its remedy in the guide")
    func serviceHold() {
        #expect(serviceBootSecurityHold(["process_sandbox", "not-a-kind"]) == [.processSandbox])
        #expect(serviceHoldCheck([], servesDarkbloom: true) == nil)
        let row = serviceHoldCheck([.processSandbox], servesDarkbloom: true)
        #expect(row?.status == .fail)
        #expect(row?.detail == "the running service holds Darkbloom serving off: Process sandbox")
        #expect(serviceHoldCheck([.processSandbox], servesDarkbloom: false)?.status == .warn)

        // A clean command and a held service: the guide gives the service's remedy.
        let clean = BootSecuritySnapshot(macOSMajorVersion: 27, sip: .enabled,
                                         sipConfiguration: SIPConfiguration(rawValue: 0), secureBoot: .full)
        let guide = bootSecurityActionGuide(clean, serviceHold: [.processSandbox])
        #expect(guide?.contains("Process sandbox (the running service): Start Darkbloom from a standard installation") == true)
        #expect(bootSecurityActionGuide(clean) == nil)
        // The same kind in this command's own checks is not repeated.
        let sandboxed = BootSecuritySnapshot(macOSMajorVersion: 27, sip: .enabled,
                                             sipConfiguration: SIPConfiguration(rawValue: 0), processSandbox: .sandboxed)
        #expect(bootSecurityActionGuide(sandboxed, serviceHold: [.processSandbox])?.contains("running service") == false)
        // An unanswered check here is only advisory: the held service's remedy still shows.
        let unchecked = BootSecuritySnapshot(macOSMajorVersion: 27, sip: .enabled,
                                             sipConfiguration: SIPConfiguration(rawValue: 0), processSandbox: .unknown)
        let both = bootSecurityActionGuide(unchecked, serviceHold: [.processSandbox])
        #expect(both?.contains("Process sandbox: Run") == true)
        #expect(both?.contains("Process sandbox (the running service): Start Darkbloom from a standard installation") == true)
    }

    @Test("ACTION REQUIRED only for a refusal on a Mac that serves Darkbloom; otherwise advisory")
    func actionHeading() {
        let unchecked = BootSecuritySnapshot(macOSMajorVersion: 27, sip: .enabled,
                                             sipConfiguration: SIPConfiguration(rawValue: 0), processSandbox: .unknown)
        #expect(bootSecurityActionGuide(unchecked) != nil)
        #expect(bootSecurityActionHeading(unchecked, serviceHold: [], servesDarkbloom: true) == "BOOT SECURITY — ADVISORY")
        let refused = BootSecuritySnapshot(macOSMajorVersion: 27, sip: .disabled)
        #expect(bootSecurityActionHeading(refused, serviceHold: [], servesDarkbloom: true)
                == "BOOT SECURITY — ACTION REQUIRED")
        #expect(bootSecurityActionHeading(refused, serviceHold: [], servesDarkbloom: false) == "BOOT SECURITY — ADVISORY")
        #expect(bootSecurityActionHeading(unchecked, serviceHold: [.sip], servesDarkbloom: true)
                == "BOOT SECURITY — ACTION REQUIRED")
    }

    @Test("authenticated root comes from the posture: off fails (warns on Only me), unread warns, on passes")
    func authenticatedRootRow() {
        func posture(_ authenticatedRoot: Bool?) -> BootSecuritySnapshot {
            BootSecuritySnapshot(macOSMajorVersion: 27, sip: .enabled, sipConfiguration: SIPConfiguration(rawValue: 0),
                                 secureBoot: .full, authenticatedRoot: authenticatedRoot)
        }
        #expect(check(checks(hardware: hardware, bootSecurity: posture(false)), "authenticated root")?.status == .fail)
        #expect(check(checks(hardware: hardware, bootSecurity: posture(false), servesDarkbloom: false),
                      "authenticated root")?.status == .warn)
        #expect(check(checks(hardware: hardware, bootSecurity: posture(nil)), "authenticated root")?.status == .warn)
        #expect(check(checks(hardware: hardware, bootSecurity: posture(true)), "authenticated root")?.status == .pass)
        #expect(bootSecurityActionGuide(posture(false))?.contains("csrutil authenticated-root enable") == true)
    }

    @Test("the retired profile row shows only this install's profile, and never fails")
    func retiredProfileRow() throws {
        let ours = try #require(retiredMDMProfileCheck(.enrolledDarkbloom(serverURL: "https://api.darkbloom.dev/mdm/connect")))
        #expect(ours.name == "darkbloom mdm profile")
        #expect(ours.status == .info)
        #expect(!ours.status.isFailure(strict: true))
        #expect(ours.detail.contains("no longer used"))
        #expect(ours.detail.contains("unenroll` and choose 2"))
        let states: [MDMEnrollmentState] = [
            .notEnrolled, .checkFailed, .enrolledOtherMDM(serverURL: "https://corp.example/mdm/connect"),
        ]
        for state in states {
            #expect(retiredMDMProfileCheck(state) == nil, "\(state)")
        }
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
            homeDirectory: base, configuredDirectory: file.path
        )
        // A plain fileExists() check called this PASS while the scanner found
        // nothing.
        #expect(check.status == .warn)
    }

    @Test("hfCacheCheck warns when a missing cache path is configured")
    func hfCacheCheckMissingPath() throws {
        let base = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("doctor-missing-\(UUID().uuidString)", isDirectory: true)

        let check = hfCacheCheck(
            homeDirectory: base, configuredDirectory: base.appendingPathComponent("hub").path
        )
        #expect(check.status == .warn)
    }

    /// Selecting an empty cache must warn when the old cache still holds models.
    @Test("hfCacheCheck warns when the redirected cache is empty but home is not")
    func hfCacheCheckEmptyRedirect() throws {
        let root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("doctor-empty-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let redirected = root.appendingPathComponent("elsewhere", isDirectory: true)
        let fm = FileManager.default
        let defaultModel = home.appendingPathComponent(".cache/huggingface/hub/models--acme--Tiny/snapshots/local")
        try makeCachedModel(at: defaultModel)
        try fm.createDirectory(at: redirected.appendingPathComponent("hub", isDirectory: true),
                               withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let check = hfCacheCheck(
            homeDirectory: home, configuredDirectory: redirected.appendingPathComponent("hub").path
        )
        #expect(check.status == .warn)

        // An empty download directory does not make the cache healthy.
        let modelDir = redirected.appendingPathComponent("hub/models--acme--Other")
        try fm.createDirectory(at: modelDir, withIntermediateDirectories: true)
        #expect(hfCacheCheck(homeDirectory: home,
                            configuredDirectory: redirected.appendingPathComponent("hub").path).status == .warn)
        try makeCachedModel(at: modelDir.appendingPathComponent("snapshots/local"))
        let ok = hfCacheCheck(
            homeDirectory: home, configuredDirectory: redirected.appendingPathComponent("hub").path
        )
        #expect(ok.status == .pass)
    }

    @Test("hfCacheCheck passes on the legacy default cache")
    func hfCacheCheckDefault() throws {
        let home = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("doctor-default-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".cache/huggingface/hub", isDirectory: true),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let check = hfCacheCheck(homeDirectory: home)
        #expect(check.status == .pass)
    }

    private func makeCachedModel(at snapshot: URL) throws {
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("{\"model_type\":\"qwen2\"}".utf8).write(to: snapshot.appendingPathComponent("config.json"))
        try Data([1, 2, 3, 4]).write(to: snapshot.appendingPathComponent("model.safetensors"))
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
