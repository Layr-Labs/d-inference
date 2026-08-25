import Foundation
import Testing
@testable import DarkbloomApp

@Suite("Provider CLI locator + process runner")
struct ProviderCLITests {
    private static let redirectableManagedComponents = [
        ".darkbloom",
        "Darkbloom.app",
        "Contents",
        "MacOS",
        "darkbloom",
    ]

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

    @Test("Shipping lookup accepts the canonical all-regular managed app CLI")
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

    @Test(
        "Every managed path component rejects symbolic-link redirection",
        arguments: redirectableManagedComponents
    )
    func locatorRejectsManagedPathSymlink(component: String) throws {
        let fixture = try CLILocatorFixture()
        defer { fixture.remove() }
        try fixture.makeExecutable(at: fixture.managedCLI)
        try fixture.redirectManagedComponentWithSymlink(component)

        let locator = SystemDarkbloomCLILocator(
            environment: [:],
            homeDirectory: fixture.home
        )

        #expect(locator.locate() == nil)
    }

    @Test("A symbolic link above the home directory cannot redirect lookup")
    func locatorRejectsSymlinkedHomeAncestor() throws {
        let fixture = try CLILocatorFixture()
        defer { fixture.remove() }
        try fixture.makeExecutable(at: fixture.managedCLI)
        let redirectedHome = try fixture.makeSymlinkedHomeAncestor()

        let locator = SystemDarkbloomCLILocator(
            environment: [:],
            homeDirectory: redirectedHome
        )

        #expect(locator.locate() == nil)
    }

    @Test("A managed directory replaced between identity passes is rejected")
    func locatorRejectsManagedDirectoryReplacementRace() throws {
        let fixture = try CLILocatorFixture()
        defer { fixture.remove() }
        try fixture.makeExecutable(at: fixture.managedCLI)

        let located = try ManagedCLIPathValidator().validatedCLIURL(
            homeDirectory: fixture.home
        ) {
            try fixture.replaceManagedComponent("Darkbloom.app")
        }

        #expect(located == nil)
    }

    @Test("The executable replaced between identity passes is rejected")
    func locatorRejectsExecutableReplacementRace() throws {
        let fixture = try CLILocatorFixture()
        defer { fixture.remove() }
        try fixture.makeExecutable(at: fixture.managedCLI)

        let located = try ManagedCLIPathValidator().validatedCLIURL(
            homeDirectory: fixture.home
        ) {
            try fixture.replaceManagedComponent("darkbloom")
        }

        #expect(located == nil)
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
        let unresolvedRoot =
            FileManager.default.temporaryDirectory.appendingPathComponent(
                "darkbloom-cli-locator-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: unresolvedRoot,
            withIntermediateDirectories: true
        )
        // `temporaryDirectory` commonly starts with `/var`, a macOS symlink.
        // Resolve the fixture root so tests exercise the same no-symlink
        // ancestor policy as a real `/Users/<name>` home directory.
        root = unresolvedRoot.resolvingSymlinksInPath()
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

    func redirectManagedComponentWithSymlink(_ component: String) throws {
        let target = try managedComponent(named: component)
        let redirected = root.appendingPathComponent(
            "redirected-\(component.replacingOccurrences(of: ".", with: "_"))-\(UUID().uuidString)"
        )
        try FileManager.default.moveItem(at: target, to: redirected)
        try FileManager.default.createSymbolicLink(
            atPath: target.path,
            withDestinationPath: redirected.path
        )
    }

    func replaceManagedComponent(_ component: String) throws {
        let target = try managedComponent(named: component)
        let preserved = root.appendingPathComponent(
            "preserved-\(component.replacingOccurrences(of: ".", with: "_"))-\(UUID().uuidString)"
        )
        try FileManager.default.moveItem(at: target, to: preserved)
        try makeExecutable(at: managedCLI)
    }

    func makeSymlinkedHomeAncestor() throws -> URL {
        let linkedParent = root.appendingPathComponent(
            "linked-home-parent",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: linkedParent.path,
            withDestinationPath: root.path
        )
        return linkedParent.appendingPathComponent("Home", isDirectory: true)
    }

    private func managedComponent(named component: String) throws -> URL {
        switch component {
        case ".darkbloom":
            home.appendingPathComponent(".darkbloom", isDirectory: true)
        case "Darkbloom.app":
            home.appendingPathComponent(
                ".darkbloom/Darkbloom.app",
                isDirectory: true
            )
        case "Contents":
            home.appendingPathComponent(
                ".darkbloom/Darkbloom.app/Contents",
                isDirectory: true
            )
        case "MacOS":
            managedCLI.deletingLastPathComponent()
        case "darkbloom":
            managedCLI
        default:
            throw UnknownManagedComponent(name: component)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct UnknownManagedComponent: Error {
    let name: String
}
