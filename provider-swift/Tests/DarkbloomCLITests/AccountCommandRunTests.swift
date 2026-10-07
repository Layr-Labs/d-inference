import ArgumentParser
import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// `login`, `enroll` and `autoupdate` against a temporary provider home and
/// a stub coordinator, each in a child process (`CLICommandSandbox`).
/// Login stops before the browser step: either a token is already saved, or
/// the coordinator refuses the device code.
@Suite("Account command run")
struct AccountCommandRunTests {

    @Test("login refuses to replace a saved token and reports a refused device code")
    func loginFailures() async throws {
        let result = try await #require(
            processExitsWith: .success, observing: [\.standardErrorContent]
        ) {
            let sandbox = try CLICommandSandbox.enter()
            defer { sandbox.remove() }
            try sandbox.writeToken("saved-token-0123456789-abcdef")
            var error = try await runFailingCLICommand(Login.self, ["login", "--config", sandbox.config.path])
            #expect((error as? ExitCode) == .failure)
            #expect(CoordinatorStub.requests.isEmpty)

            try FileManager.default.removeItem(at: sandbox.tokenFile)
            CoordinatorStub.install(["/v1/device/code": .json(403, "device login disabled")])
            error = try await runFailingCLICommand(Login.self, ["login", "--config", sandbox.config.path])
            #expect((error as? ExitCode) == .failure)
            #expect(CoordinatorStub.requests.map(\.httpMethod) == ["POST"])
            #expect(!FileManager.default.fileExists(atPath: sandbox.tokenFile.path))
        }
        let errors = decodedText(result.standardErrorContent)
        #expect(errors.contains(
            "Already logged in (token: saved-token-01234567...). Run 'darkbloom logout' first to unlink.\n"))
        #expect(errors.contains("Failed to get device code: device login disabled\n"))
    }

    @Test(
        "enroll on macOS 27 or later explains App Attest and downloads no profile",
        .enabled(if: ProviderOnboardingPolicy.usesAppAttest(
            macOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion))
    )
    func enrollUsesAppAttest() async throws {
        let result = try await #require(
            processExitsWith: .success, observing: [\.standardOutputContent]
        ) {
            let sandbox = try CLICommandSandbox.enter()
            defer { sandbox.remove() }
            try await runCLICommand(Enroll.self, ["enroll", "--config", sandbox.config.path, "--no-open"])
            #expect(CoordinatorStub.requests.isEmpty)
        }
        #expect(decodedText(result.standardOutputContent).contains("""
            Darkbloom Device Attestation Enrollment
            Coordinator: https://coordinator.invalid

              \(ProviderOnboardingPolicy.retirementNotice)
              \(Enroll.eligibilityNotice)

              \(ProviderOnboardingPolicy.appAttestGuidance)

            """))
    }

    @Test("enroll parses its coordinator and no-open options")
    func enrollParses() throws {
        let enroll = try #require(try Darkbloom.parseAsRoot(
            ["enroll", "--coordinator", "https://override.invalid", "--no-open"]) as? Enroll)
        #expect(enroll.coordinator == "https://override.invalid")
        #expect(enroll.noOpen)
    }

    @Test("autoupdate prints the setting, changes it and rejects an unknown action")
    func autoUpdateRun() async throws {
        let result = try await #require(
            processExitsWith: .success, observing: [\.standardOutputContent]
        ) {
            let sandbox = try CLICommandSandbox.enter(autoUpdate: true)
            defer { sandbox.remove() }
            let config = sandbox.config.path
            try await runCLICommand(AutoUpdate.self, ["autoupdate", "status", "--config", config])
            try await runCLICommand(AutoUpdate.self, ["autoupdate", "OFF", "--config", config])
            #expect(try ConfigManager.load(from: sandbox.config).provider.autoUpdate == false)
            try await runCLICommand(AutoUpdate.self, ["autoupdate", "status", "--config", config])
            try await runCLICommand(AutoUpdate.self, ["autoupdate", "true", "--config", config])
            #expect(try ConfigManager.load(from: sandbox.config).provider.autoUpdate == true)
            let error = try await runFailingCLICommand(
                AutoUpdate.self, ["autoupdate", "sometimes", "--config", config])
            #expect((error as? ExitCode) == .failure)
            #expect(try ConfigManager.load(from: sandbox.config).provider.autoUpdate == true)
            print("CONFIG \(config)")
        }
        let output = decodedText(result.standardOutputContent)
        let config = try #require(printedValue(output, label: "CONFIG"))
        #expect(output.contains("""
            Auto-update is ENABLED
            Config: \(config)
            Auto-update DISABLED.
            Run 'darkbloom update' manually to install new releases.
            Auto-update is DISABLED
            Config: \(config)
            Auto-update ENABLED.
            The provider will check for new signed releases at startup.
            CONFIG \(config)

            """))
    }
}
