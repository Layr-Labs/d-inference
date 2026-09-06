import Foundation
import ProviderCoreFoundation
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import ProviderCore

@Suite("Launchctl executable path persistence")
struct LaunchctlControlTests {
    @Test("LaunchAgent and watchdog persist only the validated managed CLI", arguments: [true, false])
    func launchdArgumentsUseManagedCLI(nested: Bool) throws {
        let fixture = try LaunchctlPathFixture()
        defer { fixture.remove() }
        let executable = nested ? fixture.nestedCLI : fixture.legacyCLI
        try fixture.makeExecutable(at: executable)
        if nested {
            try fixture.makeCompatibilityLink()
        }
        let persistedPath = try LaunchctlControl.managedExecutablePath(homeDirectory: fixture.home)
        let providerArguments = LaunchAgent.serviceProgramArguments(
            binaryPath: persistedPath,
            coordinatorURL: "wss://api.darkbloom.dev/ws/provider",
            models: [],
            configPath: nil
        )
        let watchdogPlist = WatchdogAgent.makeWatchdogPlist(
            label: "io.darkbloom.watchdog",
            programArguments: [persistedPath, "watchdog"],
            logPath: "/tmp/watchdog.log"
        )
        let watchdogArguments = watchdogPlist["ProgramArguments"] as? [String]
        #expect(persistedPath == executable.path)
        #expect(providerArguments.first == executable.path)
        #expect(watchdogArguments?.first == executable.path)
        #expect(persistedPath.hasPrefix(fixture.home.appendingPathComponent(".darkbloom/").path))
        if nested {
            #expect(persistedPath != fixture.legacyCLI.path)
        }
        for sourcePath in [
            fixture.home.appendingPathComponent("Downloads/Darkbloom.app/Contents/MacOS/darkbloom").path,
            fixture.home.appendingPathComponent("Downloads/Darkbloom.app/Contents/Helpers/DarkbloomProvider.app/Contents/MacOS/darkbloom").path,
            "/private/var/folders/zz/AppTranslocation/ABC/d/Darkbloom.app/Contents/MacOS/darkbloom",
        ] {
            #expect(providerArguments.first != sourcePath)
            #expect(watchdogArguments?.first != sourcePath)
        }
    }

    @Test("Absent managed install cannot produce a persisted executable path")
    func missingInstall() throws {
        let fixture = try LaunchctlPathFixture()
        defer { fixture.remove() }
        #expect(throws: LaunchctlControl.ManagedExecutableUnavailable.self) {
            try LaunchctlControl.managedExecutablePath(homeDirectory: fixture.home)
        }
    }

    @Test("Malformed nested CLI cannot fall back to the regular flat binary", arguments: [true, false])
    func malformedHelper(symlinked: Bool) throws {
        let fixture = try LaunchctlPathFixture()
        defer { fixture.remove() }
        try fixture.makeExecutable(at: fixture.legacyCLI)
        if symlinked {
            let external = fixture.root.appendingPathComponent("external/darkbloom")
            try fixture.makeExecutable(at: external)
            try FileManager.default.createDirectory(at: fixture.nestedCLI.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: fixture.nestedCLI.path, withDestinationPath: external.path)
        } else {
            let helper = ManagedProviderInstallLayout.appURL(homeDirectory: fixture.home)
                .appendingPathComponent(ManagedProviderInstallLayout.helperAppRelativePath)
            try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)
        }
        #expect(throws: LaunchctlControl.ManagedExecutableUnavailable.self) {
            try LaunchctlControl.managedExecutablePath(homeDirectory: fixture.home)
        }
    }

    @Test("Launchd path selection rejects a symlinked managed root")
    func redirectedManagedRoot() throws {
        let fixture = try LaunchctlPathFixture()
        defer { fixture.remove() }
        try fixture.makeExecutable(at: fixture.nestedCLI)
        let managedRoot = fixture.home.appendingPathComponent(".darkbloom")
        let redirected = fixture.root.appendingPathComponent("redirected")
        try FileManager.default.moveItem(at: managedRoot, to: redirected)
        try FileManager.default.createSymbolicLink(atPath: managedRoot.path, withDestinationPath: redirected.path)
        #expect(throws: LaunchctlControl.ManagedExecutableUnavailable.self) {
            try LaunchctlControl.managedExecutablePath(homeDirectory: fixture.home)
        }
    }
}

private struct LaunchctlPathFixture {
    let root: URL
    let home: URL

    init() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchctl-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        guard let canonical = temporary.path.withCString({ realpath($0, nil) }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        defer { free(canonical) }
        root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        home = root.appendingPathComponent("Home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var nestedCLI: URL { ManagedProviderInstallLayout.cliURL(homeDirectory: home) }
    var legacyCLI: URL { ManagedProviderInstallLayout.legacyCLIURL(homeDirectory: home) }

    func makeExecutable(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func makeCompatibilityLink() throws {
        try FileManager.default.createDirectory(at: legacyCLI.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: legacyCLI.path,
            withDestinationPath: ManagedProviderInstallLayout.compatibilityCLISymlinkTarget
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
