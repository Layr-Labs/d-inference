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
            homeDirectory: URL(fileURLWithPath: "/tmp")
        )
        // No executable check for the explicit override — devs point at a
        // not-yet-chmod'ed path while iterating.
        #expect(locator.locate() == URL(fileURLWithPath: "/tmp/fake-darkbloom"))
    }

    @Test("Shipping lookup returns only the managed app CLI")
    func locatorUsesOnlyManagedAppCLI() throws {
        let fixture = try CLILocatorFixture()
        defer { fixture.remove() }
        try fixture.makeExecutable(at: fixture.sourceCLI)
        try fixture.makeExecutable(at: fixture.managedCLI)
        let locator = SystemDarkbloomCLILocator(
            environment: [:],
            homeDirectory: fixture.home
        )

        #expect(locator.locate() == fixture.managedCLI)
        #expect(locator.locate() != fixture.sourceCLI)
        #expect(locator.managedCLIURL == fixture.managedCLI)
    }

    @Test("A downloaded source CLI is never a shipping fallback")
    func locatorRejectsSourceBundleFallback() throws {
        let fixture = try CLILocatorFixture()
        defer { fixture.remove() }
        try fixture.makeExecutable(at: fixture.sourceCLI)

        let locator = SystemDarkbloomCLILocator(
            environment: [:],
            homeDirectory: fixture.home
        )

        #expect(locator.locate() == nil)
    }

    @Test("The managed CLI endpoint cannot be a symlink to a source bundle")
    func locatorRejectsManagedCLISymlink() throws {
        let fixture = try CLILocatorFixture()
        defer { fixture.remove() }
        try fixture.makeExecutable(at: fixture.sourceCLI)
        try FileManager.default.createDirectory(
            at: fixture.managedCLI.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: fixture.managedCLI.path,
            withDestinationPath: fixture.sourceCLI.path
        )

        let locator = SystemDarkbloomCLILocator(
            environment: [:],
            homeDirectory: fixture.home
        )

        #expect(locator.locate() == nil)
    }

    // MARK: Runner (real /bin processes)

    private func runner(executable: String) -> ProcessProviderCLIRunner {
        ProcessProviderCLIRunner(locator: SystemDarkbloomCLILocator(
            environment: [SystemDarkbloomCLILocator.environmentKey: executable],
            homeDirectory: URL(fileURLWithPath: "/tmp")
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

private struct CLILocatorFixture {
    let root: URL
    let home: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "darkbloom-cli-locator-\(UUID().uuidString)",
            isDirectory: true
        )
        home = root.appendingPathComponent("Home", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true
        )
    }

    var sourceCLI: URL {
        home.appendingPathComponent(
            "Downloads/Darkbloom.app/Contents/MacOS/darkbloom"
        )
    }

    var managedCLI: URL {
        home.appendingPathComponent(
            ".darkbloom/Darkbloom.app/Contents/MacOS/darkbloom"
        )
    }

    func makeExecutable(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
