import ArgumentParser
import Foundation
import Testing

@testable import darkbloom
@testable import ProviderCore

/// `darkbloom update --check-only` asks the coordinator for the latest
/// release and installs nothing. The release endpoint is the stub
/// coordinator of `CLICommandSandbox`, in a child process.
@Suite("Update check-only command")
struct UpdateCheckCommandTests {

    @Test("check-only reports an available update with its hashes, an up-to-date install and a failed check")
    func checkOnlyOutcomes() async throws {
        let result = try await #require(
            processExitsWith: .success, observing: [\.standardOutputContent]
        ) {
            endChildAfter(seconds: 60)
            let sandbox = try CLICommandSandbox.enter()
            defer { sandbox.remove() }
            let arguments = ["update", "--check-only", "--config", sandbox.config.path]

            CoordinatorStub.install([
                "/v1/releases/latest": .init(status: 200, body: CLICommandSandbox.releaseJSON(
                    version: "99.0.0", binaryHash: "binary-sha", metallibHash: "metallib-sha")),
            ])
            print("== AVAILABLE")
            try await runCLICommand(Update.self, arguments)
            #expect(CoordinatorStub.requests.first?.url?.query == "platform=macos-arm64")

            CoordinatorStub.install([
                "/v1/releases/latest": .init(status: 200, body: CLICommandSandbox.releaseJSON(version: "0.0.1")),
            ])
            print("== CURRENT")
            try await runCLICommand(Update.self, arguments + ["--coordinator", "https://override.invalid"])
            #expect(CoordinatorStub.requests.first?.url?.host == "override.invalid")

            CoordinatorStub.install(["/v1/releases/latest": .json(500, "boom")])
            print("== FAILED")
            let error = try await runFailingCLICommand(Update.self, arguments)
            #expect((error as? ExitCode) == .failure)
            print("== END")
        }
        let output = decodedText(result.standardOutputContent)
        let header = "darkbloom update\nCurrent version: \(ProviderCore.version)\n\n"

