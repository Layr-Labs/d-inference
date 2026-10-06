import ArgumentParser
import Foundation
import ProviderCore
import Testing

@testable import darkbloom

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

    @Test("an update without hashes prints only the bundle hash")
    func availableWithoutOptionalHashes() async throws {
        let result = try await #require(
            processExitsWith: .success, observing: [\.standardOutputContent]
        ) {
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
