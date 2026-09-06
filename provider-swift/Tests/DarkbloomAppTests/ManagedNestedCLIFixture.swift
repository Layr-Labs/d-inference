import Foundation
import ProviderCoreFoundation
@testable import DarkbloomApp

/// Filesystem-only representation of the signed release layout. These inert
/// scripts and profile bytes exercise paths, not code-signature verification.
struct ManagedNestedCLIFixture {
    let root: URL
    let home: URL

    init() throws {
        root = try canonicalTestDirectory(prefix: "darkbloom-nested-cli")
        home = root.appendingPathComponent("Home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var app: URL { ManagedProviderInstallLayout.appURL(homeDirectory: home) }
    var helper: URL { app.appendingPathComponent(ManagedProviderInstallLayout.helperAppRelativePath) }
    var helpers: URL { helper.deletingLastPathComponent() }
    var nestedCLI: URL { ManagedProviderInstallLayout.cliURL(homeDirectory: home) }
    var legacyCLI: URL { ManagedProviderInstallLayout.legacyCLIURL(homeDirectory: home) }
    var locator: SystemDarkbloomCLILocator {
        SystemDarkbloomCLILocator(environment: [:], homeDirectory: home)
    }

    func makeNestedInstall(compatibilityLink: Bool = true) throws {
        try makeExecutable(at: nestedCLI)
        try makeExecutable(at: app.appendingPathComponent("Contents/MacOS/DarkbloomApp"))
        for (bundle, executable) in [(app, "DarkbloomApp"), (helper, "darkbloom")] {
            let info = [
                "CFBundleExecutable": executable,
                "CFBundleIdentifier": "io.darkbloom.provider",
                "CFBundleShortVersionString": "0.9.0",
                "CFBundleVersion": "0.9.0",
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
            try Data("fixture-profile".utf8).write(to: bundle.appendingPathComponent("Contents/embedded.provisionprofile"))
        }
        if compatibilityLink {
            try FileManager.default.createSymbolicLink(
                atPath: legacyCLI.path,
                withDestinationPath: ManagedProviderInstallLayout.compatibilityCLISymlinkTarget
            )
        }
    }

    func makeExecutable(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func component(_ relativePath: String) -> URL {
        relativePath.isEmpty ? home : home.appendingPathComponent(relativePath)
    }

    func redirectWithSymlink(_ target: URL) throws {
        let displaced = root.appendingPathComponent("displaced-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: target, to: displaced)
        try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: displaced.path)
    }

    func replace(_ target: URL) throws {
        // Keep the original alive so inode reuse cannot make this test flaky.
        let preserved = root.appendingPathComponent("preserved-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: target, to: preserved)
        try FileManager.default.copyItem(at: preserved, to: target)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
