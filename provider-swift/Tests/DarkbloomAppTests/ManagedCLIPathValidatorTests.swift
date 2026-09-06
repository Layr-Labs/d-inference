import Foundation
import ProviderCoreFoundation
import Testing
@testable import DarkbloomApp

@Suite("Nested managed CLI validation")
struct ManagedCLIPathValidatorTests {
    private static let components = [
        "",
        ".darkbloom",
        ".darkbloom/Darkbloom.app",
        ".darkbloom/Darkbloom.app/Contents",
        ".darkbloom/Darkbloom.app/Contents/Helpers",
        ".darkbloom/Darkbloom.app/Contents/Helpers/DarkbloomProvider.app",
        ".darkbloom/Darkbloom.app/Contents/Helpers/DarkbloomProvider.app/Contents",
        ".darkbloom/Darkbloom.app/Contents/Helpers/DarkbloomProvider.app/Contents/MacOS",
        ".darkbloom/Darkbloom.app/Contents/Helpers/DarkbloomProvider.app/Contents/MacOS/darkbloom",
    ]

    @Test("Nested CLI takes precedence over the outer compatibility entry", arguments: [true, false])
    func nestedCLI(compatibilityLink: Bool) throws {
        let fixture = try ManagedNestedCLIFixture()
        defer { fixture.remove() }
        try fixture.makeNestedInstall(compatibilityLink: compatibilityLink)
        if !compatibilityLink {
            try fixture.makeExecutable(at: fixture.legacyCLI)
        }
        let locator = fixture.locator
        #expect(locator.locate() == fixture.nestedCLI)
        #expect(locator.managedCLIURL == fixture.nestedCLI)
        #expect(locator.locate() != fixture.legacyCLI)
        if compatibilityLink {
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.legacyCLI.path)
                == "../Helpers/DarkbloomProvider.app/Contents/MacOS/darkbloom")
        }
        let recovery = AppInstallationRecovery(destination: fixture.app, preservedForeignApp: nil)
        #expect(recovery.managedCLIURL == fixture.nestedCLI)
    }

    @Test("Regular flat CLI still works when Helpers holds an unrelated helper")
    func legacyWithUnrelatedHelper() throws {
        let fixture = try ManagedNestedCLIFixture()
        defer { fixture.remove() }
        try fixture.makeExecutable(at: fixture.legacyCLI)
        try fixture.makeExecutable(at: fixture.helpers.appendingPathComponent("darkbloom-fan-helper"))
        #expect(fixture.locator.locate() == fixture.legacyCLI)
        let recovery = AppInstallationRecovery(destination: fixture.app, preservedForeignApp: nil)
        #expect(recovery.managedCLIURL == fixture.legacyCLI)
    }

    @Test("Every nested CLI ancestor and leaf rejects symlink redirection", arguments: components)
    func symlinkedComponent(relativePath: String) throws {
        let fixture = try ManagedNestedCLIFixture()
        defer { fixture.remove() }
        try fixture.makeNestedInstall(compatibilityLink: false)
        // Leave a usable flat binary: an invalid helper must not enable fallback.
        try fixture.makeExecutable(at: fixture.legacyCLI)
        try fixture.redirectWithSymlink(fixture.component(relativePath))
        #expect(fixture.locator.locate() == nil)
    }

    @Test("A symlink above the nested install home is rejected")
    func symlinkedHomeAncestor() throws {
        let fixture = try ManagedNestedCLIFixture()
        defer { fixture.remove() }
        try fixture.makeNestedInstall()
        let parentAlias = fixture.root.appendingPathComponent("linked-parent")
        try FileManager.default.createSymbolicLink(atPath: parentAlias.path, withDestinationPath: fixture.root.path)
        let locator = SystemDarkbloomCLILocator(
            environment: [:], homeDirectory: parentAlias.appendingPathComponent("Home")
        )
        #expect(locator.locate() == nil)
    }

    @Test("Replacing any nested component between complete snapshots is rejected", arguments: components)
    func replacementRace(relativePath: String) throws {
        let fixture = try ManagedNestedCLIFixture()
        defer { fixture.remove() }
        try fixture.makeNestedInstall()
        let result = try ManagedCLIPathValidator().validatedCLIURL(homeDirectory: fixture.home) {
            try fixture.replace(fixture.component(relativePath))
        }
        #expect(result == nil)
    }

    @Test("Partial nested layout cannot fall back to a usable flat binary", arguments: [
        "helper-file", "helpers-file", "helper-dangling-link", "helpers-dangling-link",
        "missing-contents", "missing-macos", "missing-cli", "cli-directory", "cli-not-executable",
    ])
    func malformedHelper(kind: String) throws {
        let fixture = try ManagedNestedCLIFixture()
        defer { fixture.remove() }
        try fixture.makeNestedInstall(compatibilityLink: false)
        try fixture.makeExecutable(at: fixture.legacyCLI)
        let fm = FileManager.default
        switch kind {
        case "helper-file", "helpers-file":
            let target = kind == "helper-file" ? fixture.helper : fixture.helpers
            try fm.removeItem(at: target)
            try Data("invalid directory".utf8).write(to: target)
        case "helper-dangling-link", "helpers-dangling-link":
            let target = kind == "helper-dangling-link" ? fixture.helper : fixture.helpers
            try fm.removeItem(at: target)
            try fm.createSymbolicLink(atPath: target.path, withDestinationPath: fixture.root.appendingPathComponent("missing").path)
        case "missing-contents":
            try fm.removeItem(at: fixture.helper.appendingPathComponent("Contents"))
        case "missing-macos":
            try fm.removeItem(at: fixture.nestedCLI.deletingLastPathComponent())
        case "missing-cli":
            try fm.removeItem(at: fixture.nestedCLI)
        case "cli-directory":
            try fm.removeItem(at: fixture.nestedCLI)
            try fm.createDirectory(at: fixture.nestedCLI, withIntermediateDirectories: false)
        case "cli-not-executable":
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.nestedCLI.path)
        default:
            Issue.record("unknown malformed fixture")
        }
        #expect(fixture.locator.locate() == nil)
    }

    @Test("Introducing the nested helper between legacy snapshots is rejected")
    func helperAppearsDuringLegacyValidation() throws {
        let fixture = try ManagedNestedCLIFixture()
        defer { fixture.remove() }
        try fixture.makeExecutable(at: fixture.legacyCLI)
        let result = try ManagedCLIPathValidator().validatedCLIURL(homeDirectory: fixture.home) {
            try fixture.makeNestedInstall(compatibilityLink: false)
        }
        #expect(result == nil)
    }

    @Test("Removing the nested helper cannot downgrade to legacy during validation")
    func helperDisappearsDuringNestedValidation() throws {
        let fixture = try ManagedNestedCLIFixture()
        defer { fixture.remove() }
        try fixture.makeNestedInstall(compatibilityLink: false)
        try fixture.makeExecutable(at: fixture.legacyCLI)
        let result = try ManagedCLIPathValidator().validatedCLIURL(homeDirectory: fixture.home) {
            try FileManager.default.removeItem(at: fixture.helper)
        }
        #expect(result == nil)
    }

    @Test("Legacy snapshots include the inspected Helpers directory identity")
    func legacyHelpersReplacementRace() throws {
        let fixture = try ManagedNestedCLIFixture()
        defer { fixture.remove() }
        try fixture.makeExecutable(at: fixture.legacyCLI)
        try FileManager.default.createDirectory(at: fixture.helpers, withIntermediateDirectories: true)
        let result = try ManagedCLIPathValidator().validatedCLIURL(homeDirectory: fixture.home) {
            try fixture.replace(fixture.helpers)
        }
        #expect(result == nil)
    }

    @Test("PATH and downloaded nested bundles never become managed fallbacks")
    func noSourceOrPATHFallback() throws {
        let fixture = try ManagedNestedCLIFixture()
        defer { fixture.remove() }
        let downloaded = fixture.home.appendingPathComponent(
            "Downloads/Darkbloom.app/Contents/Helpers/DarkbloomProvider.app/Contents/MacOS/darkbloom"
        )
        let pathCLI = fixture.home.appendingPathComponent("bin/darkbloom")
        try fixture.makeExecutable(at: downloaded)
        try fixture.makeExecutable(at: pathCLI)
        let locator = SystemDarkbloomCLILocator(
            environment: ["PATH": pathCLI.deletingLastPathComponent().path], homeDirectory: fixture.home
        )
        #expect(locator.locate() == nil)
    }
}
