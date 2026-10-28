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

    @Test("progress lines decode into stages; anything else is shown as text")
    func events() {
        #expect(SandboxInstallerOutput(line: #"{"schema":1,"stage":"verifying","version":"1.2.0"}"#)
            == .event(.init(stage: .verifying, version: "1.2.0")))
        #expect(SandboxInstallerOutput(line: #"""
            {"schema":1,"stage":"waiting_for_approval","verification_uri_complete":"https://s/device?user_code=AB","user_code":"AB","expires_in":600,"extra":true}
            """#) == .event(.init(stage: .waitingForApproval, url: "https://s/device?user_code=AB", code: "AB",
                                  expiresIn: 600)))
        #expect(SandboxInstallerOutput(line: #"{"stage":"downloading_images","progress":1.7}"#)
            == .event(.init(stage: .downloadingImages, progress: 1)))
        #expect(SandboxInstallerOutput(line: #"{"schema":1,"stage":"vm_check","detail":"Checking the VM runtime"}"#)
            == .event(.init(stage: .other("vm_check"), detail: "Checking the VM runtime")))
        #expect(SandboxInstallerOutput(line: "==> Downloading the latest release") == .text("==> Downloading the latest release"))
        #expect(SandboxInstallerOutput(line: #"{"no":"stage"}"#) == .text(#"{"no":"stage"}"#))
        #expect(SandboxInstallerOutput(line: "   ") == nil)
        #expect(SandboxInstallerEvent(stage: .other("vm_check")).title == "Vm Check")
        #expect(SandboxInstallerEvent(stage: .enrolled, hostID: "h_1").title == "Enrolled (host h_1)")
        #expect(SandboxInstallerEvent(stage: .downloadingImages, progress: 0.426).title == "Downloading images 42%")
    }

    /// Each event as the renderer gets it.
    private static func render(_ lines: [String], interactive: Bool = false, browserOpens: Bool = true,
                               finish outcome: SandboxSetupRenderer.Outcome = .succeeded) -> String {
        let output = LineCollector()
        let renderer = SandboxSetupRenderer(interactive: interactive, color: false, browserOpens: browserOpens,
                                            approvalPage: "https://sandbox.example/device",
                                            width: { 80 }, write: { output.append($0) })
        for line in lines {
            if let parsed = SandboxInstallerOutput(line: line) { renderer.handle(parsed) }
            if interactive { renderer.tick() }
        }
        renderer.finish(outcome)
        return output.all.joined()
    }

    @Test("off a terminal each stage prints once it ends; the approval link prints at once")
    func transcript() {
        #expect(Self.render(FakeSandboxInstaller.events + [
            #"{"schema":1,"stage":"downloading_images","progress":0.71}"#,
            #"{"schema":1,"stage":"downloading_images","progress":0.75}"#,
            #"{"schema":1,"stage":"ready"}"#,
        ], browserOpens: false) == """
              ✓ Checking this Mac
              ✓ Verifying release 1.2.0
              ✓ Installing
                Linux slots: 1

                Approve this Mac in your browser, signed in to your Darkbloom account:
                  https://sandbox.invalid/device?user_code=WXYZ-1234
                Code: WXYZ-1234 (expires in 15 min). Earnings go to the account that approves.
                Open the link yourself. The CLI cannot approve for you.

              ✓ Waiting for approval
              ✓ Enrolled (host h_test)
              ✓ Starting
                Downloading images 71%
              ✓ Downloading images 75%
              ✓ Ready

            """)
    }

    @Test("an installer that stops while images download says they continue")
    func backgroundDownload() {
        let transcript = Self.render(FakeSandboxInstaller.events)
        #expect(transcript.hasSuffix("  ✓ Starting\n  • Downloading images 42%, continuing in the background\n"))
        #expect(transcript.contains(
            "    Your browser should open it; if not, open the link yourself. The CLI cannot approve for you.\n"))
    }

    @Test("on a terminal the running stage is a spinner line that turns into a check mark")
    func interactive() {
        let transcript = Self.render([
            #"{"schema":1,"stage":"checking"}"#,
            #"{"schema":1,"stage":"verifying","version":"1.2.0"}"#,
        ], interactive: true)
        #expect(transcript == "  ⠋ Checking this Mac"
            + "\r\u{1B}[2K  ⠙ Checking this Mac"
            + "\r\u{1B}[2K  ✓ Checking this Mac\n  ⠙ Verifying release 1.2.0"
            + "\r\u{1B}[2K  ⠹ Verifying release 1.2.0"
            + "\r\u{1B}[2K  ✓ Verifying release 1.2.0\n")
    }

    @Test("failures show the installer's error, then its stderr; Ctrl-C marks the stage stopped")
    func failures() {
        let failed = Self.render([
            #"{"schema":1,"stage":"checking"}"#,
            #"{"schema":1,"stage":"error","detail":"this Mac is enrolled with another service"}"#,
        ], finish: .failed(SandboxSetupFlow.failureLines(
            detail: "this Mac is enrolled with another service",
            errors: ["error: this Mac is enrolled with another service", "see ~/DarkbloomSandbox/agent/enroll.log"],
            status: 1)))
        #expect(failed == """
              ✗ Checking this Mac
                this Mac is enrolled with another service
                see ~/DarkbloomSandbox/agent/enroll.log

            """)
        #expect(SandboxSetupFlow.failureLines(detail: nil, errors: [], status: 3) == ["The installer exited with status 3."])
        #expect(Self.render([#"{"schema":1,"stage":"waitlisted"}"#], finish: .interrupted).hasSuffix(
            "  ✗ On the waitlist, waiting for Darkbloom to approve your account (stopped)\n"))
        #expect(Self.render([], finish: .failed(["boom"])) == "  ✗ Setup failed\n    boom\n")
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
        #expect(plan(SandboxFixtures.error) == .rerun("The add-on reports an error (the macOS image failed "
            + "verification); running the installer again to repair it."))
        #expect(SandboxSetupPlan.decide(.outdated, changingSlots: false)
            == .rerun("Updating the add-on: this version is older than the CLI expects."))
        #expect(SandboxSetupPlan.decide(.unresponsive(seconds: 10), changingSlots: false)
            == .rerun("The add-on did not answer within 10 seconds; running the installer again to repair it."))
    }

    @Test("the summary names the state, the slots and what to do next")
    func summary() {
        let lines = SandboxSetupFlow.summary(SandboxFixtures.status(SandboxFixtures.downloading),
                                             server: "https://sandbox.example", color: false)
        #expect(lines == [
            "Darkbloom Sandbox is set up on this Mac: downloading images (42%)",
            "  Jobs start once an image is installed.",
            "  Jobs at a time: 1 Linux, 1 macOS",
            "",
            "Next",
            "  darkbloom sandbox status    see jobs, slots and images",
            "  darkbloom sandbox pause     let running jobs finish and take no new ones",
            "  darkbloom sandbox logs -f   follow the add-on's log",
            "  Earnings: https://api-sandbox.darkbloom.dev (Billing → Earnings)",
            "  Keep this Mac plugged in, awake and logged in.",
        ])
    }

    // MARK: - End to end

    /// The whole setup against a stubbed service and a fake installer: the
    /// installer is downloaded, staged, run with the owner's options, rendered
    /// and summarized; a second run only reports the state.
    @Test("setup checks, installs with progress, summarizes, and a rerun only reports")
    func endToEnd() async throws {
        let result = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            defer { sandbox.remove() }
            CoordinatorStub.install(["/install.sh": .init(status: 200, body: Data(FakeSandboxInstaller.script().utf8))])
            let first = SandboxSetupOptions(server: "https://sandbox.invalid", noBrowser: true, linuxSlots: 1)
            print("== FIRST")
            try await SandboxSetupFlow(options: first, confirmed: true, addon: .live(), interactiveInput: false,
                                       terminal: false, color: false,
                                       probe: { _ in .mac(cores: 16, memoryGiB: 128) }).run()
            print("== SECOND")
            try await SandboxSetupFlow(options: SandboxSetupOptions(server: "https://sandbox.invalid"),
                                       confirmed: false, addon: .live(), interactiveInput: false,
                                       terminal: false, color: false).run()
            print("== ARGUMENTS")
            print(try String(contentsOf: sandbox.sandboxAddonRoot.appendingPathComponent("installer-arguments"),
                             encoding: .utf8), terminator: "")
            print("requests \(CoordinatorStub.requests.map { $0.url?.absoluteString ?? "" })")
        }
        let output = decodedText(result.standardOutputContent)
        let first = try #require(outputSection(output, from: "== FIRST", to: "== SECOND"))
        #expect(first.hasPrefix("""
            Darkbloom Sandbox setup

            Checking this Mac
              [PASS] Chip: Apple M4 Max
              [PASS] macOS: 27.0.1
              [PASS] CPU: 16 cores; you keep 4
              [PASS] Memory: 128 GB; you keep 32 GB, inference keeps 32 GB
              [PASS] Disk: 800 GiB free; 100 GiB stays free for you, the VM images take 50 GiB, each Linux job 30 GiB
              [PASS] Session: logged in at this Mac's desktop
              [PASS] Network: Ethernet
              [PASS] Power: power adapter
              [PASS] Sleep: off on the power adapter

            Eligible. At a time, this Mac can run:
              1 Linux job (limited by cores)
              1 macOS job (limited by cores)
              The most requested macOS size, 12 cores and 32 GB, fits.

            What changes

            """))
        #expect(first.contains("""

              ✓ Checking this Mac
              ✓ Verifying release 1.2.0
              ✓ Installing
                Linux slots: 1

            """))
        #expect(first.contains("    Open the link yourself. The CLI cannot approve for you.\n"))
        #expect(first.contains("""
              ✓ Enrolled (host h_test)
              ✓ Starting
              • Downloading images 42%, continuing in the background

            Darkbloom Sandbox is set up on this Mac: ready
              Waiting for jobs. Inference runs as usual until a job starts.
              Jobs at a time: 1 Linux, 1 macOS

            Next

            """))
        let second = try #require(outputSection(output, from: "== SECOND", to: "== ARGUMENTS"))
        #expect(second.hasPrefix("Darkbloom Sandbox is already set up on this Mac.\n\nDarkbloom Sandbox 1.2.0: ready\n"))
        #expect(second.hasSuffix(
            "\nTo change how many jobs run at a time: darkbloom sandbox setup --linux-slots <n> --macos-slots <n>\n"))
        let arguments = try #require(outputSection(output, from: "== ARGUMENTS", to: "requests"))
        #expect(arguments == "--json-progress\n--yes\n--no-browser\n--linux-slots\n1\n")
        #expect(output.hasSuffix("requests [\"https://sandbox.invalid/install.sh\"]\n"))
    }

    @Test("an installer without progress events runs as it is, with only the options it knows")
    func olderInstaller() async throws {
        let result = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            defer { sandbox.remove() }
            CoordinatorStub.install(["/install.sh": .init(status: 200, body: Data(
                FakeSandboxInstaller.script(events: [], jsonProgress: false).utf8))])
            try await SandboxSetupFlow(
                options: SandboxSetupOptions(server: "https://sandbox.invalid", waitReady: true, macOSSlots: 1),
                confirmed: true, addon: .live(), interactiveInput: false, terminal: false, color: false,
                probe: { _ in .mac(cores: 16, memoryGiB: 128) }).run()
            print("== ARGUMENTS")
            print(try String(contentsOf: sandbox.sandboxAddonRoot.appendingPathComponent("installer-arguments"),
                             encoding: .utf8), terminator: "")
        }
        let output = decodedText(result.standardOutputContent)
        #expect(output.contains("""
            This version of the installer does not report its steps to the CLI; its own output follows.
            It does not support --no-browser or --wait-ready.

            ==> Darkbloom Sandbox 1.1.0 downloaded and checked

            Darkbloom Sandbox is set up on this Mac: ready
            """))
        #expect(output.hasSuffix("== ARGUMENTS\n--macos-slots\n1\n"))
    }

    @Test("a failing installer keeps its exit status and says how to retry")
    func failingInstaller() async throws {
        let result = try await #require(processExitsWith: .exitCode(3), observing: [\.standardOutputContent]) {
            _ = try CLICommandSandbox.enter(autoRestart: false)
            CoordinatorStub.install(["/install.sh": .init(status: 200, body: Data(FakeSandboxInstaller.script(
                events: [#"{"schema":1,"stage":"checking"}"#, #"{"schema":1,"stage":"verifying","version":"1.2.0"}"#,
                         #"{"schema":1,"stage":"error","detail":"the downloaded app is not Darkbloom's"}"#],
                standardError: "codesign: the signature is invalid",
                exitStatus: 3).utf8))])
            await exitWithCommandStatus {
                try await SandboxSetupFlow(options: SandboxSetupOptions(server: "https://sandbox.invalid"),
                                           confirmed: true, addon: .live(), interactiveInput: false,
                                           terminal: false, color: false,
                                           probe: { _ in .mac(cores: 16, memoryGiB: 128) }).run()
            }
        }
        let output = decodedText(result.standardOutputContent)
        #expect(output.hasSuffix("""
              ✓ Checking this Mac
              ✗ Verifying release 1.2.0
                the downloaded app is not Darkbloom's
                codesign: the signature is invalid

            Setup did not finish. When the problem above is fixed, run `darkbloom sandbox setup` again; it is safe to rerun.

            """))
    }

    @Test("an ineligible Mac stops before anything is downloaded")
    func ineligible() async throws {
        let result = try await #require(processExitsWith: .failure, observing: [\.standardOutputContent]) {
            _ = try CLICommandSandbox.enter(autoRestart: false)
            await exitWithCommandStatus {
                defer { print("requests \(CoordinatorStub.requests.count)") }
                try await SandboxSetupFlow(options: SandboxSetupOptions(server: "https://sandbox.invalid"),
                                           confirmed: true, addon: .live(), interactiveInput: false,
                                           terminal: false, color: false,
                                           probe: { _ in .mac(cores: 8, memoryGiB: 16) }).run()
            }
        }
        let output = decodedText(result.standardOutputContent)
        #expect(output.contains("\nNot eligible: each job needs 16 GB of memory besides the 8 GB kept for you "
            + "and the 4 GB kept for inference; this Mac has 4 GB left.\n"))
        #expect(!output.contains("What changes"))
        #expect(output.hasSuffix("requests 0\n"))
    }

    @Test("setup asks before installing, and stops on no or without a terminal")
    func confirmation() async throws {
        let declined = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) {
            _ = try CLICommandSandbox.enter(autoRestart: false)
            try replaceStandardInput(with: "n\n")
            try await SandboxSetupFlow(options: SandboxSetupOptions(server: "https://sandbox.invalid"),
                                       confirmed: false, addon: .live(), interactiveInput: true,
                                       terminal: false, color: false,
                                       probe: { _ in .mac(cores: 16, memoryGiB: 128) }).run()
            print("requests \(CoordinatorStub.requests.count)")
        }
        #expect(decodedText(declined.standardOutputContent).hasSuffix(
            "Set up Darkbloom Sandbox on this Mac? [y/N]: Nothing changed.\nrequests 0\n"))
        let unattended = try await #require(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            _ = try CLICommandSandbox.enter(autoRestart: false)
            await exitWithCommandStatus {
                try await SandboxSetupFlow(options: SandboxSetupOptions(server: "https://sandbox.invalid"),
                                           confirmed: false, addon: .live(), interactiveInput: false,
                                           terminal: false, color: false,
                                           probe: { _ in .mac(cores: 16, memoryGiB: 128) }).run()
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
                                           probe: { _ in .mac(cores: 16, memoryGiB: 128) }).run()
            }
        }
        #expect(decodedText(result.standardErrorContent).contains(
            "Could not download the Darkbloom Sandbox installer from https://sandbox.invalid/install.sh: HTTP 404. "
                + "Check this Mac's connection, then run `darkbloom sandbox setup` again."))
    }
}
