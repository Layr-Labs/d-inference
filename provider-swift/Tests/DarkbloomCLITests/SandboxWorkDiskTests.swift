import ArgumentParser
import Foundation
import Testing

@testable import darkbloom

@Suite("darkbloom sandbox setup --disk")
struct SandboxWorkDiskTests {
    static let ready = SandboxWorkDisk.Volume(mountPoint: "/Volumes/FastSSD", fileSystem: "apfs",
                                              ignoresOwnership: false)
    static let ownershipOff = SandboxWorkDisk.Volume(mountPoint: "/Volumes/FastSSD", fileSystem: "apfs",
                                                     ignoresOwnership: true)
    static let enableOwnership = "sudo diskutil enableOwnership /Volumes/FastSSD"

    /// A plan for `/Volumes/FastSSD` alone: 2 Linux and 1 macOS slots on it.
    static let externalPlan = FakeSandboxInstaller.plan(
        message: "2 Linux slots and 1 macOS slot", linux: 2, macOS: 1,
        extra: #","disks":[{"path":"/Volumes/FastSSD","directory":"/Volumes/FastSSD/DarkbloomSandbox","#
            + #""root_volume":false,"volume_bytes":\#(Int64(1_000) << 30),"free_bytes":\#(Int64(900) << 30),"#
            + #""floor_bytes":\#(Int64(93) << 30),"linux_slots":2,"macos_slots":1,"linux_images_bytes":0,"#
            + #""macos_images_bytes":0,"cache":true}]"#)

    // MARK: - Options and arguments

    @Test("--disk repeats, becomes an absolute path, and an empty one is refused")
    func parsing() throws {
        let setup = try Sandbox.Setup.parse(["--disk", "/Volumes/FastSSD/", "--disk", "~"])
        #expect(setup.options.disks == ["/Volumes/FastSSD", NSHomeDirectory()])
        #expect(try Sandbox.Setup.parse([]).options.disks.isEmpty)
        #expect(throws: (any Error).self) { try Sandbox.Setup.parse(["--disk", ""]) }
        #expect(SandboxWorkDisk.absolutePath("FastSSD", directory: "/Volumes") == "/Volumes/FastSSD")
        #expect(SandboxWorkDisk.absolutePath("../Volumes/FastSSD", directory: "/Users") == "/Volumes/FastSSD")
        let help = Sandbox.Setup.helpMessage(columns: 1_000)
        #expect(help.contains("--disk <volume>"))
        #expect(help.contains("Work disks need add-on \(SandboxWorkDisk.minimumAddonVersion) or later."))
    }

    @Test("the plan and the install get each --disk in order; only an installer that names --disk takes them")
    func installerArguments() {
        let options = SandboxSetupOptions(linuxSlots: 1, disks: ["/Volumes/FastSSD", "/Users/ada"])
        let disks = ["--disk", "/Volumes/FastSSD", "--disk", "/Users/ada"]
        #expect(SandboxInstaller.planArguments(options) == ["--plan", "--json-progress", "--linux-slots", "1"] + disks)
        #expect(SandboxInstaller.arguments(options, jsonProgress: true)
            == ["--json-progress", "--yes", "--linux-slots", "1"] + disks)
        #expect(SandboxInstaller.supportsDisks(Data(FakeSandboxInstaller.script(workDisks: true).utf8)))
        #expect(!SandboxInstaller.supportsDisks(Data(FakeSandboxInstaller.script(plan: []).utf8)))
    }

    @Test("an installed add-on that reports its disks takes --disk; one without the member does not")
    func addonSupport() {
        #expect(SandboxFixtures.status(Self.statusWithDisks).supportsWorkDisks)
        #expect(!SandboxFixtures.status(SandboxFixtures.ready).supportsWorkDisks)
        #expect(!SandboxFixtures.status(SandboxFixtures.minimal).supportsWorkDisks)
    }

