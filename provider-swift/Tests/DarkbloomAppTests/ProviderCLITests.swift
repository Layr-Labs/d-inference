import Foundation
import Testing
@testable import DarkbloomApp

@Suite("Provider CLI locator + process runner")
struct ProviderCLITests {
    // MARK: Locator

    @Test("DARKBLOOM_CLI_PATH wins over every install location")
    func locatorPrefersEnvironmentOverride() {
        let locator = SystemDarkbloomCLILocator(
            environment: [SystemDarkbloomCLILocator.environmentKey: "/tmp/fake-darkbloom"],
            bundleURL: URL(fileURLWithPath: "/tmp/Darkbloom.app")
        )
        // No executable check for the explicit override — devs point at a
        // not-yet-chmod'ed path while iterating.
        #expect(locator.locate() == URL(fileURLWithPath: "/tmp/fake-darkbloom"))
    }

    @Test("With no override an unknown bundle yields nil when nothing is installed")
    func locatorFallsThrough() {
        let locator = SystemDarkbloomCLILocator(
            environment: [:],
            bundleURL: URL(fileURLWithPath: "/tmp/Nothing.app")
        )
        let located = locator.locate()
        if let located {
            // Real dev/CI boxes may have the CLI installed — then any located
            // path must be an executable darkbloom binary.
            #expect(located.lastPathComponent == "darkbloom")
            #expect(FileManager.default.isExecutableFile(atPath: located.path))
        }
    }

    // MARK: Runner (real /bin processes)

    private func runner(executable: String) -> ProcessProviderCLIRunner {
        ProcessProviderCLIRunner(locator: SystemDarkbloomCLILocator(
            environment: [SystemDarkbloomCLILocator.environmentKey: executable],
            bundleURL: URL(fileURLWithPath: "/tmp")
        ))
    }

    @Test("Successful exit returns status zero")
    func runnerSuccess() async throws {
        // /usr/bin/true: arguments irrelevant, exits 0.
        let result = try await runner(executable: "/usr/bin/true")
            .run(arguments: ["ignored"], timeout: .seconds(5))
        #expect(result.exitStatus == 0)
    }

    @Test("Non-zero exit surfaces the last stderr line")
    func runnerFailureMessage() async throws {
        do {
            _ = try await runner(executable: "/bin/sh")
                .run(arguments: ["-c", "echo first >&2; echo Boot-out failed >&2; exit 3"], timeout: .seconds(5))
            Issue.record("expected a non-zero exit error")
        } catch let error as ProviderCLIError {
            #expect(error == .exited(3, message: "Boot-out failed"))
        }
    }

    @Test("Timeout terminates the child and throws .timedOut")
    func runnerTimeout() async throws {
        do {
            _ = try await runner(executable: "/bin/sleep")
                .run(arguments: ["30"], timeout: .milliseconds(50))
            Issue.record("expected a timeout")
        } catch let error as ProviderCLIError {
            guard case .timedOut(let command) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(command == "30")
        }
    }

    @Test("Missing CLI throws cliNotFound before any exec attempt")
    func runnerMissingCLI() async throws {
        struct NoCLI: DarkbloomCLILocating {
            func locate() -> URL? { nil }
        }
        do {
            _ = try await ProcessProviderCLIRunner(locator: NoCLI())
                .run(arguments: ["stop"], timeout: .seconds(1))
            Issue.record("expected cliNotFound")
        } catch let error as ProviderCLIError {
            #expect(error == .cliNotFound)
        }
    }
}
