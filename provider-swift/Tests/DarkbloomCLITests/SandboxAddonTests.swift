import ArgumentParser
import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// The CLI against fake add-on commands it runs exactly as it runs the real
/// one: a current add-on, one from before `status --json`, a hung one, a
/// failing one and none at all.
@Suite("darkbloom sandbox: the add-on command")
struct SandboxAddonTests {
    @Test("the add-on root is ~/DarkbloomSandbox unless DARKBLOOM_SANDBOX_ROOT moves it")
    func paths() {
        let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
        let addon = SandboxAddon.live(environment: [:], home: home)
        #expect(addon.root.path == "/Users/me/DarkbloomSandbox")
        #expect(addon.command.path == "/Users/me/DarkbloomSandbox/darkbloom-sandbox")
        #expect(addon.agentLog.path == "/Users/me/DarkbloomSandbox/agent/agent.log")
        #expect(SandboxAddon.live(environment: [SandboxAddon.rootOverrideVariable: "/tmp/x"], home: home).root.path
            == "/tmp/x")
        #expect(SandboxAddon.live(environment: [SandboxAddon.rootOverrideVariable: ""], home: home).root == addon.root)
    }

    @Test("a missing add-on, or a command that is not executable, is not installed")
    func missing() throws {
        let root = FakeSandboxAddon.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let addon = SandboxAddon(root: root)
        #expect(addon.queryStatus(timeout: 60) == .notInstalled)
        #expect(addon.perform(["pause"], timeout: 60) == .notInstalled)
        let command = try FakeSandboxAddon.install(.current(status: SandboxFixtures.ready), at: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: command.path)
        #expect(!addon.isInstalled)
        #expect(addon.queryStatus(timeout: 60) == .notInstalled)
    }

    @Test("a current add-on answers with its JSON, kept byte for byte")
    func current() throws {
        let root = FakeSandboxAddon.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FakeSandboxAddon.install(.current(status: SandboxFixtures.running), at: root)
        let addon = SandboxAddon(root: root)
        guard case .status(let status, let json) = addon.queryStatus(timeout: 60) else {
            Issue.record("expected a status")
            return
        }
        #expect(status == SandboxFixtures.status(SandboxFixtures.running))
        #expect(json == SandboxFixtures.running + "\n")
        #expect(addon.perform(["pause"], timeout: 60) == .done)
        #expect(try String(contentsOf: root.appendingPathComponent("last-action"), encoding: .utf8) == "pause\n")
        #expect(addon.perform(["frobnicate"], timeout: 60) == .outdated)
    }

    @Test("an add-on from before status --json is told apart from a broken one")
    func outdated() throws {
        let root = FakeSandboxAddon.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FakeSandboxAddon.install(.outdated, at: root)
        let addon = SandboxAddon(root: root)
        #expect(addon.queryStatus(timeout: 60) == .outdated)
        #expect(addon.perform(["pause"], timeout: 60) == .outdated)
        try FakeSandboxAddon.install(.failing("agent state unreadable"), at: root)
        #expect(addon.queryStatus(timeout: 60) == .failed("exit status 1: agent state unreadable"))
        #expect(addon.perform(["resume"], timeout: 60) == .failed("exit status 1: agent state unreadable"))
    }

    @Test("an add-on command with nothing installed under it reads as not set up, its refusals too")
    func emptyInstall() async throws {
        let root = FakeSandboxAddon.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FakeSandboxAddon.install(.empty, at: root)
        let addon = SandboxAddon(root: root)
        guard case .status(let status, _) = addon.queryStatus(timeout: 60) else {
            Issue.record("the not_installed document must decode although status exits 1")
            return
        }
        #expect(!status.installed && SandboxStatusView.statusLine(.status(status, json: "")) == nil)
        #expect(addon.perform(["pause"], timeout: 60)
            == .failed("exit status 1: Darkbloom Sandbox is not installed in /Users/ada/DarkbloomSandbox"))
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            defer { sandbox.remove() }
            try FakeSandboxAddon.install(.empty, at: sandbox.sandboxAddonRoot)
            await exitWithCommandStatus { try await runCLICommand(Sandbox.Pause.self, ["sandbox", "pause"]) }
        }
        let errors = decodedText(result?.standardErrorContent ?? [])
        #expect(errors.contains("Darkbloom Sandbox is not set up on this Mac. Set it up with `darkbloom sandbox setup`."))
    }

    @Test("a hung add-on costs at most the timeout")
    func hung() throws {
        let root = FakeSandboxAddon.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FakeSandboxAddon.install(.hanging, at: root)
        let started = ContinuousClock.now
        #expect(SandboxAddon(root: root).queryStatus(timeout: 0.5) == .unresponsive(seconds: 1))
        // Far below the add-on's 30 s hang, with room for a slow process launch.
        #expect(ContinuousClock.now - started < .seconds(20))
    }

    @Test("a child gets Ctrl-C with default handling and reports how it ended")
    func childProcess() async throws {
        let lines = LineCollector()
        let errors = SandboxOutputTail()
        let exit = try await SandboxChildProcess.run(
            URL(fileURLWithPath: "/bin/sh"), ["-c", "printf 'one\\ntwo\\r\\nthree'; echo oops >&2; exit 3"],
            closeStandardInput: true, standardOutput: .lines { lines.append($0) }, standardError: .tail(errors))
        #expect(exit == .init(status: 3, signal: nil))
        #expect(!exit.succeeded && !exit.interrupted)
        #expect(lines.all == ["one", "two", "three"])
        #expect(errors.lastLines(5) == ["oops"])
        // A shell's `exit 130` after Ctrl-C, and death by SIGINT, both read as interrupted.
        #expect(try await SandboxChildProcess.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "exit 130"]).interrupted)
        let killed = try await SandboxChildProcess.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "kill -INT $$"])
        #expect(killed == .init(status: SIGINT, signal: SIGINT) && killed.interrupted)
        await #expect(throws: (any Error).self) {
            try await SandboxChildProcess.run(URL(fileURLWithPath: "/nonexistent/tool"), [])
        }
    }

    @Test("long lines are cut and a final line without a break is kept")
    func lineSplitter() {
        var splitter = SandboxLineSplitter(maximumBytes: 8)
        #expect(splitter.append(Data("ab\ncd".utf8)) == ["ab"])
        #expect(splitter.append(Data("efghijkl".utf8)) == ["cdefghijkl"])
        #expect(splitter.append(Data("z".utf8)) == [])
        #expect(splitter.finish() == "z")
        #expect(splitter.finish() == nil)
    }

    @Test("darkbloom status adds a Sandboxes line, never waits long and is silent without the add-on")
    func statusIntegration() async throws {
        let result = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            defer { sandbox.remove() }
            let arguments = ["status", "--config", sandbox.config.path]
            print("== NONE")
            try await runCLICommand(Status.self, arguments)
            try FakeSandboxAddon.install(.current(status: SandboxFixtures.running), at: sandbox.sandboxAddonRoot)
            // macOS assesses a new executable on its first runs, which can take
            // seconds on a loaded machine; status would rightly give up on it.
            var warmups = 0
            while warmups < 10, case .unresponsive = SandboxAddon.live().queryStatus(timeout: Sandbox.statusLineTimeout) {
                warmups += 1
            }
            print("== RUNNING")
            try await runCLICommand(Status.self, arguments)
            try FakeSandboxAddon.install(.hanging, at: sandbox.sandboxAddonRoot)
            let started = ContinuousClock.now
            print("== HUNG")
            try await runCLICommand(Status.self, arguments)
            print("elapsed \((ContinuousClock.now - started).components.seconds)")
            print("== END")
        }
        let output = decodedText(result.standardOutputContent)
        let none = try #require(outputSection(output, from: "== NONE", to: "== RUNNING"))
        #expect(!none.contains("Sandboxes"))
        let running = try #require(outputSection(output, from: "== RUNNING", to: "== HUNG"))
        #expect(running.contains("\nSandboxes: running 1 job; free slots Linux 0/1, macOS 1/1\n\nDaemon: not running"))
        let hung = try #require(outputSection(output, from: "== HUNG", to: "== END"))
        #expect(hung.contains("\nSandboxes: installed; the add-on did not answer within 2s. "
            + "Run `darkbloom sandbox status` for details.\n\nDaemon: not running (run `darkbloom start`)\n"))
        let elapsed = try #require(printedValue(hung, label: "elapsed").flatMap { Int($0) })
        #expect(elapsed < 20, "status waited \(elapsed)s for an add-on that hangs for 30s")
    }

    @Test("sandbox status: not set up, current, outdated and --json")
    func statusCommand() async throws {
        let result = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            defer { sandbox.remove() }
            print("== NONE")
            try await runCLICommand(Sandbox.Status.self, ["sandbox", "status"])
            try await runCLICommand(Sandbox.Status.self, ["sandbox", "status", "--json"])
            try FakeSandboxAddon.install(.current(status: SandboxFixtures.paused), at: sandbox.sandboxAddonRoot)
            print("== PAUSED")
            try await runCLICommand(Sandbox.self, ["sandbox"])
            try await runCLICommand(Sandbox.Status.self, ["sandbox", "status", "--json"])
            try FakeSandboxAddon.install(.outdated, at: sandbox.sandboxAddonRoot)
            print("== OUTDATED")
            try await runCLICommand(Sandbox.Status.self, ["sandbox", "status"])
            print("== END")
        }
        let output = decodedText(result.standardOutputContent)
        let none = try #require(outputSection(output, from: "== NONE", to: "== PAUSED"))
        #expect(none.hasPrefix("Darkbloom Sandbox: not set up on this Mac.\n"))
        #expect(none.contains("  Set it up with `darkbloom sandbox setup`. Docs: \(Sandbox.docsURL)\n"))
        #expect(none.hasSuffix(Sandbox.notInstalledJSON + "\n"))
        let paused = try #require(outputSection(output, from: "== PAUSED", to: "== OUTDATED"))
        #expect(paused.hasPrefix("Darkbloom Sandbox 1.0.1: paused\n  1 job still running;"))
        #expect(paused.hasSuffix("\n" + SandboxFixtures.paused + "\n"))
        let outdated = try #require(outputSection(output, from: "== OUTDATED", to: "== END"))
        #expect(outdated.hasPrefix("This version of the add-on has no `status --json`, so its own status follows."))
        #expect(outdated.hasSuffix("\nDarkbloom Sandbox 0.9.0 in ~/DarkbloomSandbox\n"))
    }

    @Test("sandbox status fails clearly when the add-on cannot answer")
    func statusFailures() async {
        await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            defer { sandbox.remove() }
            try FakeSandboxAddon.install(.failing("boom"), at: sandbox.sandboxAddonRoot)
            await exitWithCommandStatus { try await runCLICommand(Sandbox.Status.self, ["sandbox", "status"]) }
        }
    }

    @Test("pause and resume run the add-on's actions and say what happens next")
    func pauseAndResume() async throws {
        let result = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            defer { sandbox.remove() }
            try FakeSandboxAddon.install(.current(status: SandboxFixtures.paused), at: sandbox.sandboxAddonRoot)
            try await runCLICommand(Sandbox.Pause.self, ["sandbox", "pause"])
            print("last " + (try String(contentsOf: sandbox.sandboxAddonRoot.appendingPathComponent("last-action"),
                                        encoding: .utf8)), terminator: "")
            try await runCLICommand(Sandbox.Resume.self, ["sandbox", "resume"])
            print("last " + (try String(contentsOf: sandbox.sandboxAddonRoot.appendingPathComponent("last-action"),
                                        encoding: .utf8)), terminator: "")
        }
        #expect(decodedText(result.standardOutputContent) == """
            Paused: this Mac takes no new sandbox jobs until you run `darkbloom sandbox resume`.
              1 job still running; inference serves again once it ends.
            last pause
            Resumed: this Mac takes sandbox jobs again. Inference pauses while a job runs.
            last resume

            """)
    }

    @Test("pause on an outdated add-on, or without one, explains instead of failing silently")
    func pauseRefused() async {
        let outdated = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            defer { sandbox.remove() }
            try FakeSandboxAddon.install(.outdated, at: sandbox.sandboxAddonRoot)
            await exitWithCommandStatus { try await runCLICommand(Sandbox.Pause.self, ["sandbox", "pause"]) }
        }
        let outdatedErrors = decodedText(outdated?.standardErrorContent ?? [])
        #expect(outdatedErrors.contains(
            "This version of the add-on cannot pause from the CLI. It updates itself; "
                + "run `darkbloom sandbox setup` to update it now."))
        let missing = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            defer { sandbox.remove() }
            await exitWithCommandStatus { try await runCLICommand(Sandbox.Resume.self, ["sandbox", "resume"]) }
        }
        let missingErrors = decodedText(missing?.standardErrorContent ?? [])
        #expect(missingErrors.contains(
            "Darkbloom Sandbox is not set up on this Mac. Set it up with `darkbloom sandbox setup`."))
    }

    @Test("logs print the end of the agent log, or say why there is none")
    func logs() async throws {
        let result = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            defer { sandbox.remove() }
            print("== MISSING")
            try await runCLICommand(Sandbox.Logs.self, ["sandbox", "logs"])
            try FakeSandboxAddon.install(.current(status: SandboxFixtures.ready), at: sandbox.sandboxAddonRoot)
            print("== NO LOG")
            try await runCLICommand(Sandbox.Logs.self, ["sandbox", "logs"])
            let log = sandbox.sandboxAddonRoot.appendingPathComponent("agent/agent.log")
            try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("one\ntwo\nthree\n".utf8).write(to: log)
            print("== LOG")
            try await runCLICommand(Sandbox.Logs.self, ["sandbox", "logs", "-n", "2"])
            print("== END")
        }
        let output = decodedText(result.standardOutputContent)
        #expect(outputSection(output, from: "== MISSING", to: "== NO LOG")
            == "Darkbloom Sandbox is not set up on this Mac, so it has no log. Set it up with `darkbloom sandbox setup`.\n")
        #expect(outputSection(output, from: "== NO LOG", to: "== LOG")?.hasPrefix("No agent log yet at ") == true)
        #expect(outputSection(output, from: "== LOG", to: "== END") == "two\nthree\n")
    }

    @Test("uninstall explains, then runs the add-on's uninstall; without --yes it needs a terminal")
    func uninstall() async throws {
        let result = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            defer { sandbox.remove() }
            print("== NONE")
            try await runCLICommand(Sandbox.Uninstall.self, ["sandbox", "uninstall"])
            try FakeSandboxAddon.install(.current(status: SandboxFixtures.running), at: sandbox.sandboxAddonRoot)
            print("== RUNNING")
            try await runCLICommand(Sandbox.Uninstall.self, ["sandbox", "uninstall", "--yes"])
            print("removed \(!FileManager.default.fileExists(atPath: sandbox.sandboxAddonRoot.path))")
        }
        let output = decodedText(result.standardOutputContent)
        #expect(outputSection(output, from: "== NONE", to: "== RUNNING")
            == "Darkbloom Sandbox is not installed on this Mac; nothing to remove.\n")
        let running = try #require(outputSection(output, from: "== RUNNING", to: "removed"))
        #expect(running.contains("  1 job running now will end and will not be paid."))
        #expect(running.hasSuffix("==> Removed.\nSet it up again any time with `darkbloom sandbox setup`.\n"))
        #expect(output.hasSuffix("removed true\n"))

        let prompt = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            defer { sandbox.remove() }
            try FakeSandboxAddon.install(.current(status: SandboxFixtures.ready), at: sandbox.sandboxAddonRoot)
            try replaceStandardInput(with: "y\n")
            await exitWithCommandStatus { try await runCLICommand(Sandbox.Uninstall.self, ["sandbox", "uninstall"]) }
        }
        let promptErrors = decodedText(prompt?.standardErrorContent ?? [])
        #expect(promptErrors.contains(
            "Confirm in an interactive terminal, or pass --yes to uninstall without a prompt."))
    }
}

final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}
