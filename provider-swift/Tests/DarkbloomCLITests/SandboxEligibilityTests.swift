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
        let eligibility = SandboxEligibility(.mac(cores: example.cores, memoryGiB: example.memoryGiB,
                                                  provider: example.provider))
        #expect(eligibility.linuxSlots == example.linux)
        #expect(eligibility.macOSSlots == example.macOS)
        #expect(eligibility.eligible == (example.linux + example.macOS > 0))
    }

    @Test("16 cores and 128 GB runs macOS and Linux jobs, including the 12-core, 32 GB macOS size")
    func largeMac() {
        let eligibility = SandboxEligibility(.mac(cores: 16, memoryGiB: 128))
        #expect(eligibility.keptCores == 4)
        #expect(eligibility.keptMemory == 32 << 30)
        #expect(eligibility.providerMemory == 32 << 30)
        #expect(eligibility.largeMacOSFits)
        #expect(eligibility.verdict() == [
            "Eligible. At a time, this Mac can run:",
            "  1 Linux job (limited by cores)",
            "  1 macOS job (limited by cores)",
            "  The most requested macOS size, 12 cores and 32 GB, fits.",
        ])
        // 16 cores and about 64 GB is the smallest Mac for it beside inference.
        #expect(SandboxEligibility(.mac(cores: 16, memoryGiB: 64)).largeMacOSFits)
        #expect(!SandboxEligibility(.mac(cores: 16, memoryGiB: 48)).largeMacOSFits)
        #expect(!SandboxEligibility(.mac(cores: 14, memoryGiB: 128)).largeMacOSFits)
        // No room for a Linux scratch disk leaves 12 cores and 32 GB with a macOS slot.
        let macOSOnly = SandboxEligibility(.mac(cores: 12, memoryGiB: 32, freeGiB: 160))
        #expect((macOSOnly.linuxSlots, macOSOnly.macOSSlots) == (0, 1))
        #expect(macOSOnly.verdict().last
            == "  The most requested macOS size, 12 cores and 32 GB, does not fit: it needs a Mac with at least "
                + "16 cores and about 64 GB.")
    }

    @Test("12 cores and 32 GB runs Linux jobs only")
    func linuxOnly() {
        let eligibility = SandboxEligibility(.mac(cores: 12, memoryGiB: 32))
        #expect(eligibility.verdict() == [
            "Eligible. At a time, this Mac can run:",
            "  1 Linux job (limited by memory)",
            "  no macOS jobs (limited by cores)",
        ])
    }

    @Test("8 cores and 16 GB is not eligible, and says what is short")
    func tooSmall() {
        let withInference = SandboxEligibility(.mac(cores: 8, memoryGiB: 16))
        #expect(!withInference.eligible)
        #expect(withInference.verdict() == [
            "Not eligible: each job needs 16 GB of memory besides the 8 GB kept for you and the 4 GB kept for "
                + "inference; this Mac has 4 GB left.",
        ])
        let checks = Dictionary(uniqueKeysWithValues: withInference.checks.map { ($0.name, $0) })
        #expect(checks["Memory"]?.level == .fail)
        #expect(checks["Memory"]?.detail == "16 GB; you keep 8 GB, inference keeps 4 GB")
        #expect(checks["CPU"]?.level == .pass)
        #expect(SandboxEligibility(.mac(cores: 4, memoryGiB: 64)).verdict()
            == ["Not eligible: each job needs 4 cores besides the 2 kept for you; this Mac has 2 left."])
    }

    @Test("the free-space floor is a tenth of the disk, between 50 and 100 GiB")
    func freeSpaceFloor() {
        #expect(SandboxEligibility.freeSpaceFloor(volumeBytes: 256 << 30) == 50 << 30)
        #expect(SandboxEligibility.freeSpaceFloor(volumeBytes: 700 << 30) == 70 << 30)
        #expect(SandboxEligibility.freeSpaceFloor(volumeBytes: 4_000 << 30) == 100 << 30)
    }

    @Test("disk: images and each Linux job need room above the floor; how much to free is exact")
    func disk() {
        // 2 TB disk: 100 GiB floor + 50 GiB images; 119 GiB free is 31 GiB short.
        let short = SandboxEligibility(.mac(cores: 16, memoryGiB: 128, freeGiB: 119))
        #expect(!short.eligible)
        #expect(short.verdict() == [
            "Not eligible: free up 61 GiB of disk, then this Mac can run 1 Linux job and 1 macOS job at a time. "
                + "100 GiB stays free for you, the VM images need 50 GiB and each Linux job 30 GiB.",
        ])
        #expect(short.checks.first { $0.name == "Disk" }?.level == .fail)
        // Room for the images but no Linux scratch disk: macOS only.
        let macOSOnly = SandboxEligibility(.mac(cores: 16, memoryGiB: 128, freeGiB: 160))
        #expect((macOSOnly.linuxSlots, macOSOnly.macOSSlots) == (0, 1))
        #expect(macOSOnly.verdict()[1] == "  no Linux jobs (limited by free disk)")
        // 30 GiB per Linux job above floor and images: 2 cores-and-memory-wise, 1 by disk.
        let oneByDisk = SandboxEligibility(.mac(cores: 32, memoryGiB: 512, freeGiB: 185))
        #expect((oneByDisk.linuxSlots, oneByDisk.linuxLimit) == (1, .disk))
        // Images already installed need no space.
        var rerun = SandboxHostFacts.mac(cores: 16, memoryGiB: 128, freeGiB: 135)
        rerun.imagesInstalled = true
        #expect(SandboxEligibility(rerun).linuxSlots == 1)
        // Only a Linux scratch disk is short on a Mac too small for macOS jobs.
        let linuxScratch = SandboxEligibility(.mac(cores: 8, memoryGiB: 64, freeGiB: 160))
        #expect(linuxScratch.verdict() == [
            "Not eligible: free up 20 GiB of disk, then this Mac can run 1 Linux job at a time. "
                + "100 GiB stays free for you, the VM images need 50 GiB and each Linux job 30 GiB.",
        ])
    }

    @Test("Intel, macOS before 27 and no network are refused outright")
    func refusals() {
        var intel = SandboxHostFacts.mac(cores: 16, memoryGiB: 64)
        intel.appleSilicon = false
        intel.chip = "Intel(R) Core(TM) i9"
        #expect(SandboxEligibility(intel).verdict()
            == ["Not eligible: Darkbloom Sandbox needs a Mac with Apple silicon (this one has Intel(R) Core(TM) i9)."])
        var old = SandboxHostFacts.mac(cores: 16, memoryGiB: 64)
        old.macOSMajor = 26
        old.macOSVersion = "26.4"
        let refused = SandboxEligibility(old)
        #expect(!refused.eligible)
        #expect(refused.verdict() == ["Not eligible: Darkbloom Sandbox needs macOS 27 or later; this Mac runs "
            + "macOS 26.4. Update it in System Settings → General → Software Update first."])
        #expect(refused.checks.first { $0.name == "macOS" }?.level == .fail)
        var offline = SandboxHostFacts.mac(cores: 16, memoryGiB: 64)
        offline.network = .offline
        #expect(SandboxEligibility(offline).refusal == "This Mac is not connected to the Internet.")
        var remote = SandboxHostFacts.mac(cores: 16, memoryGiB: 64)
        remote.desktopSession = false
        remote.userName = "ada"
        let away = SandboxEligibility(remote)
        #expect(away.verdict() == ["Not eligible: Log in to this Mac's desktop as ada and run setup there: the add-on "
            + "runs in your login session."])
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
        #expect(eligibility.eligible)
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

    @Test("slot counts the owner chose replace the estimate; counts that do not fit are flagged")
    func requestedSlots() {
        let eligibility = SandboxEligibility(.mac(cores: 32, memoryGiB: 512))
        // 4 Linux and 1 macOS take 24 of the 24 cores left for jobs: they fit.
        #expect(eligibility.verdict(linuxRequested: 4, macOSRequested: 1) == [
            "Eligible. At a time, this Mac can run:",
            "  4 Linux jobs (your choice)",
            "  1 macOS job (your choice)",
            "  The most requested macOS size, 12 cores and 32 GB, fits.",
        ])
        #expect(eligibility.verdict(linuxRequested: 8).contains(
            "  Those counts need more cores, memory or disk than this Mac has left for jobs; jobs may run slowly."))
        #expect(eligibility.verdict().last
            == "  macOS runs at most 2 macOS VMs at once, yours included; `--macos-slots 1` keeps one for you.")
        #expect(eligibility.slots(linuxRequested: 0, macOSRequested: nil) == (0, 2))
        // Giving up the Linux job leaves 12 cores and 32 GB room for a macOS one.
        let small = SandboxEligibility(.mac(cores: 12, memoryGiB: 32))
        #expect(small.fits(linux: 0, macOS: 1) && !small.fits(linux: 1, macOS: 1))
        #expect(small.verdict(linuxRequested: 0, macOSRequested: 1) == [
            "Eligible. At a time, this Mac can run:",
            "  no Linux jobs (your choice)",
            "  1 macOS job (your choice)",
            "  The most requested macOS size, 12 cores and 32 GB, does not fit: it needs a Mac with at least "
                + "16 cores and about 64 GB.",
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
