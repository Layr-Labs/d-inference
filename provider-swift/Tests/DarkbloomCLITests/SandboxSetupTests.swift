import ArgumentParser
import Foundation
import ProviderCore
import Testing

@testable import darkbloom

@Suite("darkbloom sandbox setup")
struct SandboxSetupTests {
    // MARK: - Arguments

    @Test("setup parses every option and refuses bad ones")
    func parsing() throws {
        let setup = try #require(try Darkbloom.parseAsRoot([
            "sandbox", "setup", "--yes", "--no-browser", "--linux-slots", "2", "--macos-slots", "1",
            "--wait-ready", "--server", "https://sandbox.example/",
        ]) as? Sandbox.Setup)
        #expect(setup.options == SandboxSetupOptions(server: "https://sandbox.example/", noBrowser: true,
                                                     waitReady: true, linuxSlots: 2, macOSSlots: 1))
        #expect(setup.yes)
        let defaults = try Sandbox.Setup.parse([])
        #expect(defaults.options == SandboxSetupOptions() && !defaults.yes)
        #expect(defaults.server == "https://api-sandbox.darkbloom.dev")
        for invalid in [["--server", "http://sandbox.example"], ["--server", "sandbox.example"],
                        ["--server", "https://sandbox.example/?x=1"], ["--linux-slots", "17"],
                        ["--macos-slots", "3"], ["--linux-slots", "0", "--macos-slots", "0"]] {
            #expect(throws: (any Error).self, "\(invalid)") { try Sandbox.Setup.parse(invalid) }
        }
        #expect(try Darkbloom.parseAsRoot(["sandbox"]) is Sandbox)
        #expect(try Darkbloom.parseAsRoot(["sandbox", "status", "--json"]) is Sandbox.Status)
        #expect(try Darkbloom.parseAsRoot(["sandbox", "pause"]) is Sandbox.Pause)
        #expect(try Darkbloom.parseAsRoot(["sandbox", "resume"]) is Sandbox.Resume)
        #expect(try #require(try Darkbloom.parseAsRoot(["sandbox", "uninstall", "-y"]) as? Sandbox.Uninstall).yes)
        // Inference enrollment keeps its own command.
        #expect(try Darkbloom.parseAsRoot(["enroll"]) is Enroll)
    }

    @Test("sandbox help says what sandboxes are and links the docs")
    func help() {
        let help = Darkbloom.helpMessage(for: Sandbox.self, columns: 1_000)
        #expect(help.contains("Darkbloom Sandbox runs approved GitHub Actions jobs in isolated Linux and macOS "
            + "virtual machines on this Mac, pausing inference while a job runs and paying each job's price "
            + "minus a 10% fee into your Darkbloom balance."))
        #expect(help.contains("Docs: \(Sandbox.docsURL)"))
        for subcommand in ["setup", "status", "pause", "resume", "logs", "uninstall"] {
            #expect(help.contains("\n  \(subcommand) "), "\(subcommand)")
        }
    }

    // MARK: - Installer download

    @Test("the installer comes only from an https service")
    func scriptURL() {
        #expect(SandboxInstaller.scriptURL(server: "https://api-sandbox.darkbloom.dev")?.absoluteString
            == "https://api-sandbox.darkbloom.dev/install.sh")
        #expect(SandboxInstaller.scriptURL(server: "https://api-sandbox.darkbloom.dev/")?.absoluteString
            == "https://api-sandbox.darkbloom.dev/install.sh")
        #expect(SandboxInstaller.scriptURL(server: "HTTPS://example.com/sandbox//")?.absoluteString
            == "HTTPS://example.com/sandbox/install.sh")
        for refused in ["http://api-sandbox.darkbloom.dev", "https://", "file:///tmp/install.sh",
                        "https://user:pw@example.com", "https://example.com/#x", "https://example.com/?a=b", ""] {
            #expect(SandboxInstaller.scriptURL(server: refused) == nil, "\(refused)")
        }
    }

    @Test("only a 200 https response carrying a shell script is accepted")
    func validation() throws {
        let url = try #require(URL(string: "https://sandbox.example/install.sh"))
        func response(_ status: Int, _ final: String = "https://sandbox.example/install.sh") -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: final)!, statusCode: status, httpVersion: nil, headerFields: nil)!
        }
        let script = Data("#!/bin/sh\necho hi\n".utf8)
        #expect(try SandboxInstaller.validate(script, response: response(200), from: url) == script)
        let cases: [(Data, URLResponse, String)] = [
            (script, response(404), "HTTP 404"),
            (script, response(302), "it redirected to a location that is not https"),
            (script, response(200, "http://sandbox.example/install.sh"), "the response did not come over https"),
            (Data("<html>".utf8), response(200), "the response is not a shell script"),
            (Data("#!/usr/bin/env python3\n".utf8), response(200), "the response is not a shell script"),
            (Data(count: SandboxInstaller.maximumScriptBytes + 1), response(200), "the response is too large"),
            (script, URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil),
             "no HTTP response"),
        ]
        for (data, response, reason) in cases {
            #expect(throws: SandboxInstaller.Failure.download(url, reason)) {
                try SandboxInstaller.validate(data, response: response, from: url)
            }
        }
        #expect(SandboxInstaller.Failure.download(url, "HTTP 404").description
            == "Could not download the Darkbloom Sandbox installer from https://sandbox.example/install.sh: HTTP 404.")
    }

    @Test("a body over 1 MiB is refused from its announced size, before it is read")
    func downloadLimit() async throws {
        let result = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) {
            _ = try CLICommandSandbox.enter(autoRestart: false)
            let url = try #require(URL(string: "https://sandbox.invalid/install.sh"))
            var large = Data("#!/bin/sh\n".utf8)
            large.append(Data(repeating: 0x23, count: SandboxInstaller.maximumScriptBytes))
            CoordinatorStub.install(["/install.sh": .init(status: 200, body: large)])
            do {
                _ = try await SandboxInstaller.download(url)
                print("large: accepted")
            } catch {
                print("large: \(error)")
            }
            CoordinatorStub.install(["/install.sh": .init(status: 200, body: Data("#!/bin/sh\necho ok\n".utf8))])
            print("small: \(try await SandboxInstaller.download(url).count) bytes")
        }
        let output = decodedText(result.standardOutputContent)
        #expect(output.contains("large: Could not download the Darkbloom Sandbox installer from "
            + "https://sandbox.invalid/install.sh: the response is too large.\n"))
        #expect(output.hasSuffix("small: 18 bytes\n"))
    }

    @Test("an installer that knows --json-progress gets every option; an older one only the slots")
    func installerArguments() {
        let options = SandboxSetupOptions(noBrowser: true, waitReady: true, linuxSlots: 1, macOSSlots: 0)
        #expect(SandboxInstaller.arguments(options, jsonProgress: true)
            == ["--json-progress", "--yes", "--no-browser", "--wait-ready", "--linux-slots", "1", "--macos-slots", "0"])
        #expect(SandboxInstaller.arguments(options, jsonProgress: false) == ["--linux-slots", "1", "--macos-slots", "0"])
        #expect(SandboxInstaller.arguments(SandboxSetupOptions(), jsonProgress: true) == ["--json-progress", "--yes"])
        #expect(SandboxInstaller.supportsJSONProgress(Data(FakeSandboxInstaller.script().utf8)))
        #expect(!SandboxInstaller.supportsJSONProgress(Data(FakeSandboxInstaller.script(jsonProgress: false).utf8)))
        // The plan gets the owner's slot counts and no --yes.
        #expect(SandboxInstaller.planArguments(options) == ["--plan", "--json-progress", "--linux-slots", "1",
                                                            "--macos-slots", "0"])
        #expect(SandboxInstaller.planArguments(SandboxSetupOptions(noBrowser: true)) == ["--plan", "--json-progress"])
        #expect(SandboxInstaller.supportsPlan(Data(FakeSandboxInstaller.script(plan: []).utf8)))
        #expect(!SandboxInstaller.supportsPlan(Data(FakeSandboxInstaller.script().utf8)))
    }

    @Test("the staged script is owner-only")
    func staging() throws {
        let file = try SandboxInstaller.stage(Data("#!/bin/sh\n".utf8))
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let directory = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)
        let script = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((directory[.posixPermissions] as? Int) == 0o700)
        #expect((script[.posixPermissions] as? Int) == 0o600)
        #expect(try Data(contentsOf: file) == Data("#!/bin/sh\n".utf8))
    }

    // MARK: - Progress events

    @Test("installer events decode as add-on 1.0.1 writes them; anything else is shown as text")
    func events() throws {
        let started = try #require(SandboxInstallerEvent(json: FakeSandboxInstaller.events[2]))
        #expect(started.kind == .stage && started.stage == "verifying_release" && started.status == .started)
        #expect(started.message == "Verifying release")
        let approval = try #require(SandboxInstallerEvent(json: FakeSandboxInstaller.events[8]))
        #expect(approval.status == .progress && approval.userCode == "WDJB-MJHT" && approval.browserOpened == false)
        #expect(approval.verificationURI == "https://api-sandbox.darkbloom.dev/device")
        #expect(approval.verificationURIComplete == "https://api-sandbox.darkbloom.dev/device?code=WDJB-MJHT")
        let summary = try #require(SandboxInstallerEvent(json: FakeSandboxInstaller.events.last!))
        #expect(summary.kind == .summary && summary.hostID == SandboxFixtures.host)
        #expect(summary.linuxSlots == .init(count: 1, automatic: true, limit: "cores"))
        #expect(summary.consoleURL == "https://api-sandbox.darkbloom.dev/macs/\(SandboxFixtures.host)")
        let failed = try #require(SandboxInstallerEvent(json: FakeSandboxInstaller.stage(
            "waiting_for_approval", "failed", "the owner denied the request", #""exit_code":3"#)))
        #expect(failed.status == .failed && failed.exitCode == 3)
        let download = try #require(SandboxInstallerEvent(json: FakeSandboxInstaller.stage(
            "downloading_images", "progress", "Downloading", #""platform":null,"progress":1.7"#)))
        #expect(download.progress == 1)
        #expect(SandboxInstallerEvent(json: #"{"event":"stage","stage":"x","status":"later"}"#)?.status == .other("later"))
        #expect(SandboxInstallerEvent(json: #"{"event":"heartbeat"}"#)?.kind == .other("heartbeat"))
        #expect(SandboxInstallerOutput(line: "==> Downloading the latest release") == .text("==> Downloading the latest release"))
        #expect(SandboxInstallerOutput(line: #"{"no":"event"}"#) == .text(#"{"no":"event"}"#))
        #expect(SandboxInstallerOutput(line: "   ") == nil)
        #expect(SandboxInstallerEvent.title(stage: "starting", message: "Starting the agent") == "Starting")
        #expect(SandboxInstallerEvent.title(stage: "vm_check", message: "Checking the VM runtime") == "Checking the VM runtime")
        #expect(SandboxInstallerEvent.title(stage: "vm_check", message: nil) == "Vm Check")
    }

    @Test("the approval and waitlist events say whether the wait goes on in the background; absent reads as no")
    func backgroundEvents() throws {
        for (background, parsed) in [(true, true), (false, false), (nil, false)] as [(Bool?, Bool)] {
            let approval = try #require(SandboxInstallerEvent(json: FakeSandboxInstaller.approval(background: background)))
            #expect(approval.userCode == "WDJB-MJHT" && approval.background == parsed, "\(String(describing: background))")
            let waitlist = try #require(SandboxInstallerEvent(json: FakeSandboxInstaller.waitlist(background: background)))
            #expect(waitlist.waitlisted && waitlist.background == parsed, "\(String(describing: background))")
        }
        // Add-on 1.0.1's approval event has no such member; a value that is not a boolean is no.
        #expect(try #require(SandboxInstallerEvent(json: FakeSandboxInstaller.events[8])).background == false)
        #expect(SandboxInstallerEvent(json: FakeSandboxInstaller.stage(
            "waiting_for_approval", "progress", "…", #""waitlisted":true,"background":"yes""#))?.background == false)
    }

    @Test("the plan event decodes as add-on 1.1.1 writes it; unknown members are ignored, schema 1 only")
    func planEvent() throws {
        let gib: Int64 = 1 << 30
        let plan = try #require(SandboxSizingPlan(line: FakeSandboxInstaller.plan()))
        #expect(plan == SandboxSizingPlan(
            message: "1 Linux slot",
            linux: .init(slots: 1, automatic: true, limit: "free disk space", imagesBytes: 4 * gib, slotBytes: 30 * gib),
            macOS: .init(slots: 0, automatic: true, limit: "free disk space", imagesBytes: 46 * gib, slotBytes: 40 * gib),
            freeBytes: 157 * gib, floorBytes: 100 * gib, cores: 16, coresKept: 4, memoryBytes: 128 * gib,
            memoryKeptBytes: 32 * gib, providerMemoryBytes: 32 * gib))
        #expect(SandboxSizingPlan(line: FakeSandboxInstaller.plan(linuxAutomatic: false))?.linux.automatic == false)
        #expect(SandboxSizingPlan(line: FakeSandboxInstaller.plan(
            extra: #","gpu_cores":40,"future":{"slots":[1,2]},"note":null"#)) == plan)
        let schema2 = FakeSandboxInstaller.plan().replacingOccurrences(of: #""schema":1"#, with: #""schema":2"#)
        #expect(SandboxSizingPlan(line: schema2) == nil)
        let unversioned = FakeSandboxInstaller.plan().replacingOccurrences(of: #""schema":1,"#, with: "")
        #expect(SandboxSizingPlan(line: unversioned) == nil)
        let summary = FakeSandboxInstaller.plan().replacingOccurrences(of: #""event":"plan""#, with: #""event":"summary""#)
        #expect(SandboxSizingPlan(line: summary) == nil)
        let missing = FakeSandboxInstaller.plan().replacingOccurrences(of: #""cores_kept":4,"#, with: "")
        #expect(SandboxSizingPlan(line: missing) == nil)
        #expect(SandboxSizingPlan(line: "==> 1 Linux slot") == nil)
    }

    @Test("the plan's lines: 157 GiB free of 1858 GiB runs 1 Linux job and no macOS job; none fits at 120 GiB")
    func planReport() throws {
        let plan = try #require(SandboxSizingPlan(line: FakeSandboxInstaller.plan()))
        #expect(plan.checks == [
            .init(level: .pass, name: "CPU", detail: "16 cores; you keep 4"),
            .init(level: .pass, name: "Memory", detail: "128 GB; you keep 32 GB, inference keeps 32 GB"),
            .init(level: .pass, name: "Disk", detail: "157 GiB free; 100 GiB stays free for you; Linux images 4 GiB "
                + "+ 30 GiB per Linux job; macOS images 46 GiB + 40 GiB per macOS job"),
        ])
        #expect(plan.verdict == [
            "Eligible. At a time, this Mac can run:",
            "  1 Linux job (limited by free disk space)",
            "  no macOS jobs (limited by free disk space)",
        ])
        let full = try #require(SandboxSizingPlan(line: FakeSandboxInstaller.plan(
            message: "No slot fits: 20 GiB free above the 100 GiB floor", linux: 0, freeGiB: 120)))
        #expect(full.verdict == [
            "Not eligible: No slot fits: 20 GiB free above the 100 GiB floor.",
            "  Free up 14 GiB of disk for one Linux job, or 66 GiB of disk for one macOS job.",
        ])
        #expect(full.checks.map(\.level) == [.pass, .pass, .fail])
    }

    /// The free-space note, with what one macOS job needs beside the plan's Linux slots.
    private static func freeSpaceNote(macOSNeeds more: Int?) -> String {
        "Free space here is what `df -h ~` shows as Avail; Finder also counts purgeable space, which macOS frees "
            + "only when it needs to (restarting, or removing Time Machine local snapshots: "
            + "`tmutil listlocalsnapshots /`, frees it now)."
            + (more.map { " A macOS job needs about \($0) GB more." } ?? "")
    }

    @Test("the free-space note appears only when the add-on gives macOS no job for want of disk")
    func freeSpaceNoteScope() throws {
        func plan(linux: Int = 1, macOS: Int = 0, limit: String = "free disk space",
                  freeGiB: Int64 = 157) throws -> SandboxSizingPlan {
            let line = FakeSandboxInstaller.plan(linux: linux, macOS: macOS, freeGiB: freeGiB)
                .replacingOccurrences(of: #""macos_limit":"free disk space""#, with: #""macos_limit":"\#(limit)""#)
            return try #require(SandboxSizingPlan(line: line))
        }
        // 100 GiB floor + 1 Linux job with its images (34) + macOS images and job (86) - 157 free.
        #expect(try plan().freeSpaceNote == Self.freeSpaceNote(macOSNeeds: 63))
        #expect(try plan(freeGiB: 200).freeSpaceNote == Self.freeSpaceNote(macOSNeeds: 20))
        // No job: one macOS job's disk alone, as the verdict's own line says.
        #expect(try plan(linux: 0, freeGiB: 120).freeSpaceNote == Self.freeSpaceNote(macOSNeeds: 66))
        // A plan whose numbers fit a macOS job anyway says no number.
        #expect(try plan(freeGiB: 400).freeSpaceNote == Self.freeSpaceNote(macOSNeeds: nil))
        for limit in ["cores", "memory", "your choice", "macOS's limit of 2 VMs, yours included"] {
            #expect(try plan(limit: limit).freeSpaceNote == nil, "\(limit)")
        }
        #expect(try plan(macOS: 1).freeSpaceNote == nil)
    }

    @Test("the feedback's Mac: 3 Linux slots and no macOS one for want of disk; the note counts the Linux slots")
    func freeSpaceNoteWithThreeLinuxSlots() throws {
        // 110 GiB above the floor: a lone macOS job (86) would fit, but the 3 Linux jobs and their images take 94.
        let plan = try #require(SandboxSizingPlan(line: FakeSandboxInstaller.plan(
            message: "3 Linux slots", linux: 3, freeGiB: 210)))
        #expect(plan.diskShortfall(plan.macOS) == 70 << 30)
        #expect(plan.freeSpaceNote == Self.freeSpaceNote(macOSNeeds: 70))
    }

    /// Each event as the renderer gets it.
    private static func render(_ lines: [String], interactive: Bool = false,
                               finish outcome: SandboxSetupRenderer.Outcome = .succeeded) -> String {
        let output = LineCollector()
        let renderer = SandboxSetupRenderer(interactive: interactive, color: false, width: { 80 },
                                            write: { output.append($0) })
        for line in lines {
            if let parsed = SandboxInstallerOutput(line: line) { renderer.handle(parsed) }
            if interactive { renderer.tick() }
        }
        renderer.finish(outcome)
        return output.all.joined()
    }

    @Test("off a terminal each stage prints once it ends, with its results; the approval link prints at once")
    func transcript() {
        #expect(Self.render(FakeSandboxInstaller.events) == """
              ✓ Checking this Mac
                Apple M4 Max, 16 cores, 128 GB memory, macOS 27.0.1; logged in as ada
              ✓ Verifying release
                Downloaded 1.0.1 from https://api-sandbox.darkbloom.dev: the archive matches its manifest, the app is Darkbloom's (team SLDQ2GJ6TL)
                Darkbloom Sandbox 1.0.1, signed by Darkbloom (Developer ID team SLDQ2GJ6TL); the release's signature checks out
              ✓ Installing
                ~/DarkbloomSandbox: 1 Linux slot and 1 macOS slot

                Approve this Mac in your browser, signed in to the Darkbloom account that should own it:
                  https://api-sandbox.darkbloom.dev/device?code=WDJB-MJHT
                Code: WDJB-MJHT. Check the Mac shown, then press Approve; the CLI cannot approve for you.
                Open the link in a browser on any device.
                Earnings for jobs on this Mac go to the account that approves it.

              ✓ Waiting for approval
                Approved after 0:42
              ✓ Enrolled
                Host 0b7d4e2a-91c3-4f6e-8a25-7c1d3e9f4b60; App Attest verified this app
              ✓ Starting
                Connected to https://api-sandbox.darkbloom.dev
              ✓ Downloading images
                In the background (about 13 GB for Linux and 42 GB for macOS)
              ✓ Ready
                Not yet: this Mac takes jobs once its first image is installed

            """)
    }

    @Test("--wait-ready download progress prints every tenth; an opened browser and the waitlist are said so")
    func waitingStages() {
        let stage = FakeSandboxInstaller.stage
        let transcript = Self.render([
            stage("waiting_for_approval", "started", "Waiting for approval", ""),
            stage("waiting_for_approval", "progress", "Opened…",
                  #""browser_opened":true,"user_code":"WDJB-MJHT","verification_uri":"https://s.example/device","verification_uri_complete":null"#),
            stage("waiting_for_approval", "progress", "Your account is on the waitlist…", #""waitlisted":true"#),
            stage("waiting_for_approval", "done", "Approved after 2:01:13", ""),
            stage("downloading_images", "started", "Downloading images", ""),
            stage("downloading_images", "progress", "Downloading its linux image: 5% 0:01", #""platform":"linux","progress":0.05"#),
            stage("downloading_images", "progress", "Downloading its linux image: 42% 0:09", #""platform":"linux","progress":0.42"#),
            stage("downloading_images", "progress", "Downloading its linux image: 47% 0:10", #""platform":"linux","progress":0.47"#),
            stage("downloading_images", "progress", "Downloading its linux image: 100% 0:21", #""platform":"linux","progress":1"#),
            stage("downloading_images", "done", "Installed: linux; the rest in the background", #""installed":["linux"]"#),
        ])
        #expect(transcript == """

                Approve this Mac in your browser, signed in to the Darkbloom account that should own it:
                  https://s.example/device
                Code: WDJB-MJHT. Check the Mac shown, then press Approve; the CLI cannot approve for you.
                Your browser opened this page. If it didn't, open the link yourself.
                Earnings for jobs on this Mac go to the account that approves it.


                Your account is on the waitlist: Darkbloom reviews new Mac owners before their first Mac joins.
                Leave this running, or press Ctrl-C and run `darkbloom sandbox setup` again later; this Mac enrolls once your account is approved.

              ✓ Waiting for approval
                Approved after 2:01:13
                Downloading images 5%
                Downloading images 42%
              ✓ Downloading images
                Installed: linux; the rest in the background

            """)
        // On a terminal the running line says what it waits for.
        let live = Self.render([
            stage("waiting_for_approval", "started", "Waiting for approval", ""),
            stage("waiting_for_approval", "progress", "…", #""waitlisted":true"#),
        ], interactive: true, finish: .interrupted)
        #expect(live.contains("  ⠙ Waiting for Darkbloom to approve your account"))
        #expect(live.hasSuffix("\r\u{1B}[2K  ✗ Waiting for approval (stopped)\n"))
    }

    @Test("the waitlist says the window may close when the add-on waits in the background, else to leave it running")
    func backgroundWaitlist() {
        let started = FakeSandboxInstaller.stage("waiting_for_approval", "started", "Waiting for approval")
        /// What follows the approval block, `background` as each event says.
        func afterApproval(approval: Bool?, waitlist: Bool?) -> String {
            Self.render([started, FakeSandboxInstaller.approval(background: approval),
                         FakeSandboxInstaller.waitlist(background: waitlist)], finish: .interrupted)
                .components(separatedBy: "approves it.\n\n").last ?? ""
        }
        let closeWindow = """

                Your account is on the waitlist: Darkbloom reviews new Mac owners before their first Mac joins.
                You can close this window: this Mac keeps waiting, also across restarts, and enrolls by itself \
            once your account is approved. `darkbloom sandbox status` shows where it is.

              ✗ Waiting for approval (stopped)

            """
        // `background` on the approval or on the waitlist event is enough.
        #expect(afterApproval(approval: true, waitlist: true) == closeWindow)
        #expect(afterApproval(approval: true, waitlist: nil) == closeWindow)
        #expect(afterApproval(approval: nil, waitlist: true) == closeWindow)
        let leaveRunning = """

                Your account is on the waitlist: Darkbloom reviews new Mac owners before their first Mac joins.
                Leave this running, or press Ctrl-C and run `darkbloom sandbox setup` again later; this Mac enrolls \
            once your account is approved.

              ✗ Waiting for approval (stopped)

            """
        #expect(afterApproval(approval: false, waitlist: false) == leaveRunning)
        #expect(afterApproval(approval: nil, waitlist: nil) == leaveRunning)
    }

    @Test("a background approval or waitlist event means this Mac waits in the background until it enrolls")
    func waitsInBackground() {
        func waits(_ lines: [String]) -> Bool {
            let renderer = SandboxSetupRenderer(interactive: false, color: false, width: { 80 }, write: { _ in })
            lines.compactMap(SandboxInstallerOutput.init(line:)).forEach(renderer.handle)
            return renderer.waitsInBackground
        }
        let stage = FakeSandboxInstaller.stage
        let started = stage("waiting_for_approval", "started", "Waiting for approval", "")
        #expect(waits([started, FakeSandboxInstaller.approval(background: true)]))
        #expect(waits([started, FakeSandboxInstaller.approval(), FakeSandboxInstaller.waitlist(background: true)]))
        #expect(!waits([started, FakeSandboxInstaller.approval(background: false),
                        FakeSandboxInstaller.waitlist(background: false)]))
        #expect(!waits(FakeSandboxInstaller.events))
        // Another event's `background` says nothing about the approval.
        #expect(!waits([stage("starting", "progress", "Still connecting", #""background":true"#)]))
        // App Attest after the approval still waits in the background; once enrolled, nothing does.
        let approved = [started, FakeSandboxInstaller.approval(background: true),
                        stage("waiting_for_approval", "done", "Approved after 0:42", ""),
                        stage("enrolled", "started", "Enrolled", "")]
        #expect(waits(approved))
        #expect(waits(approved + [stage("enrolled", "failed", "App Attest did not complete yet", #""exit_code":1"#)]))
        #expect(!waits(approved + [stage("enrolled", "done", "Host 0b7d4e2a; App Attest verified this app", "")]))
    }

    @Test("on a terminal the running stage is a spinner line that turns into a check mark")
    func interactive() {
        let transcript = Self.render(Array(FakeSandboxInstaller.events[0..<3]), interactive: true)
        #expect(transcript == "  ⠋ Checking this Mac"
            + "\r\u{1B}[2K  ⠙ Checking this Mac"
            + "\r\u{1B}[2K  ✓ Checking this Mac\n    Apple M4 Max, 16 cores, 128 GB memory, macOS 27.0.1; logged in as ada\n"
            + "  ⠹ Verifying release"
            + "\r\u{1B}[2K  ⠸ Verifying release"
            + "\r\u{1B}[2K  ✓ Verifying release\n")
    }

    @Test("a failed stage shows the installer's message once, then stderr lines that add something")
    func failures() {
        let stage = FakeSandboxInstaller.stage
        let message = "enrollment did not complete: the owner denied the request; run the installer again"
        #expect(Self.render([
            stage("waiting_for_approval", "started", "Waiting for approval", ""),
            stage("waiting_for_approval", "failed", message, #""exit_code":3"#),
        ], finish: .failed(status: 3, errors: ["error: \(message)", "see ~/DarkbloomSandbox/agent/enroll.log"])) == """
              ✗ Waiting for approval
                \(message)
                see ~/DarkbloomSandbox/agent/enroll.log

            """)
        #expect(Self.render([stage("checking_mac", "started", "Checking this Mac", "")],
                            finish: .failed(status: 1, errors: ["boom"])) == "  ✗ Checking this Mac\n    boom\n")
        #expect(Self.render([], finish: .failed(status: 3, errors: []))
            == "  ✗ Setup failed\n    The installer exited with status 3.\n")
        #expect(Self.render([stage("installing", "started", "Installing", "")], finish: .interrupted)
            == "  ✗ Installing (stopped)\n")
    }

    @Test("each installer exit status gets its own next step; a stop says whether this Mac waits in the background")
    func advice() {
        func advice(_ status: Int32, signal: Int32? = nil, waitsInBackground: Bool = false) -> String {
            SandboxSetupFlow.advice(.init(status: status, signal: signal), waitsInBackground: waitsInBackground)
        }
        #expect(advice(2) == "This Mac cannot host Darkbloom Sandbox as it is; see why above.")
        #expect(advice(3).hasPrefix("This Mac was not enrolled: the code was denied or expired"))
        #expect(advice(4) == Self.jobRunningAdvice)
        #expect(advice(130) == "Setup stopped. An enrollment waiting for approval goes on; run "
            + "`darkbloom sandbox setup` again to follow it.")
        #expect(advice(2, signal: SIGINT) == advice(130))
        #expect(advice(1).hasPrefix("Setup did not finish."))
        #expect(advice(9, signal: SIGKILL).hasPrefix("Setup did not finish."))
        #expect(advice(130, waitsInBackground: true) == "Setup stopped. This Mac keeps waiting for approval in the "
            + "background, also across restarts, and enrolls by itself once approved; `darkbloom sandbox status` shows "
            + "where it is.")
        #expect(advice(2, signal: SIGINT, waitsInBackground: true) == advice(130, waitsInBackground: true))
        // Only a stop reads it: add-on 1.1.2 exits 1 while App Attest is retried after the approval.
        for status: Int32 in [1, 2, 3, 4] {
            #expect(advice(status, waitsInBackground: true) == advice(status), "\(status)")
        }
        #expect(advice(9, signal: SIGKILL, waitsInBackground: true) == advice(9, signal: SIGKILL))
    }

    // MARK: - Plan

    @Test("rerunning setup reports, continues, repairs or applies new slots, as the add-on's state needs")
    func plan() {
        func plan(_ json: String, changingSlots: Bool = false) -> SandboxSetupPlan {
            SandboxSetupPlan.decide(.status(SandboxFixtures.status(json), json: json), changingSlots: changingSlots)
        }
        #expect(SandboxSetupPlan.decide(.notInstalled, changingSlots: false) == .fresh)
        #expect(plan(SandboxFixtures.notInstalled) == .fresh)
        #expect(plan(SandboxFixtures.ready) == .alreadySetUp(SandboxFixtures.status(SandboxFixtures.ready)))
        #expect(plan(SandboxFixtures.paused) == .alreadySetUp(SandboxFixtures.status(SandboxFixtures.paused)))
        #expect(plan(SandboxFixtures.downloading) == .alreadySetUp(SandboxFixtures.status(SandboxFixtures.downloading)))
        #expect(plan(SandboxFixtures.ready, changingSlots: true) == .rerun("Applying the new slot counts."))
        #expect(plan(SandboxFixtures.waiting) == .rerun("Continuing the setup on this Mac (waiting for approval)."))
        #expect(plan(SandboxFixtures.error) == .rerun("The add-on reports an error: Not connected to the plane "
            + "(cannot reach the plane); it keeps trying. Running the installer again to repair it."))
        #expect(SandboxSetupPlan.decide(.outdated, changingSlots: false)
            == .rerun("Updating the add-on: this version is older than the CLI expects."))
        #expect(SandboxSetupPlan.decide(.unresponsive(seconds: 10), changingSlots: false)
            == .rerun("The add-on did not answer within 10 seconds; running the installer again to repair it."))
    }

    @Test("the summary names the state, the slots the installer chose and what to do next")
    func summary() throws {
        let installer = try #require(SandboxInstallerEvent(json: FakeSandboxInstaller.events.last!))
        let lines = SandboxSetupFlow.summary(SandboxFixtures.status(SandboxFixtures.downloading),
                                             installer: installer, server: "https://sandbox.example", color: false)
        #expect(lines == [
            "Darkbloom Sandbox is set up on this Mac: downloading images (Linux 42%)",
            "  Downloading its linux image: 42%",
            "  Jobs at a time: 1 Linux (automatic, limited by cores), 1 macOS (automatic, limited by cores)",
            "",
            "Next",
            "  darkbloom sandbox status    see jobs, slots and images",
            "  darkbloom sandbox pause     let running jobs finish and take no new ones",
            "  darkbloom sandbox logs -f   follow the add-on's log",
            "  Console: https://api-sandbox.darkbloom.dev/macs/\(SandboxFixtures.host) (jobs; earnings under Billing → Earnings)",
            "  Keep this Mac plugged in, awake and logged in.",
        ])
        let chosen = SandboxSetupFlow.summary(SandboxFixtures.status(SandboxFixtures.ready), server: "https://s", color: false)
        #expect(chosen[2] == "  Jobs at a time: 1 Linux, 1 macOS")
    }

    // MARK: - End to end

    /// The whole setup against a stubbed service and a fake installer: the
    /// installer is downloaded, staged, run with the owner's options, rendered
    /// and summarized; a second run only reports the state.
    @Test("setup checks, shows the add-on's plan, installs with progress, summarizes, and a rerun only reports")
    func endToEnd() async throws {
        let result = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            defer { sandbox.remove() }
            CoordinatorStub.install(["/install.sh": .init(status: 200, body: Data(FakeSandboxInstaller.script(
                plan: [FakeSandboxInstaller.plan(linuxAutomatic: false)]).utf8))])
            let first = SandboxSetupOptions(server: "https://sandbox.invalid", noBrowser: true, linuxSlots: 1)
            print("== FIRST")
            try await SandboxSetupFlow(options: first, confirmed: true, addon: .live(), interactiveInput: false,
                                       terminal: false, color: false,
                                       probe: { _ in .mac(cores: 16, memoryGiB: 128) }, waitlist: .approved).run()
            print("== PLAN")
            print(try String(contentsOf: sandbox.sandboxAddonRoot.appendingPathComponent("plan-arguments"),
                             encoding: .utf8), terminator: "")
            print("== INSTALL")
            print(try String(contentsOf: sandbox.sandboxAddonRoot.appendingPathComponent("installer-arguments"),
                             encoding: .utf8), terminator: "")
            print("requests \(CoordinatorStub.requests.map { $0.url?.absoluteString ?? "" })")
            print("== SECOND")
            try await SandboxSetupFlow(options: SandboxSetupOptions(server: "https://sandbox.invalid"),
                                       confirmed: false, addon: .live(), interactiveInput: false,
                                       terminal: false, color: false, waitlist: .approved).run()
            print("== END")
        }
        let output = decodedText(result.standardOutputContent)
        let first = try #require(outputSection(output, from: "== FIRST", to: "== PLAN"))
        // The sizing lines are the plan's (157 GiB free), not this Mac's probe (800 GiB).
        #expect(first.hasPrefix("""
            Darkbloom Sandbox setup

            Checking this Mac
              [PASS] Chip: Apple M4 Max
              [PASS] macOS: 27.0.1
              [PASS] Session: logged in at this Mac's desktop
              [PASS] Network: Ethernet
              [PASS] Power: power adapter
              [PASS] Sleep: off on the power adapter
              [PASS] CPU: 16 cores; you keep 4
              [PASS] Memory: 128 GB; you keep 32 GB, inference keeps 32 GB
              [PASS] Disk: 157 GiB free; 100 GiB stays free for you; Linux images 4 GiB + 30 GiB per Linux job; \
            macOS images 46 GiB + 40 GiB per macOS job

            Eligible. At a time, this Mac can run:
              1 Linux job (your choice)
              no macOS jobs (limited by free disk space)
              \(Self.freeSpaceNote(macOSNeeds: 63))

            What changes

            """))
        #expect(first.contains("\n\n" + Self.render(FakeSandboxInstaller.events) + """

            Darkbloom Sandbox is set up on this Mac: downloading images (Linux 42%)
              Downloading its linux image: 42%
              Jobs at a time: 1 Linux (automatic, limited by cores), 1 macOS (automatic, limited by cores)

            Next

            """))
        // The owner's slot counts reach the plan and the install; one download serves both.
        let plan = try #require(outputSection(output, from: "== PLAN", to: "== INSTALL"))
        #expect(plan == "--plan\n--json-progress\n--linux-slots\n1\n")
        let install = try #require(outputSection(output, from: "== INSTALL", to: "requests"))
        #expect(install == "--json-progress\n--yes\n--no-browser\n--linux-slots\n1\n")
        #expect(output.contains("requests [\"https://sandbox.invalid/install.sh\"]\n== SECOND"))
        // The rerun reports and asks the plan again (1 Linux, no macOS, against 1 + 1 installed);
        // without a prompt it does not remove a slot.
        let second = try #require(outputSection(output, from: "== SECOND", to: "== END"))
        #expect(second.hasPrefix("Darkbloom Sandbox is already set up on this Mac.\n\n"
            + "Darkbloom Sandbox 1.0.1: downloading images (Linux 42%)\n"))
        #expect(second.hasSuffix("""
            macOS images 46 GiB + 40 GiB per macOS job
              \(Self.freeSpaceNote(macOSNeeds: 63))

            This Mac now fits 1 Linux + 0 macOS (installed: 1 Linux + 1 macOS).
            Not applied: it removes slots, and without a prompt setup applies only a plan that adds slots. To apply \
            it: darkbloom sandbox setup --linux-slots 1 --macos-slots 0

            """))
    }

    // MARK: - Rerun on a Mac that is set up

    @Test("a slot change compares the plan with the installed totals; none without totals or without a job")
    func slotChange() throws {
        let plan = try #require(SandboxSizingPlan(line: FakeSandboxInstaller.plan(macOS: 1, freeGiB: 240)))
        let change = try #require(SandboxSlotChange(installed: SandboxFixtures.status(
            SandboxFixtures.ready(linux: 3, macOS: 0)), plan: plan))
        #expect(change == SandboxSlotChange(installedLinux: 3, installedMacOS: 0, plannedLinux: 1, plannedMacOS: 1))
        #expect(!change.onlyAdds)
        #expect(change.applying(to: SandboxSetupOptions(noBrowser: true))
            == SandboxSetupOptions(noBrowser: true, linuxSlots: 1, macOSSlots: 1))
        #expect(SandboxSlotChange(installedLinux: 1, installedMacOS: 0, plannedLinux: 1, plannedMacOS: 1).onlyAdds)
        #expect(SandboxSlotChange(installed: SandboxFixtures.status(SandboxFixtures.ready), plan: plan) == nil)
        #expect(SandboxSlotChange(installed: SandboxFixtures.status(SandboxFixtures.minimal), plan: plan) == nil)
        let none = try #require(SandboxSizingPlan(line: FakeSandboxInstaller.plan(linux: 0, freeGiB: 120)))
        #expect(SandboxSlotChange(installed: SandboxFixtures.status(SandboxFixtures.ready), plan: none) == nil)
        // An empty answer is yes only where yes is the default.
        #expect(SandboxTerminal.confirm("Apply?", defaultYes: true, readInput: { "" }, emit: { _ in }))
        #expect(!SandboxTerminal.confirm("Apply?", readInput: { "" }, emit: { _ in }))
        #expect(!SandboxTerminal.confirm("Apply?", defaultYes: true, readInput: { "n" }, emit: { _ in }))
    }

    /// Runs setup on a Mac with the add-on installed (`status`) against an
    /// installer whose plan prints `plan` (none: an installer without plan
    /// mode), answering `answer` at a prompt when given; an install prints
    /// `installerEvents` and exits with `installerExit`, which setup keeps.
    /// Prints the output, then `== PLAN` and `== INSTALL` with the arguments
    /// each run got.
    private static func rerun(status: String, plan: String?, answer: String? = nil, confirmed: Bool = false,
                              linuxSlots: Int? = nil, macOSSlots: Int? = nil,
                              installerEvents: [String] = FakeSandboxInstaller.events,
                              installerExit: Int32 = 0) async throws -> String {
        let expected: ExitTest.Condition = installerExit == 0 ? .success : .exitCode(installerExit)
        let result = try await #require(processExitsWith: expected, observing: [\.standardOutputContent]) {
            [status = status as String, plan = plan as String?, answer = answer as String?,
             confirmed = confirmed as Bool, linuxSlots = linuxSlots as Int?, macOSSlots = macOSSlots as Int?,
             installerEvents = installerEvents as [String], installerExit = installerExit as Int32] in
            let options = SandboxSetupOptions(server: "https://sandbox.invalid", linuxSlots: linuxSlots,
                                              macOSSlots: macOSSlots)
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            try FakeSandboxAddon.install(.current(status: status), at: sandbox.sandboxAddonRoot)
            CoordinatorStub.install(["/install.sh": .init(status: 200, body: Data(FakeSandboxInstaller.script(
                events: installerEvents, plan: plan.map { [$0] }, addonStatus: SandboxFixtures.ready(linux: 1, macOS: 1),
                exitStatus: installerExit).utf8))])
            if let answer { try replaceStandardInput(with: answer) }
            print("== EXPECTED")
            SandboxStatusView.lines(SandboxFixtures.status(status)).forEach { print($0) }
            print("== OUTPUT")
            await exitWithCommandStatus {
                defer {
                    for (marker, file) in [("== PLAN", "plan-arguments"), ("== INSTALL", "installer-arguments")] {
                        print(marker)
                        let url = sandbox.sandboxAddonRoot.appendingPathComponent(file)
                        print((try? String(contentsOf: url, encoding: .utf8)) ?? "none\n", terminator: "")
                    }
                    print("== END")
                    sandbox.remove()
                }
                try await SandboxSetupFlow(options: options, confirmed: confirmed, addon: .live(),
                                           interactiveInput: answer != nil, terminal: false, color: false, waitlist: .approved).run()
            }
        }
        return decodedText(result.standardOutputContent)
    }

    private static let changeHint = "To change how many jobs run at a time: darkbloom sandbox setup "
        + "--linux-slots <n> --macos-slots <n>\n"

    /// Today's report for `output`'s Mac: the state, then the slot options.
    private static func alreadySetUp(_ output: String) throws -> String {
        let status = try #require(outputSection(output, from: "== EXPECTED", to: "== OUTPUT"))
        return "Darkbloom Sandbox is already set up on this Mac.\n\n" + status + "\n" + changeHint
    }

    @Test("rerun with the plan the Mac runs: today's report, after the plan, changing nothing")
    func rerunSamePlan() async throws {
        let output = try await Self.rerun(status: SandboxFixtures.ready(linux: 1, macOS: 1),
                                          plan: FakeSandboxInstaller.plan(message: "1 Linux slot and 1 macOS slot",
                                                                          macOS: 1, freeGiB: 300))
        #expect(try outputSection(output, from: "== OUTPUT", to: "== PLAN") == Self.alreadySetUp(output))
        #expect(output.hasSuffix("== PLAN\n--plan\n--json-progress\n== INSTALL\nnone\n== END\n"))
    }

    @Test("rerun with the same plan, macOS short of disk: exactly today's report, without the free-space note")
    func rerunSamePlanShortOfDisk() async throws {
        // The feedback's Mac before it freed space: 3 Linux slots, macOS short of disk, as installed.
        let output = try await Self.rerun(status: SandboxFixtures.ready(linux: 3, macOS: 0),
                                          plan: FakeSandboxInstaller.plan(message: "3 Linux slots", linux: 3,
                                                                          freeGiB: 210))
        #expect(try outputSection(output, from: "== OUTPUT", to: "== PLAN") == Self.alreadySetUp(output))
        #expect(output.hasSuffix("== PLAN\n--plan\n--json-progress\n== INSTALL\nnone\n== END\n"))
    }

    /// The feedback's Mac: 3 Linux slots installed; with more free space the plan fits 1 Linux and 1 macOS.
    private static let macOSFits = FakeSandboxInstaller.plan(message: "1 Linux slot and 1 macOS slot", macOS: 1,
                                                             freeGiB: 240)

    @Test("rerun when the plan now fits macOS: it offers the plan; yes applies its counts, no changes nothing")
    func rerunOffersPlan() async throws {
        let offer = """
            The add-on's plan for this Mac now:
              [PASS] CPU: 16 cores; you keep 4
              [PASS] Memory: 128 GB; you keep 32 GB, inference keeps 32 GB
              [PASS] Disk: 240 GiB free; 100 GiB stays free for you; Linux images 4 GiB + 30 GiB per Linux job; \
            macOS images 46 GiB + 40 GiB per macOS job


            """ + "This Mac now fits 1 Linux + 1 macOS (installed: 3 Linux + 0 macOS). If a job is running, the "
            + "installer refuses and changes nothing. Apply? [Y/n]: "
        for answer in ["\n", "y\n"] {
            let output = try await Self.rerun(status: SandboxFixtures.ready(linux: 3, macOS: 0), plan: Self.macOSFits,
                                              answer: answer)
            let shown = try #require(outputSection(output, from: "== OUTPUT", to: "== PLAN"))
            let report = try Self.alreadySetUp(output).replacingOccurrences(of: Self.changeHint, with: "")
            #expect(shown.hasPrefix(report + offer + "\n"), "\(answer)")
            #expect(shown.contains("Darkbloom Sandbox is set up on this Mac: ready"))
            #expect(output.hasSuffix("== INSTALL\n--json-progress\n--yes\n--linux-slots\n1\n--macos-slots\n1\n== END\n"))
        }
        let declined = try await Self.rerun(status: SandboxFixtures.ready(linux: 3, macOS: 0), plan: Self.macOSFits,
                                            answer: "n\n")
        #expect(declined.contains(offer + "Nothing changed. To apply it later: darkbloom sandbox setup "
            + "--linux-slots 1 --macos-slots 1\n== PLAN"))
        #expect(declined.hasSuffix("== INSTALL\nnone\n== END\n"))
    }

    @Test("rerun without a prompt (--yes or no terminal): only a plan that adds slots and removes none is applied")
    func rerunUnattended() async throws {
        for confirmed in [true, false] {
            // 3 Linux + 0 macOS to 1 + 1 removes Linux slots: suggested, not applied.
            let removes = try await Self.rerun(status: SandboxFixtures.ready(linux: 3, macOS: 0), plan: Self.macOSFits,
                                               confirmed: confirmed)
            #expect(removes.contains("Not applied: it removes slots, and without a prompt setup applies only a plan "
                + "that adds slots. To apply it: darkbloom sandbox setup --linux-slots 1 --macos-slots 1\n== PLAN"))
            #expect(!removes.contains("[Y/n]"))
            #expect(removes.hasSuffix("== INSTALL\nnone\n== END\n"))
            // 1 Linux + 0 macOS to 1 + 1 only adds: applied.
            let adds = try await Self.rerun(status: SandboxFixtures.ready(linux: 1, macOS: 0), plan: Self.macOSFits,
                                            confirmed: confirmed)
            #expect(adds.contains("\nThis Mac now fits 1 Linux + 1 macOS (installed: 1 Linux + 0 macOS).\n"
                + "Applying it: it only adds slots.\n\n"))
            #expect(adds.hasSuffix("== INSTALL\n--json-progress\n--yes\n--linux-slots\n1\n--macos-slots\n1\n== END\n"))
        }
    }

    /// Setup's words for the installer's exit status 4.
    private static let jobRunningAdvice = "A job is running on this Mac, so the installer changed nothing. Run "
        + "`darkbloom sandbox setup` again when it finishes; `darkbloom sandbox pause` keeps new jobs from starting. "
        + "Setup never passes the installer's --force: it would stop running jobs, and stopped jobs aren't paid."

    @Test("applying the plan after a job started: the installer refuses (exit 4), setup says so and exits 4")
    func rerunRefusedWhileAJobRuns() async throws {
        // add-on 1.1.1's refusal (`InstallError.jobsRunning`) at its install stage.
        let refusal = "jobs are running on this Mac; rerun when they finish (the agent also updates itself "
            + "between jobs), or pass --force to stop them"
        let output = try await Self.rerun(
            status: SandboxFixtures.ready(linux: 3, macOS: 0), plan: Self.macOSFits, answer: "y\n",
            installerEvents: [FakeSandboxInstaller.stage("installing", "started", "Installing"),
                              FakeSandboxInstaller.stage("installing", "failed", refusal, #""exit_code":4"#)],
            installerExit: 4)
        #expect(output.contains("\n\n" + Self.jobRunningAdvice + "\n== PLAN"))
        #expect(!output.contains("Darkbloom Sandbox is set up on this Mac"))
        // The plan's counts, and no --force: the running job is not stopped.
        #expect(output.hasSuffix("== INSTALL\n--json-progress\n--yes\n--linux-slots\n1\n--macos-slots\n1\n== END\n"))
    }

    @Test("rerun while jobs run: today's report, no plan, and when to run it again")
    func rerunWhileJobsRun() async throws {
        let output = try await Self.rerun(status: SandboxFixtures.ready(linux: 3, macOS: 0, jobsRunning: 1),
                                          plan: Self.macOSFits)
        #expect(try outputSection(output, from: "== OUTPUT", to: "== PLAN") == Self.alreadySetUp(output)
            + "Jobs are running, so setup did not check whether this Mac now fits other slot counts. Run "
            + "`darkbloom sandbox setup` again once they finish; `darkbloom sandbox pause` keeps new ones from starting.\n")
        #expect(output.hasSuffix("== PLAN\nnone\n== INSTALL\nnone\n== END\n"))
    }

    @Test("rerun with explicit slot counts applies them without a plan, as before")
    func rerunExplicitCounts() async throws {
        let output = try await Self.rerun(
            status: SandboxFixtures.ready(linux: 3, macOS: 0), plan: Self.macOSFits, linuxSlots: 2, macOSSlots: 0)
        let shown = try #require(outputSection(output, from: "== OUTPUT", to: "== PLAN"))
        #expect(shown.hasPrefix("Applying the new slot counts.\n"))
        #expect(output.hasSuffix("== PLAN\nnone\n== INSTALL\n--json-progress\n--yes\n--linux-slots\n2\n"
            + "--macos-slots\n0\n== END\n"))
    }

    @Test("rerun with an installer without plan mode, or one that fails it: today's report")
    func rerunWithoutPlan() async throws {
        for plan in [nil, "not a plan"] as [String?] {
            let output = try await Self.rerun(status: SandboxFixtures.ready(linux: 3, macOS: 0), plan: plan)
            #expect(try outputSection(output, from: "== OUTPUT", to: "== PLAN") == Self.alreadySetUp(output))
            #expect(output.hasSuffix("== INSTALL\nnone\n== END\n"))
        }
    }

    @Test("rerun when the installer cannot be downloaded: today's report and why it could not check")
    func rerunOffline() async throws {
        let result = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            defer { sandbox.remove() }
            try FakeSandboxAddon.install(.current(status: SandboxFixtures.ready(linux: 3, macOS: 0)),
                                         at: sandbox.sandboxAddonRoot)
            try await SandboxSetupFlow(options: SandboxSetupOptions(server: "https://sandbox.invalid"),
                                       confirmed: false, addon: .live(), interactiveInput: false,
                                       terminal: false, color: false, waitlist: .approved).run()
        }
        #expect(decodedText(result.standardOutputContent).hasSuffix(Self.changeHint
            + "Could not check whether this Mac now fits other slot counts: Could not download the Darkbloom Sandbox "
            + "installer from https://sandbox.invalid/install.sh: HTTP 404.\n"))
    }

    @Test("when the plan fits no job, setup prints why and how much disk to free, and installs nothing")
    func noJobFits() async throws {
        let result = try await #require(processExitsWith: .failure, observing: [\.standardOutputContent]) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            CoordinatorStub.install(["/install.sh": .init(status: 200, body: Data(FakeSandboxInstaller.script(
                plan: [FakeSandboxInstaller.plan(message: "No slot fits", linux: 0, freeGiB: 120)]).utf8))])
            await exitWithCommandStatus {
                defer {
                    let root = sandbox.sandboxAddonRoot
                    print("planned \(FileManager.default.fileExists(atPath: root.appendingPathComponent("plan-arguments").path))")
                    print("installed \(FileManager.default.fileExists(atPath: root.appendingPathComponent("installer-arguments").path))")
                }
                try await SandboxSetupFlow(options: SandboxSetupOptions(server: "https://sandbox.invalid"),
                                           confirmed: true, addon: .live(), interactiveInput: false,
                                           terminal: false, color: false,
                                           probe: { _ in .mac(cores: 16, memoryGiB: 128) }, waitlist: .approved).run()
            }
        }
        let output = decodedText(result.standardOutputContent)
        #expect(output.hasSuffix("""
              [FAIL] Disk: 120 GiB free; 100 GiB stays free for you; Linux images 4 GiB + 30 GiB per Linux job; \
            macOS images 46 GiB + 40 GiB per macOS job

            Not eligible: No slot fits.
              Free up 14 GiB of disk for one Linux job, or 66 GiB of disk for one macOS job.
              \(Self.freeSpaceNote(macOSNeeds: 66))
            planned true
            installed false

            """))
    }

    @Test("an installer without a plan falls back to the CLI's estimate, by the add-on's 1.1.1 disk rules")
    func estimateWithoutPlan() async throws {
        let result = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            defer { sandbox.remove() }
            // A plan mode that prints no plan event, one that fails, and an installer from before plan mode.
            for script in [FakeSandboxInstaller.script(plan: []), FakeSandboxInstaller.script(plan: [], planExitStatus: 2),
                           FakeSandboxInstaller.script()] {
                try? FileManager.default.removeItem(at: sandbox.sandboxAddonRoot)
                CoordinatorStub.install(["/install.sh": .init(status: 200, body: Data(script.utf8))])
                print("== RUN")
                try await SandboxSetupFlow(
                    options: SandboxSetupOptions(server: "https://sandbox.invalid"), confirmed: true, addon: .live(),
                    interactiveInput: false, terminal: false, color: false,
                    probe: { _ in .mac(cores: 16, memoryGiB: 128, freeGiB: 157, volumeGiB: 1_858) }, waitlist: .approved).run()
            }
        }
        let runs = decodedText(result.standardOutputContent).components(separatedBy: "== RUN\n").dropFirst()
        #expect(runs.count == 3)
        for run in runs {
            #expect(run.contains("""
                  [PASS] Sleep: off on the power adapter
                  [INFO] Sizing: this installer reports no plan (add-on 1.1.1 and later do); the CLI estimated the \
                lines below
                  [PASS] CPU: 16 cores; you keep 4
                  [PASS] Memory: 128 GB; you keep 32 GB, inference keeps 32 GB
                  [PASS] Disk: 157 GiB free; 100 GiB stays free for you; Linux images 4 GiB + 30 GiB per Linux job; \
                macOS images 46 GiB + 40 GiB per macOS job

                Eligible. At a time, this Mac can run:
                  1 Linux job (limited by free disk space)
                  no macOS jobs (limited by free disk space)

                What changes
                """))
            #expect(run.contains("Darkbloom Sandbox is set up on this Mac"))
        }
    }

    @Test("an installer without progress events runs as it is, with only the options it knows")
    func olderInstaller() async throws {
        let result = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            defer { sandbox.remove() }
            CoordinatorStub.install(["/install.sh": .init(status: 200, body: Data(
                FakeSandboxInstaller.script(events: [], addonStatus: SandboxFixtures.ready, jsonProgress: false).utf8))])
            try await SandboxSetupFlow(
                options: SandboxSetupOptions(server: "https://sandbox.invalid", waitReady: true, macOSSlots: 1),
                confirmed: true, addon: .live(), interactiveInput: false, terminal: false, color: false,
                probe: { _ in .mac(cores: 16, memoryGiB: 128) }, waitlist: .approved).run()
            print("== ARGUMENTS")
            print(try String(contentsOf: sandbox.sandboxAddonRoot.appendingPathComponent("installer-arguments"),
                             encoding: .utf8), terminator: "")
        }
        let output = decodedText(result.standardOutputContent)
        #expect(output.contains("""
            This version of the installer does not report its steps to the CLI; its own output follows.
            It does not support --no-browser or --wait-ready.

            ==> Darkbloom Sandbox 1.0.0 downloaded and checked

            Darkbloom Sandbox is set up on this Mac: ready
            """))
        #expect(output.hasSuffix("== ARGUMENTS\n--macos-slots\n1\n"))
    }

    @Test("a failing installer keeps its exit status and says what it means")
    func failingInstaller() async throws {
        let message = "Darkbloom Sandbox 1.0.1 needs macOS 28 or later"
        let result = try await #require(processExitsWith: .exitCode(2), observing: [\.standardOutputContent]) {
            _ = try CLICommandSandbox.enter(autoRestart: false)
            let stage = FakeSandboxInstaller.stage
            CoordinatorStub.install(["/install.sh": .init(status: 200, body: Data(FakeSandboxInstaller.script(
                events: Array(FakeSandboxInstaller.events[0..<3])
                    + [stage("verifying_release", "failed", "Darkbloom Sandbox 1.0.1 needs macOS 28 or later",
                             #""exit_code":2,"step":2,"steps":8"#)],
                standardError: "error: Darkbloom Sandbox 1.0.1 needs macOS 28 or later",
                exitStatus: 2).utf8))])
            await exitWithCommandStatus {
                try await SandboxSetupFlow(options: SandboxSetupOptions(server: "https://sandbox.invalid"),
                                           confirmed: true, addon: .live(), interactiveInput: false,
                                           terminal: false, color: false,
                                           probe: { _ in .mac(cores: 16, memoryGiB: 128) }, waitlist: .approved).run()
            }
        }
        let output = decodedText(result.standardOutputContent)
        #expect(output.hasSuffix("""
              ✓ Checking this Mac
                Apple M4 Max, 16 cores, 128 GB memory, macOS 27.0.1; logged in as ada
              ✗ Verifying release
                \(message)

            This Mac cannot host Darkbloom Sandbox as it is; see why above.

            """))
    }

    @Test("stopped while waiting: an add-on that waits in the background gets its own texts; an older one the old ones")
    func stoppedWhileWaiting() async throws {
        let result = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            defer { sandbox.remove() }
            // Add-on 1.1.2 says `background: true`; add-on 1.1.1 leaves the member out.
            for background in [true, nil] as [Bool?] {
                try? FileManager.default.removeItem(at: sandbox.sandboxAddonRoot)
                CoordinatorStub.install(["/install.sh": .init(status: 200, body: Data(FakeSandboxInstaller.script(
                    events: Array(FakeSandboxInstaller.events[0..<8])
                        + [FakeSandboxInstaller.approval(background: background),
                           FakeSandboxInstaller.waitlist(background: background)],
                    exitStatus: 130).utf8))])
                print("== RUN")
                do {
                    try await SandboxSetupFlow(options: SandboxSetupOptions(server: "https://sandbox.invalid"),
                                               confirmed: true, addon: .live(), interactiveInput: false,
                                               terminal: false, color: false,
                                               probe: { _ in .mac(cores: 16, memoryGiB: 128) }, waitlist: .approved).run()
                } catch let code as ExitCode {
                    print("exit \(code.rawValue)")
                }
            }
        }
        let runs = Array(decodedText(result.standardOutputContent).components(separatedBy: "== RUN\n").dropFirst())
        try #require(runs.count == 2)
        let approval = """
              ✓ Installing
                ~/DarkbloomSandbox: 1 Linux slot and 1 macOS slot

                Approve this Mac in your browser, signed in to the Darkbloom account that should own it:
                  https://api-sandbox.darkbloom.dev/device?code=WDJB-MJHT
                Code: WDJB-MJHT. Check the Mac shown, then press Approve; the CLI cannot approve for you.
                Open the link in a browser on any device.
                Earnings for jobs on this Mac go to the account that approves it.


                Your account is on the waitlist: Darkbloom reviews new Mac owners before their first Mac joins.

            """
        #expect(runs[0].hasSuffix(approval + """
                You can close this window: this Mac keeps waiting, also across restarts, and enrolls by itself \
            once your account is approved. `darkbloom sandbox status` shows where it is.

              ✗ Waiting for approval (stopped)

            Setup stopped. This Mac keeps waiting for approval in the background, also across restarts, and enrolls \
            by itself once approved; `darkbloom sandbox status` shows where it is.
            exit 130

            """))
        #expect(runs[1].hasSuffix(approval + """
                Leave this running, or press Ctrl-C and run `darkbloom sandbox setup` again later; this Mac enrolls \
            once your account is approved.

              ✗ Waiting for approval (stopped)

            Setup stopped. An enrollment waiting for approval goes on; run `darkbloom sandbox setup` again to follow it.
            exit 130

            """))
    }

    @Test("a Mac that can never host sandboxes stops before anything is downloaded")
    func refused() async throws {
        let result = try await #require(processExitsWith: .failure, observing: [\.standardOutputContent]) {
            _ = try CLICommandSandbox.enter(autoRestart: false)
            await exitWithCommandStatus {
                defer { print("requests \(CoordinatorStub.requests.count)") }
                try await SandboxSetupFlow(options: SandboxSetupOptions(server: "https://sandbox.invalid"),
                                           confirmed: true, addon: .live(), interactiveInput: false,
                                           terminal: false, color: false,
                                           probe: { _ in
                                               var facts = SandboxHostFacts.mac(cores: 16, memoryGiB: 128)
                                               facts.macOSMajor = 26
                                               facts.macOSVersion = "26.4"
                                               return facts
                                           }, waitlist: .approved).run()
            }
        }
        let output = decodedText(result.standardOutputContent)
        #expect(output.hasSuffix("""
              [PASS] Sleep: off on the power adapter

            Not eligible: Darkbloom Sandbox needs macOS 27 or later; this Mac runs macOS 26.4. Update it in System \
            Settings → General → Software Update first.
            requests 0

            """))
    }

    @Test("a Mac too small for a job stops after the installer's sizing, before installing")
    func tooSmall() async throws {
        let result = try await #require(processExitsWith: .failure, observing: [\.standardOutputContent]) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            CoordinatorStub.install(["/install.sh": .init(status: 200, body: Data(FakeSandboxInstaller.script().utf8))])
            await exitWithCommandStatus {
                defer {
                    let installed = sandbox.sandboxAddonRoot.appendingPathComponent("installer-arguments")
                    print("requests \(CoordinatorStub.requests.count), installed \(FileManager.default.fileExists(atPath: installed.path))")
                }
                try await SandboxSetupFlow(options: SandboxSetupOptions(server: "https://sandbox.invalid"),
                                           confirmed: true, addon: .live(), interactiveInput: false,
                                           terminal: false, color: false,
                                           probe: { _ in .mac(cores: 8, memoryGiB: 16) }, waitlist: .approved).run()
            }
        }
        let output = decodedText(result.standardOutputContent)
        #expect(output.hasSuffix("\nNot eligible: each job needs 16 GB of memory besides the 8 GB kept for you "
            + "and the 4 GB kept for inference; this Mac has 4 GB left.\nrequests 1, installed false\n"))
        #expect(!output.contains("What changes"))
    }

    @Test("setup asks before installing, and stops on no or without a terminal")
    func confirmation() async throws {
        let declined = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            CoordinatorStub.install(["/install.sh": .init(status: 200, body: Data(FakeSandboxInstaller.script(
                plan: [FakeSandboxInstaller.plan()]).utf8))])
            try replaceStandardInput(with: "n\n")
            try await SandboxSetupFlow(options: SandboxSetupOptions(server: "https://sandbox.invalid"),
                                       confirmed: false, addon: .live(), interactiveInput: true,
                                       terminal: false, color: false,
                                       probe: { _ in .mac(cores: 16, memoryGiB: 128) }, waitlist: .approved).run()
            let installed = sandbox.sandboxAddonRoot.appendingPathComponent("installer-arguments")
            print("installed \(FileManager.default.fileExists(atPath: installed.path))")
        }
        #expect(decodedText(declined.standardOutputContent).hasSuffix(
            "Set up Darkbloom Sandbox on this Mac? [y/N]: Nothing changed.\ninstalled false\n"))
        let unattended = try await #require(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            _ = try CLICommandSandbox.enter(autoRestart: false)
            CoordinatorStub.install(["/install.sh": .init(status: 200, body: Data(FakeSandboxInstaller.script().utf8))])
            await exitWithCommandStatus {
                try await SandboxSetupFlow(options: SandboxSetupOptions(server: "https://sandbox.invalid"),
                                           confirmed: false, addon: .live(), interactiveInput: false,
                                           terminal: false, color: false,
                                           probe: { _ in .mac(cores: 16, memoryGiB: 128) }, waitlist: .approved).run()
            }
        }
        #expect(decodedText(unattended.standardErrorContent).contains(
            "Confirm in an interactive terminal, or pass --yes to set up without a prompt."))
    }

    @Test("a download failure names the URL and the reason")
    func downloadFailure() async throws {
        let result = try await #require(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            _ = try CLICommandSandbox.enter(autoRestart: false)
            await exitWithCommandStatus {
                try await SandboxSetupFlow(options: SandboxSetupOptions(server: "https://sandbox.invalid"),
                                           confirmed: true, addon: .live(), interactiveInput: false,
                                           terminal: false, color: false,
                                           probe: { _ in .mac(cores: 16, memoryGiB: 128) }, waitlist: .approved).run()
            }
        }
        #expect(decodedText(result.standardErrorContent).contains(
            "Could not download the Darkbloom Sandbox installer from https://sandbox.invalid/install.sh: HTTP 404. "
                + "Check this Mac's connection, then run `darkbloom sandbox setup` again."))
    }
}