        let available = try #require(outputSection(output, from: "== AVAILABLE", to: "== CURRENT"))
        #expect(available == header
            + "Update available: v\(ProviderCore.version) -> v99.0.0\n"
            + "Download URL: https://downloads.invalid/darkbloom-99.0.0.tar.gz\n"
            + "Bundle SHA-256: bundle-99.0.0\n"
            + "Binary SHA-256: binary-sha\n"
            + "mlx.metallib SHA-256: metallib-sha\n"
            + "\n"
            + "Run 'darkbloom update' to install.\n")

        let current = try #require(outputSection(output, from: "== CURRENT", to: "== FAILED"))
        #expect(current.hasPrefix(header + "Up to date (v"))
        #expect(!current.contains("Update available"))

        let failed = try #require(outputSection(output, from: "== FAILED", to: "== END"))
        #expect(failed == header)
    }

    /// pair-2's MacBook (DevNet, 2026-11-07): "download failed: update check failed: The request timed out", twice, a
    /// minute each. The check of both forms of the command now tries 3 times, 15 s each, and says what failed, that
    /// nothing changed, and what to do. `update` gets an install root in the sandbox (`Update.updaterForTesting`).
    @Test("a check that gets no answer is tried 3 times, 15 s each, then said plainly with what to do")
    func unansweredCheckSaysWhatToDo() async throws {
        let result = try await #require(
            processExitsWith: .success, observing: [\.standardErrorContent]
        ) {
            endChildAfter(seconds: 60)
            let sandbox = try CLICommandSandbox.enter()
            defer { sandbox.remove() }
            let install = sandbox.root.appendingPathComponent("install", isDirectory: true)
            let unanswered = ["/v1/releases/latest": CoordinatorStub.Reply.failure(.timedOut)]
            try await Update.$updaterForTesting.withValue({ coordinator in
                sandboxUpdater(coordinator, install: install)
            }) {
                CoordinatorStub.install(unanswered)
                let checkOnly = try await runFailingCLICommand(
                    Update.self, ["update", "--check-only", "--config", sandbox.config.path])
                #expect((checkOnly as? ExitCode) == .failure)
                #expect(CoordinatorStub.requests.map(\.timeoutInterval) == [15, 15, 15])

                CoordinatorStub.install(unanswered)
                let update = try await runFailingCLICommand(Update.self, ["update", "--config", sandbox.config.path])
                #expect((update as? ExitCode) == .failure)
                #expect(CoordinatorStub.requests.map { $0.url?.path } == Array(repeating: "/v1/releases/latest", count: 3))
            }
        }
        let errors = decodedText(result.standardErrorContent)
        #expect(errors.contains("""
            Couldn't check for updates: coordinator.invalid didn't answer within 15 s (3 tries).
            Run `darkbloom update --check-only` again in a minute. If it keeps failing, check this Mac's network connection.
            Couldn't check for updates: coordinator.invalid didn't answer within 15 s (3 tries). Nothing was downloaded or changed.
            Run `darkbloom update` again in a minute. If it keeps failing, check this Mac's network connection.

            """), "\(errors)")
        #expect(!errors.contains("download failed"))
    }

    /// Under a mutant whose rounds never ended, `unansweredCheckSaysWhatToDo`'s child asked again for 1 h 50 min (its
    /// coordinator fails every try at once, and its updater doesn't pause), and a time limit doesn't end an exit test's
    /// child. So each child here ends itself after a minute (`endChildAfter`): its test fails instead of the run hanging.
    @Test("a child that doesn't end by itself is ended after its time, and says so")
    func childEndsAfterItsTime() async throws {
        let result = try await #require(
            processExitsWith: .exitCode(124), observing: [\.standardErrorContent]
        ) {
            endChildAfter(seconds: 1)
            let started = Date()
            while Date().timeIntervalSince(started) < 30 {}
        }
        let errors = decodedText(result.standardErrorContent)
        #expect(errors.contains("the exit test's child didn't end within 1 s, so it was ended\n"), "\(errors)")
    }

    /// The coordinator answered, so the network isn't what failed: the lines say what the answer was instead.
    @Test("a check the coordinator refuses says so, and doesn't point at the network")
    func refusedCheckSaysWhatWasRefused() async throws {
        let result = try await #require(
            processExitsWith: .success, observing: [\.standardErrorContent]
        ) {
            endChildAfter(seconds: 60)
            let sandbox = try CLICommandSandbox.enter()
            defer { sandbox.remove() }
            let install = sandbox.root.appendingPathComponent("install", isDirectory: true)
            try await Update.$updaterForTesting.withValue({ coordinator in
                sandboxUpdater(coordinator, install: install)
            }) {
                CoordinatorStub.install(["/v1/releases/latest": .json(500, "boom")])
                let checkOnly = try await runFailingCLICommand(
                    Update.self, ["update", "--check-only", "--config", sandbox.config.path])
                #expect((checkOnly as? ExitCode) == .failure)
                let update = try await runFailingCLICommand(Update.self, ["update", "--config", sandbox.config.path])
                #expect((update as? ExitCode) == .failure)
                #expect(CoordinatorStub.requests.count == 2)
            }
        }
        let errors = decodedText(result.standardErrorContent)
        #expect(errors.contains("""
            Couldn't check for updates: coordinator.invalid answered HTTP 500 instead of the latest release.
            The coordinator answered, so this Mac's network connection works. Run `darkbloom update --check-only` again later.
            Couldn't check for updates: coordinator.invalid answered HTTP 500 instead of the latest release. Nothing was downloaded or changed.
            The coordinator answered, so this Mac's network connection works. Run `darkbloom update` again later.

            """), "\(errors)")
        #expect(!errors.contains("check this Mac's network connection"))
    }

    @Test("a check that fails on this Mac says so, and doesn't point at the network")
    func thisMacsFailureSaysSo() async throws {
        let result = try await #require(
            processExitsWith: .success, observing: [\.standardErrorContent]
        ) {
            endChildAfter(seconds: 60)
            let sandbox = try CLICommandSandbox.enter()
            defer { sandbox.remove() }
            let install = sandbox.root.appendingPathComponent("install", isDirectory: true)
            let record = install.appendingPathComponent("recovery/state.json")
            try FileManager.default.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{".utf8).write(to: record)
            try await Update.$updaterForTesting.withValue({ coordinator in
                sandboxUpdater(coordinator, install: install)
            }) {
                CoordinatorStub.install(["/v1/releases/latest": .init(status: 200, body: CLICommandSandbox.releaseJSON(version: "99.0.0"))])
                let checkOnly = try await runFailingCLICommand(
                    Update.self, ["update", "--check-only", "--config", sandbox.config.path])
                #expect((checkOnly as? ExitCode) == .failure)
                let update = try await runFailingCLICommand(Update.self, ["update", "--config", sandbox.config.path])
                #expect((update as? ExitCode) == .failure)
                #expect(CoordinatorStub.requests.isEmpty)
            }
        }
        let errors = decodedText(result.standardErrorContent)
        let unreadable = errors.split(separator: "\n").filter {
            $0.hasPrefix("Couldn't check for updates: this Mac's update record can't be read (")
        }
        #expect(unreadable.count == 2, "\(errors)")
        #expect(errors.contains(
            "This is on this Mac, not its network connection: fix it, then run `darkbloom update --check-only` again.\n"))
        #expect(errors.contains("This is on this Mac, not its network connection: fix it, then run `darkbloom update` again.\n"))
        #expect(!errors.contains("check this Mac's network connection"))
    }

    @Test("the lines name what failed once, with one full stop, and only no answer points at the network")
    func checkFailedLines() {
        #expect(Update.checkFailedLines(.init(.badAnswer, "x answered HTTP 503."), checkOnly: false) == [
            "Couldn't check for updates: x answered HTTP 503. Nothing was downloaded or changed.",
            "The coordinator answered, so this Mac's network connection works. Run `darkbloom update` again later.",
        ])
        #expect(Update.checkFailedLines(.init(.noAnswer, "x didn't answer within 15 s (3 tries)"), checkOnly: true) == [
            "Couldn't check for updates: x didn't answer within 15 s (3 tries).",
            "Run `darkbloom update --check-only` again in a minute. If it keeps failing, check this Mac's network connection.",
        ])
        #expect(Update.checkFailedLines(.init(.thisMac, "the coordinator URL isn't a valid URL"), checkOnly: false) == [
            "Couldn't check for updates: the coordinator URL isn't a valid URL. Nothing was downloaded or changed.",
            "This is on this Mac, not its network connection: fix it, then run `darkbloom update` again.",
        ])
    }

    @Test("an update without hashes prints only the bundle hash")
    func availableWithoutOptionalHashes() async throws {
        let result = try await #require(
            processExitsWith: .success, observing: [\.standardOutputContent]
        ) {
            endChildAfter(seconds: 60)
            let sandbox = try CLICommandSandbox.enter()
            defer { sandbox.remove() }
            CoordinatorStub.install([
                "/v1/releases/latest": .init(status: 200, body: CLICommandSandbox.releaseJSON(version: "99.1.0")),
            ])
            try await runCLICommand(
                Update.self, ["update", "--check-only", "--override-quarantine", "--config", sandbox.config.path])
        }
        let output = decodedText(result.standardOutputContent)
        #expect(output.contains("Bundle SHA-256: bundle-99.1.0\n\nRun 'darkbloom update' to install.\n"))
        #expect(!output.contains("Binary SHA-256"))
        #expect(!output.contains("mlx.metallib SHA-256"))
    }

    @Test("update parses its check, quarantine and drain options")
    func parsing() throws {
        let update = try #require(try Darkbloom.parseAsRoot([
            "update", "--check-only", "--override-quarantine", "--coordinator", "https://override.invalid",
            "--timeout", "30", "--force",
        ]) as? Update)
        #expect(update.checkOnly)
        #expect(update.overrideQuarantine)
        #expect(update.coordinator == "https://override.invalid")
        #expect(update.drain.timeout == 30)
        #expect(update.drain.force)
        #expect(throws: (any Error).self) { try Darkbloom.parseAsRoot(["update", "--timeout", "3601"]) }
    }

    @Test("update reads the coordinator and settings from the selected config")
    func updateConfigLoading() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("update-config-\(UUID().uuidString)", isDirectory: true)
        let cache = folder.appendingPathComponent("hub", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("provider.toml")
        try ConfigManager.save(
            ProviderConfig(
                provider: ProviderSettings(name: "update-fixture", autoUpdate: false),
                backend: BackendSettings(modelCacheDirectory: cache.path),
                coordinator: CoordinatorSettings(url: "https://coordinator.invalid")),
            to: path)
        let config = try loadUpdateConfig(configPath: path.path)
        #expect(config.coordinator.url == "https://coordinator.invalid")
        #expect(config.provider.name == "update-fixture")
        #expect(!config.provider.autoUpdate)
    }
}

/// The updater `update` gets in a sandbox: the shared session (the stub coordinator), an install root of the sandbox's,
/// and the standard check without its pauses or log lines.
private func sandboxUpdater(_ coordinator: String, install: URL) -> SelfUpdater {
    SelfUpdater(coordinatorBaseURL: coordinator, installRoot: install, verifyCodeSignatures: false,
                currentVersion: ProviderCore.version, releaseCheck: .init(pause: { _ in }, log: { _ in }))
}
