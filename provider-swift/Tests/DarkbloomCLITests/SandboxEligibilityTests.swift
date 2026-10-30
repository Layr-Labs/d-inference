import Foundation
import ProviderCore
import Testing

@testable import darkbloom

@Suite("darkbloom sandbox setup: eligibility")
struct SandboxEligibilityTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let cores: Int
        let memoryGiB: Int64
        let provider: Bool
        let linux: Int
        let macOS: Int
        var testDescription: String {
            "\(cores) cores, \(memoryGiB) GB\(provider ? " with inference" : ""): \(linux) Linux, \(macOS) macOS"
        }
    }

    /// The add-on's own sizing table (its provider FAQ), plus the brief's examples.
    @Test("slots follow the add-on's sizing rules", arguments: [
        Case(cores: 16, memoryGiB: 128, provider: true, linux: 1, macOS: 1),
        Case(cores: 16, memoryGiB: 128, provider: false, linux: 1, macOS: 1),
        Case(cores: 12, memoryGiB: 32, provider: true, linux: 1, macOS: 0),
        Case(cores: 12, memoryGiB: 32, provider: false, linux: 1, macOS: 0),
        Case(cores: 8, memoryGiB: 16, provider: true, linux: 0, macOS: 0),
        Case(cores: 8, memoryGiB: 16, provider: false, linux: 0, macOS: 0),
        Case(cores: 16, memoryGiB: 48, provider: false, linux: 1, macOS: 1),
        Case(cores: 16, memoryGiB: 48, provider: true, linux: 1, macOS: 0),
        Case(cores: 24, memoryGiB: 192, provider: true, linux: 2, macOS: 1),
        Case(cores: 32, memoryGiB: 512, provider: true, linux: 2, macOS: 2),
        Case(cores: 10, memoryGiB: 24, provider: false, linux: 1, macOS: 0),
    ])
    func sizing(_ example: Case) {
        let plan = SandboxEligibility(.mac(cores: example.cores, memoryGiB: example.memoryGiB,
                                           provider: example.provider)).estimatedPlan()
        #expect(plan.linux.slots == example.linux)
        #expect(plan.macOS.slots == example.macOS)
        #expect(plan.runsJobs == (example.linux + example.macOS > 0))
    }

    @Test("16 cores and 128 GB runs macOS and Linux jobs, including the 12-core, 32 GB macOS size")
    func largeMac() {
        let plan = SandboxEligibility(.mac(cores: 16, memoryGiB: 128)).estimatedPlan()
        #expect(plan.coresKept == 4)
        #expect(plan.memoryKeptBytes == 32 << 30)
        #expect(plan.providerMemoryBytes == 32 << 30)
        #expect(plan.verdict == [
            "Eligible. At a time, this Mac can run:",
            "  1 Linux job (limited by cores)",
            "  1 macOS job (limited by cores)",
            "  The most requested macOS size, 12 cores and 32 GB, fits.",
        ])
        // 16 cores and about 64 GB is the smallest Mac for it beside inference.
        #expect(SandboxEligibility(.mac(cores: 16, memoryGiB: 64)).estimatedPlan().verdict.last
            == "  The most requested macOS size, 12 cores and 32 GB, fits.")
        #expect(SandboxEligibility(.mac(cores: 12, memoryGiB: 32)).estimatedPlan(linuxRequested: 0, macOSRequested: 1)
            .verdict.last == "  The most requested macOS size, 12 cores and 32 GB, does not fit: it needs a Mac with "
                + "at least 16 cores and about 64 GB.")
    }

    @Test("12 cores and 32 GB runs Linux jobs only")
    func linuxOnly() {
        #expect(SandboxEligibility(.mac(cores: 12, memoryGiB: 32)).estimatedPlan().verdict == [
            "Eligible. At a time, this Mac can run:",
            "  1 Linux job (limited by memory)",
            "  no macOS jobs (limited by cores)",
        ])
    }

    @Test("8 cores and 16 GB is not eligible, and says what is short")
    func tooSmall() {
        let withInference = SandboxEligibility(.mac(cores: 8, memoryGiB: 16)).estimatedPlan()
        #expect(!withInference.runsJobs)
        #expect(withInference.verdict == [
            "Not eligible: each job needs 16 GB of memory besides the 8 GB kept for you and the 4 GB kept for "
                + "inference; this Mac has 4 GB left.",
        ])
        let checks = Dictionary(uniqueKeysWithValues: withInference.checks.map { ($0.name, $0) })
        #expect(checks["Memory"]?.level == .fail)
        #expect(checks["Memory"]?.detail == "16 GB; you keep 8 GB, inference keeps 4 GB")
        // A macOS job's 8 cores do not fit either; the disk does.
        #expect(checks["CPU"]?.level == .fail)
        #expect(checks["Disk"]?.level == .pass)
        #expect(SandboxEligibility(.mac(cores: 4, memoryGiB: 64)).estimatedPlan().verdict
            == ["Not eligible: each job needs 4 cores besides the 2 kept for you; this Mac has 2 left."])
    }

    @Test("the free-space floor is a tenth of the disk, between 50 and 100 GiB")
    func freeSpaceFloor() {
        #expect(SandboxEligibility.freeSpaceFloor(volumeBytes: 256 << 30) == 50 << 30)
        #expect(SandboxEligibility.freeSpaceFloor(volumeBytes: 700 << 30) == 70 << 30)
        #expect(SandboxEligibility.freeSpaceFloor(volumeBytes: 4_000 << 30) == 100 << 30)
    }

    @Test("fallback disk: a platform's first slot brings its images, each slot its job's disk, above the floor")
    func disk() throws {
        // The add-on's own plan for this Mac: 57 GiB above the floor fits Linux images (4) and one Linux
        // job (30), not another (30) nor macOS images (46) and a macOS job (40).
        let small = SandboxEligibility(.mac(cores: 16, memoryGiB: 128, freeGiB: 157, volumeGiB: 1_858))
        var addon = try #require(SandboxSizingPlan(line: FakeSandboxInstaller.plan()))
        addon.message = nil
        #expect(small.estimatedPlan() == addon)
        // 2 TB disk, 100 GiB floor: 119 GiB free fits no job and says how much to free for one.
        let short = SandboxEligibility(.mac(cores: 16, memoryGiB: 128, freeGiB: 119)).estimatedPlan()
        #expect(short.verdict == [
            "Not eligible: no job fits on this Mac.",
            "  Free up 15 GiB of disk for one Linux job, or 67 GiB of disk for one macOS job.",
        ])
        #expect(short.checks.map(\.level) == [.pass, .pass, .fail])
        // Both first slots fit; the rest of the disk holds no further job.
        let both = SandboxEligibility(.mac(cores: 32, memoryGiB: 512, freeGiB: 220)).estimatedPlan()
        #expect((both.linux.slots, both.macOS.slots, both.linux.limit) == (1, 1, "free disk space"))
        // Later Linux slots cost 30 GiB each: 85 GiB holds two, not a macOS slot's 86.
        let linuxByDisk = SandboxEligibility(.mac(cores: 32, memoryGiB: 512, freeGiB: 185)).estimatedPlan()
        #expect((linuxByDisk.linux.slots, linuxByDisk.macOS.slots) == (2, 0))
        // Installed images need no space.
        var rerun = SandboxHostFacts.mac(cores: 16, memoryGiB: 128, freeGiB: 135)
        rerun.imagesInstalled = true
        let installed = SandboxEligibility(rerun).estimatedPlan()
        #expect((installed.linux.slots, installed.macOS.slots) == (1, 0))
        #expect(installed.checks.last?.detail == "135 GiB free; 100 GiB stays free for you; Linux images installed "
            + "+ 30 GiB per Linux job; macOS images installed + 40 GiB per macOS job")
    }

    @Test("Intel, macOS before 27 and no network are refused outright")
    func refusals() {
        var intel = SandboxHostFacts.mac(cores: 16, memoryGiB: 64)
        intel.appleSilicon = false
        intel.chip = "Intel(R) Core(TM) i9"
        #expect(SandboxEligibility(intel).refusal
            == "Darkbloom Sandbox needs a Mac with Apple silicon (this one has Intel(R) Core(TM) i9).")
        var old = SandboxHostFacts.mac(cores: 16, memoryGiB: 64)
        old.macOSMajor = 26
        old.macOSVersion = "26.4"
        let refused = SandboxEligibility(old)
        #expect(refused.refusal == "Darkbloom Sandbox needs macOS 27 or later; this Mac runs "
            + "macOS 26.4. Update it in System Settings → General → Software Update first.")
        #expect(refused.checks.first { $0.name == "macOS" }?.level == .fail)
        var offline = SandboxHostFacts.mac(cores: 16, memoryGiB: 64)
        offline.network = .offline
        #expect(SandboxEligibility(offline).refusal == "This Mac is not connected to the Internet.")
        var remote = SandboxHostFacts.mac(cores: 16, memoryGiB: 64)
        remote.desktopSession = false
        remote.userName = "ada"
        let away = SandboxEligibility(remote)
        #expect(away.refusal == "Log in to this Mac's desktop as ada and run setup there: the add-on "
            + "runs in your login session.")
        // Setup's own checks, before it asks the installer for the sizing lines.
        #expect(away.checks.map(\.name) == ["Chip", "macOS", "Session", "Network", "Power", "Sleep"])
        #expect(away.checks.first { $0.name == "Session" } == .init(
            level: .fail, name: "Session", detail: "not logged in at this Mac's desktop",
            fix: "log in at the desktop as ada; the add-on runs in that session"))
    }

    @Test("Wi-Fi, a laptop on battery and automatic sleep warn without blocking")
    func warnings() {
        var facts = SandboxHostFacts.mac(cores: 16, memoryGiB: 128)
        facts.network = .wifi
        facts.power = .battery
        facts.sleepMinutes = 10
        let eligibility = SandboxEligibility(facts)
        #expect(eligibility.refusal == nil)
        let warnings = eligibility.checks.filter { $0.level == .warn }.map(\.name)
        #expect(warnings == ["Network", "Power", "Sleep"])
        #expect(eligibility.checks.last == .init(
            level: .warn, name: "Sleep", detail: "after 10 min idle (a sleeping Mac gets no jobs and loses running ones)",
            fix: "sudo pmset -c sleep 0"))
        #expect(eligibility.checks.filter { $0.level == .warn }.allSatisfy { $0.fix != nil })
        let calm = SandboxEligibility(.mac(cores: 16, memoryGiB: 128)).checks
        #expect(calm.allSatisfy { $0.level == .pass })
        facts.power = .pluggedIn
        facts.sleepMinutes = nil
        facts.network = .unknown
        let unknown = SandboxEligibility(facts).checks
        #expect(unknown.first { $0.name == "Power" }?.level == .pass)
        #expect(unknown.first { $0.name == "Sleep" }?.level == .info)
        #expect(unknown.first { $0.name == "Network" }?.level == .info)
    }

    @Test("fallback: slot counts the owner chose replace the estimate")
    func requestedSlots() {
        let eligibility = SandboxEligibility(.mac(cores: 32, memoryGiB: 512))
        #expect(eligibility.estimatedPlan(linuxRequested: 4, macOSRequested: 1).verdict == [
            "Eligible. At a time, this Mac can run:",
            "  4 Linux jobs (your choice)",
            "  1 macOS job (your choice)",
            "  The most requested macOS size, 12 cores and 32 GB, fits.",
        ])
        #expect(eligibility.estimatedPlan().verdict.last
            == "  macOS runs at most 2 macOS VMs at once, yours included; `--macos-slots 1` keeps one for you.")
        let noLinux = eligibility.estimatedPlan(linuxRequested: 0)
        #expect((noLinux.linux.slots, noLinux.linux.automatic, noLinux.macOS.slots) == (0, false, 2))
        // The automatic macOS estimate leaves the cores to Linux, so choosing no Linux runs nothing.
        #expect(SandboxEligibility(.mac(cores: 12, memoryGiB: 32)).estimatedPlan(linuxRequested: 0).verdict == [
            "Not eligible: no job fits on this Mac.",
            "  That is with the slot counts you chose; change --linux-slots or --macos-slots.",
        ])
    }

    @Test("pmset: the power adapter's sleep timer, and SleepDisabled")
    func pmsetParsing() {
        let laptop = """
        Battery Power:
         Sleep On Power Button 1
         powermode            1
         sleep                0
         displaysleep         10
        AC Power:
         Sleep On Power Button 1
         powermode            0
         sleep                1
         displaysleep         10
        """
        #expect(SandboxHostProbe.powerAdapterSleepMinutes(laptop) == 1)
        #expect(SandboxHostProbe.powerAdapterSleepMinutes("AC Power:\n sleep                0\n") == 0)
        #expect(SandboxHostProbe.powerAdapterSleepMinutes("Battery Power:\n sleep 5\n") == nil)
        #expect(SandboxHostProbe.sleepDisabled("System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:"))
        #expect(!SandboxHostProbe.sleepDisabled("System-wide power settings:\n SleepDisabled\t\t0\n"))
        let runner = SecurityCommandRunner { _, arguments in
            arguments == ["-g"]
                ? SecurityCommandResult(terminationStatus: 0, stdout: " SleepDisabled\t\t0\n")
                : SecurityCommandResult(terminationStatus: 0, stdout: laptop)
        }
        #expect(SandboxHostProbe.sleepMinutes(runner: runner) == 1)
        let disabled = SecurityCommandRunner { _, _ in
            SecurityCommandResult(terminationStatus: 0, stdout: " SleepDisabled\t\t1\n")
        }
        #expect(SandboxHostProbe.sleepMinutes(runner: disabled) == 0)
    }

    @Test("the live probe reads this Mac without failing")
    func liveProbe() async {
        let facts = await SandboxHostProbe.live(addon: SandboxAddon(root: FakeSandboxAddon.temporaryRoot()),
                                                imagesInstalled: false)
        #expect(facts.cores >= 1)
        #expect(facts.memoryBytes > 0)
        #expect(facts.volumeBytes >= facts.freeBytes)
        #expect(facts.macOSMajor == ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
        #if arch(arm64)
        #expect(facts.appleSilicon)
        #endif
    }
}