    @Test("a set-up Mac given --disk runs the installer again to apply the disks")
    func rerunPlan() {
        let json = SandboxFixtures.ready
        let query = SandboxAddonQuery.status(SandboxFixtures.status(json), json: json)
        #expect(SandboxSetupPlan.decide(query, changingSlots: false, changingDisks: true)
            == .rerun("Applying the new work disks."))
        #expect(SandboxSetupPlan.decide(query, changingSlots: true, changingDisks: true)
            == .rerun("Applying the new slot counts and work disks."))
        #expect(SandboxSetupPlan.decide(query, changingSlots: false, changingDisks: false)
            == .alreadySetUp(SandboxFixtures.status(json)))
    }

    // MARK: - The drive check

    @Test("an APFS drive with ownership on passes; each other drive fails with its exact fix")
    func check() {
        #expect(SandboxWorkDisk.check(path: "/Volumes/FastSSD", volume: Self.ready) == .init(
            level: .pass, name: "Work disk", detail: "/Volumes/FastSSD: APFS, ownership on"))
        let home = SandboxWorkDisk.Volume(mountPoint: "/System/Volumes/Data", fileSystem: "apfs", ignoresOwnership: false)
        #expect(SandboxWorkDisk.check(path: "/Users/ada", volume: home).detail
            == "/Users/ada (on /System/Volumes/Data): APFS, ownership on")
        let ownership = SandboxWorkDisk.check(path: "/Volumes/FastSSD", volume: Self.ownershipOff)
        #expect(ownership.level == .fail)
        #expect(ownership.fix == Self.enableOwnership)
        let spaced = SandboxWorkDisk.Volume(mountPoint: "/Volumes/Fast SSD's", fileSystem: "apfs", ignoresOwnership: true)
        #expect(SandboxWorkDisk.check(path: "/Volumes/Fast SSD's", volume: spaced).fix
            == #"sudo diskutil enableOwnership '/Volumes/Fast SSD'\''s'"#)
        let exFAT = SandboxWorkDisk.Volume(mountPoint: "/Volumes/FastSSD", fileSystem: "exfat", ignoresOwnership: true)
        let format = SandboxWorkDisk.check(path: "/Volumes/FastSSD", volume: exFAT)
        #expect(format.level == .fail && format.detail == "/Volumes/FastSSD is exfat, not APFS")
        #expect(format.fix?.contains("erase the drive as APFS in Disk Utility") == true)
        // Unplugged: /Volumes/FastSSD resolves to the internal disk.
        let unplugged = SandboxWorkDisk.check(path: "/Volumes/FastSSD/sandbox", volume: home)
        #expect(unplugged.level == .fail && unplugged.detail == "/Volumes/FastSSD is not a mounted drive")
        #expect(SandboxWorkDisk.check(path: "/Volumes/FastSSD", volume: nil).level == .fail)
    }

    @Test("statfs: the temporary directory's volume, and a drive that is not there")
    func liveVolume() throws {
        let temporary = SandboxWorkDisk.absolutePath(NSTemporaryDirectory())
        let volume = try #require(SandboxWorkDisk.volume(at: temporary))
        #expect(!volume.mountPoint.isEmpty && !volume.fileSystem.isEmpty)
        let missing = "/Volumes/no-such-drive-\(UUID().uuidString)"
        #expect(SandboxWorkDisk.check(path: missing, volume: SandboxWorkDisk.volume(at: missing)).detail
            == "\(missing) is not a mounted drive")
    }

    @Test("the plan shows each work disk and the jobs placed on it; the internal disk alone shows none")
    func planDisks() throws {
        let plan = try #require(SandboxSizingPlan(line: Self.externalPlan))
        #expect(plan.disks == [.init(path: "/Volumes/FastSSD", rootVolume: false, freeBytes: 900 << 30,
                                     floorBytes: 93 << 30, linuxSlots: 2, macOSSlots: 1)])
        #expect(plan.checks.map(\.name) == ["CPU", "Memory", "Disk", "Work disk"])
        #expect(plan.checks.last == .init(level: .info, name: "Work disk", detail:
            "/Volumes/FastSSD: 900 GiB free; 93 GiB stays free; 2 Linux jobs, 1 macOS job"))
        let internalOnly = try #require(SandboxSizingPlan(line: FakeSandboxInstaller.plan(
            extra: #","disks":[{"path":"/System/Volumes/Data","root_volume":true,"free_bytes":1,"floor_bytes":1}]"#)))
        #expect(internalOnly.checks.count == 3)
    }

    // MARK: - Setup

    static let statusWithDisks = SandboxFixtures.ready.replacingOccurrences(
        of: #"{"accepting""#, with: #"{"disks":[{"path":"/System/Volumes/Data","state":"online"}],"accepting""#)

    @Test("ownership off: setup prints the one-line diskutil command and stops before downloading anything")
    func ownershipOff() async throws {
        let result = try await #require(processExitsWith: .failure, observing: [\.standardOutputContent]) {
            _ = try CLICommandSandbox.enter(autoRestart: false)
            await exitWithCommandStatus {
                defer { print("requests \(CoordinatorStub.requests.count)") }
                try await SandboxSetupFlow(
                    options: SandboxSetupOptions(server: "https://sandbox.invalid", disks: ["/Volumes/FastSSD"]),
                    confirmed: true, addon: .live(), interactiveInput: false, terminal: false, color: false,
                    probe: { _ in .mac(cores: 16, memoryGiB: 128) },
                    workDiskVolume: { _ in Self.ownershipOff }).run()
            }
        }
        #expect(decodedText(result.standardOutputContent).hasSuffix("""
              [PASS] Sleep: off on the power adapter
              [FAIL] Work disk: /Volumes/FastSSD ignores file ownership; turning it on needs an administrator, so \
            run this yourself, then run setup again
                     ↳ fix: \(Self.enableOwnership)

            A work disk is not ready: follow the fix above, then run setup again. Nothing changed.
            requests 0

            """))
    }

    @Test("an installer whose release has no work disks: setup names the add-on version and installs nothing")
    func releaseWithoutDisks() async throws {
        let result = try await #require(processExitsWith: .failure,
                                        observing: [\.standardOutputContent, \.standardErrorContent]) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            CoordinatorStub.install(["/install.sh": .init(status: 200, body: Data(FakeSandboxInstaller.script(
                plan: [FakeSandboxInstaller.plan()]).utf8))])
            await exitWithCommandStatus {
                defer {
                    let root = sandbox.sandboxAddonRoot
                    print("planned \(FileManager.default.fileExists(atPath: root.appendingPathComponent("plan-arguments").path))")
                }
                try await SandboxSetupFlow(
                    options: SandboxSetupOptions(server: "https://sandbox.invalid", disks: ["/Volumes/FastSSD"]),
                    confirmed: true, addon: .live(), interactiveInput: false, terminal: false, color: false,
                    probe: { _ in .mac(cores: 16, memoryGiB: 128) }, workDiskVolume: { _ in Self.ready }).run()
            }
        }
        #expect(decodedText(result.standardOutputContent).hasSuffix(
            "  [PASS] Work disk: /Volumes/FastSSD: APFS, ownership on\nplanned false\n"))
        #expect(decodedText(result.standardErrorContent).contains(
            "The add-on release that https://sandbox.invalid offers does not support --disk: work disks need add-on "
                + "\(SandboxWorkDisk.minimumAddonVersion) or later. Nothing changed."))
    }

    @Test("--disk reaches the plan and the install, and the plan shows the jobs on each disk")
    func firstSetupWithDisk() async throws {
        let result = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            defer { sandbox.remove() }
            CoordinatorStub.install(["/install.sh": .init(status: 200, body: Data(FakeSandboxInstaller.script(
                plan: [Self.externalPlan], workDisks: true).utf8))])
            try await SandboxSetupFlow(
                options: SandboxSetupOptions(server: "https://sandbox.invalid", disks: ["/Volumes/FastSSD"]),
                confirmed: true, addon: .live(), interactiveInput: false, terminal: false, color: false,
                probe: { _ in .mac(cores: 16, memoryGiB: 128) }, workDiskVolume: { _ in Self.ready }).run()
            for (marker, file) in [("== PLAN", "plan-arguments"), ("== INSTALL", "installer-arguments")] {
                print(marker)
                print(try String(contentsOf: sandbox.sandboxAddonRoot.appendingPathComponent(file), encoding: .utf8),
                      terminator: "")
            }
        }
        let output = decodedText(result.standardOutputContent)
        #expect(output.contains("  [PASS] Sleep: off on the power adapter\n"
            + "  [PASS] Work disk: /Volumes/FastSSD: APFS, ownership on\n"))
        #expect(output.contains("macOS images 46 GiB + 40 GiB per macOS job\n"
            + "  [INFO] Work disk: /Volumes/FastSSD: 900 GiB free; 93 GiB stays free; 2 Linux jobs, 1 macOS job\n"))
        #expect(output.hasSuffix("== PLAN\n--plan\n--json-progress\n--disk\n/Volumes/FastSSD\n"
            + "== INSTALL\n--json-progress\n--yes\n--disk\n/Volumes/FastSSD\n"))
    }

    /// The installer's refusal of a disk in its plan, on stderr.
    static let planRefusal = "error: /Volumes/FastSSD is a disk image; use a drive"

    @Test("a work disk the installer refuses in its plan: setup shows the installer's fix and keeps its exit status")
    func planRefusesDisk() async throws {
        let result = try await #require(processExitsWith: .exitCode(2), observing: [\.standardOutputContent]) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            CoordinatorStub.install(["/install.sh": .init(status: 200, body: Data(FakeSandboxInstaller.script(
                plan: [], planExitStatus: 2, planStandardError: Self.planRefusal, workDisks: true).utf8))])
            await exitWithCommandStatus {
                defer {
                    let installed = sandbox.sandboxAddonRoot.appendingPathComponent("installer-arguments")
                    print("installed \(FileManager.default.fileExists(atPath: installed.path))")
                }
                try await SandboxSetupFlow(
                    options: SandboxSetupOptions(server: "https://sandbox.invalid", disks: ["/Volumes/FastSSD"]),
                    confirmed: true, addon: .live(), interactiveInput: false, terminal: false, color: false,
                    probe: { _ in .mac(cores: 16, memoryGiB: 128) }, workDiskVolume: { _ in Self.ready }).run()
            }
        }
        #expect(decodedText(result.standardOutputContent).hasSuffix("""
              [PASS] Work disk: /Volumes/FastSSD: APFS, ownership on

              \(Self.planRefusal)
            The installer's plan failed with these work disks; fix what it says above, then run setup again. \
            Nothing changed.
            installed false

            """))
    }

    @Test("a set-up Mac given --disk checks the drive, then runs the installer with it")
    func rerunWithDisk() async throws {
        let result = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            defer { sandbox.remove() }
            try FakeSandboxAddon.install(.current(status: Self.statusWithDisks), at: sandbox.sandboxAddonRoot)
            CoordinatorStub.install(["/install.sh": .init(status: 200, body: Data(FakeSandboxInstaller.script(
                plan: [Self.externalPlan], addonStatus: Self.statusWithDisks, workDisks: true).utf8))])
            try await SandboxSetupFlow(
                options: SandboxSetupOptions(server: "https://sandbox.invalid", disks: ["/Volumes/FastSSD"]),
                confirmed: false, addon: .live(), interactiveInput: false, terminal: false, color: false,
                workDiskVolume: { _ in Self.ready }).run()
            print("== INSTALL")
            print(try String(contentsOf: sandbox.sandboxAddonRoot.appendingPathComponent("installer-arguments"),
                             encoding: .utf8), terminator: "")
        }
        let output = decodedText(result.standardOutputContent)
        #expect(output.hasPrefix("""
            Applying the new work disks.

            Checking the work disks
              [PASS] Work disk: /Volumes/FastSSD: APFS, ownership on

            """))
        #expect(output.hasSuffix("== INSTALL\n--json-progress\n--yes\n--disk\n/Volumes/FastSSD\n"))
    }

    @Test("a set-up Mac offers --disk only when its add-on takes it")
    func hint() async throws {
        let diskHint = "To put the VM images and jobs on an external drive: darkbloom sandbox setup --disk /Volumes/<name>"
        for (status, offered) in [(Self.statusWithDisks, true), (SandboxFixtures.ready, false)] {
            let result = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) {
                [status = status as String] in
                let sandbox = try CLICommandSandbox.enter(autoRestart: false)
                defer { sandbox.remove() }
                try FakeSandboxAddon.install(.current(status: status), at: sandbox.sandboxAddonRoot)
                // No installer to download: the report and its hints only.
                try await SandboxSetupFlow(options: SandboxSetupOptions(server: "https://sandbox.invalid"),
                                           confirmed: false, addon: .live(), interactiveInput: false,
                                           terminal: false, color: false).run()
            }
            let output = decodedText(result.standardOutputContent)
            #expect(output.contains("--linux-slots <n> --macos-slots <n>\n"
                + (offered ? diskHint + "\n" : "") + "Could not check"), "\(offered)")
        }
    }
}
