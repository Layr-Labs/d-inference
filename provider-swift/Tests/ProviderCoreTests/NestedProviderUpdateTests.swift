import Foundation
import Testing
@testable import ProviderCore

@Suite("Nested signed-provider update layout")
struct NestedProviderUpdateTests {
    @Test("stage and records bind the real helper payload")
    func stageNestedPayload() throws {
        let fixture = try NestedProviderFixture()
        defer { fixture.cleanup() }
        let archive = try fixture.archive()
        let staged = try fixture.updater().stageBundleForTesting(
            from: archive.url, release: archive.release, installDir: fixture.installRoot).get()
        defer { staged.discard() }
        let app = try #require(staged.extractedApp)
        #expect(staged.installedBinary == app.appendingPathComponent(ProviderAppLayout.nestedBinaryRelativePath))
        #expect(staged.installedMetallib.deletingLastPathComponent() == staged.installedBinary.deletingLastPathComponent())
        #expect(staged.installedEnclave.deletingLastPathComponent() == staged.installedBinary.deletingLastPathComponent())
        #expect(staged.artifactModes.binary == 0o755)
        #expect(staged.artifactModes.metallib == 0o644)
        let store = UpdateRecoveryStore(installRoot: fixture.installRoot, verifyCodeSignatures: false)
        let record = try store.recordForStagedBundle(staged, generation: 1, now: 100)
        #expect(record.binaryHash == archive.release.binaryHash)
        #expect(record.metallibHash == archive.release.metallibHash)
        #expect(try store.stagingContainsTarget(staged.stagingRoot, target: record, layout: .app))
    }

    @Test("snapshot and restore preserve nested paths and exact alias")
    func snapshotRestore() throws {
        let fixture = try NestedProviderFixture()
        defer { fixture.cleanup() }
        let fm = FileManager.default
        try fm.createDirectory(at: fixture.installRoot, withIntermediateDirectories: true)
        let liveApp = fixture.installRoot.appendingPathComponent("Darkbloom.app")
        try fm.copyItem(at: fixture.app, to: liveApp)
        let store = UpdateRecoveryStore(installRoot: fixture.installRoot, verifyCodeSignatures: false)
        let predecessor = try store.snapshotLiveAsPredecessor(
            version: fixture.version, releaseBundleHash: nil, installGeneration: 1, now: 100)
        #expect(predecessor.layout == .app)
        #expect(predecessor.binaryPath == "predecessor/Darkbloom.app/" + ProviderAppLayout.nestedBinaryRelativePath)
        #expect(predecessor.metallibPath.contains("DarkbloomProvider.app/Contents/MacOS/mlx.metallib"))
        try store.verifyPredecessor(predecessor)
        try fm.removeItem(at: liveApp)
        #expect(try !store.liveMatches(predecessor.release, layout: .app))
        try store.restorePredecessorCopy(predecessor, stagingName: ".recovery-restore-test")
        #expect(try store.liveMatches(predecessor.release, layout: .app))
        #expect(try fm.destinationOfSymbolicLink(atPath: liveApp.appendingPathComponent(ProviderAppLayout.aliasRelativePath).path) == ProviderAppLayout.aliasTarget)
        #expect(fixture.installRoot.appendingPathComponent("bin/darkbloom").resolvingSymlinksInPath()
            == liveApp.appendingPathComponent(ProviderAppLayout.nestedBinaryRelativePath))
        var forged = predecessor
        forged.binaryPath = "predecessor/Darkbloom.app/Contents/MacOS/darkbloom"
        #expect(throws: (any Error).self) { try store.verifyPredecessor(forged) }
    }

    @Test("hash verification rejects a runtime metallib different from the registered release")
    func rejectsRuntimeMetallibMismatch() throws {
        let fixture = try NestedProviderFixture()
        defer { fixture.cleanup() }
        // Keep nested and outer copies equal to isolate the registered hash gate.
        for app in [fixture.app, fixture.helper] {
            try Data("tampered metallib".utf8).write(to: app.appendingPathComponent("Contents/MacOS/mlx.metallib"))
        }
        let archive = try fixture.archive()
        #expect(throws: UpdateError.self) {
            _ = try fixture.updater().stageBundleForTesting(
                from: archive.url, release: archive.release, installDir: fixture.installRoot).get()
        }
    }

    @Test("the outer copy cannot substitute for missing or redirected runtime files")
    func rejectsTamperedRuntimeTargets() throws {
        for relative in [
            "Contents/MacOS/darkbloom", "Contents/MacOS/darkbloom-enclave",
            "Contents/MacOS/mlx.metallib", "Contents/MacOS", "Contents/Resources",
            "Contents/Info.plist", "Contents/embedded.provisionprofile",
        ] {
            let fixture = try NestedProviderFixture()
            defer { fixture.cleanup() }
            let target = fixture.helper.appendingPathComponent(relative)
            let saved = fixture.root.appendingPathComponent("original")
            try FileManager.default.moveItem(at: target, to: saved)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: saved)
            #expect(throws: (any Error).self) { _ = try ProviderAppLayout(app: fixture.app) }
        }
    }

    @Test("alias bytes, target name, and all helper parents must be exact")
    func rejectsAliasesAndParents() throws {
        for target in [
            "../Helpers/Other.app/Contents/MacOS/darkbloom",
            "../Helpers/DarkbloomProvider.app/Contents/MacOS/./darkbloom",
            "../Helpers/DarkbloomProvider.app/Contents/MacOS/Darkbloom",
            "/tmp/darkbloom", "darkbloom", "../../../../outside",
        ] {
            let fixture = try NestedProviderFixture()
            defer { fixture.cleanup() }
            try FileManager.default.removeItem(at: fixture.alias)
            try FileManager.default.createSymbolicLink(atPath: fixture.alias.path, withDestinationPath: target)
            #expect(throws: (any Error).self) { _ = try ProviderAppLayout(app: fixture.app) }
        }
        for relative in ["Contents/Helpers", ProviderAppLayout.helperRelativePath, ProviderAppLayout.helperRelativePath + "/Contents"] {
            let fixture = try NestedProviderFixture()
            defer { fixture.cleanup() }
            let parent = fixture.app.appendingPathComponent(relative)
            let saved = fixture.root.appendingPathComponent("moved")
            try FileManager.default.moveItem(at: parent, to: saved)
            try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: saved)
            #expect(throws: (any Error).self) { _ = try ProviderAppLayout(app: fixture.app) }
        }
    }

    @Test("outer and helper identities, both version fields, and profiles are pinned")
    func rejectsMetadataTampering() throws {
        for nested in [false, true] {
            for key in ["CFBundleIdentifier", "CFBundleExecutable", "CFBundleShortVersionString", "CFBundleVersion"] {
                let fixture = try NestedProviderFixture()
                defer { fixture.cleanup() }
                try NestedProviderFixture.editInfo(app: nested ? fixture.helper : fixture.app, key: key, value: "wrong")
                #expect(throws: (any Error).self) { _ = try ProviderAppLayout(app: fixture.app, expectedVersion: fixture.version) }
            }
        }
        let fixture = try NestedProviderFixture()
        defer { fixture.cleanup() }
        try Data("different-profile".utf8).write(to: fixture.helper.appendingPathComponent("Contents/embedded.provisionprofile"))
        #expect(throws: (any Error).self) { _ = try ProviderAppLayout(app: fixture.app) }
    }

    @Test("post-stage mode and alias mutations cannot become release records")
    func rejectsPostStageMutation() throws {
        for mutateAlias in [false, true] {
            let fixture = try NestedProviderFixture()
            defer { fixture.cleanup() }
            let archive = try fixture.archive()
            let staged = try fixture.updater().stageBundleForTesting(
                from: archive.url, release: archive.release, installDir: fixture.installRoot).get()
            defer { staged.discard() }
            if mutateAlias {
                let alias = try #require(staged.extractedApp).appendingPathComponent(ProviderAppLayout.aliasRelativePath)
                try FileManager.default.removeItem(at: alias)
                try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: "../Helpers/Other.app/Contents/MacOS/darkbloom")
            } else {
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staged.installedBinary.path)
            }
            let store = UpdateRecoveryStore(installRoot: fixture.installRoot, verifyCodeSignatures: false)
            #expect(throws: (any Error).self) { _ = try store.recordForStagedBundle(staged, generation: 1, now: 100) }
        }
    }

    @Test("direct helper, outer compatibility alias, and bin invocation share one install root")
    func installRoot() throws {
        let fixture = try NestedProviderFixture()
        defer { fixture.cleanup() }
        let binAlias = fixture.root.appendingPathComponent("entry")
        try FileManager.default.createSymbolicLink(at: binAlias, withDestinationURL: fixture.alias)
        for executable in [fixture.binary, fixture.alias, binAlias] {
            #expect(SelfUpdater.installRoot(forExecutablePath: executable.path).path == fixture.source.path)
        }
        #expect(SelfUpdater.installRoot(forExecutablePath: "/Users/provider/.darkbloom/Darkbloom.app/Contents/MacOS/darkbloom").path == "/Users/provider/.darkbloom")
        #expect(SelfUpdater.installRoot(forExecutablePath: "/Users/provider/.darkbloom/bin/darkbloom").path == "/Users/provider/.darkbloom")
    }

    @Test("fan checks use the outer app even when the CLI is nested")
    func fanHelperOuterBundle() throws {
        let fixture = try NestedProviderFixture()
        defer { fixture.cleanup() }
        try FanHelperCapabilityVerifier.verify(app: fixture.app, executable: fixture.binary, signaturePolicy: nil)
        #expect(throws: UpdateError.self) {
            try FanHelperCapabilityVerifier.verify(app: fixture.helper, executable: fixture.binary, signaturePolicy: nil)
        }
        try Data(FanHelperCapabilityVerifier.binaryCapability.utf8).write(to: fixture.binary)
        let outerMarker = fixture.app.appendingPathComponent(FanHelperCapabilityVerifier.markerRelativePath)
        try FileManager.default.createDirectory(at: outerMarker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("1".utf8).write(to: outerMarker)
        let outerHelper = fixture.app.appendingPathComponent(FanHelperCapabilityVerifier.helperRelativePath)
        try Data("fan helper".utf8).write(to: outerHelper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outerHelper.path)
        try FanHelperCapabilityVerifier.verify(app: fixture.app, executable: fixture.binary, signaturePolicy: nil)
    }
}

extension NestedProviderUpdateTests {
    @Test("journal replay upgrades an older nested install after a pre-swap interruption")
    func replayOlderNestedInstall() throws {
        struct Interruption: Error {}
        let fixture = try NestedProviderFixture()
        defer { fixture.cleanup() }
        try UpdateRecoveryFixture.writeApp(version: "0.8.10", root: fixture.installRoot)
        try NestedProviderFixture.nest(app: fixture.installRoot.appendingPathComponent("Darkbloom.app"), version: "0.8.10")
        let archive = try fixture.archive()
        let staged = try fixture.updater().stageBundleForTesting(
            from: archive.url, release: archive.release, installDir: fixture.installRoot).get()
        defer { staged.discard() }
        let interrupted = UpdateRecoveryStore(
            installRoot: fixture.installRoot, verifyCodeSignatures: false,
            faultInjector: { if $0 == .transactionPersisted { throw Interruption() } })
        #expect(throws: Interruption.self) {
            try interrupted.commit(staged: staged, currentVersion: "0.8.10", now: 100)
        }
        let resumed = UpdateRecoveryStore(installRoot: fixture.installRoot, verifyCodeSignatures: false)
        try resumed.recoverInterruptedTransaction(now: 101)
        let state = try resumed.loadState()
        let candidate = try #require(state.candidate).release
        #expect(candidate.version == fixture.version)
        #expect(try resumed.liveMatches(candidate, layout: .app))
        #expect(state.predecessor?.release.version == "0.8.10")
    }

    @Test("legacy app and bin predecessor records remain restorable")
    func legacyRecoveryCompatibility() throws {
        for layout in [VerifiedPredecessor.Layout.app, .flat] {
            let fixture = try UpdateRecoveryFixture(layout: layout)
            defer { fixture.cleanup() }
            let store = UpdateRecoveryStore(installRoot: fixture.installRoot, verifyCodeSignatures: false)
            let predecessor = try store.snapshotLiveAsPredecessor(
                version: fixture.oldVersion, releaseBundleHash: nil, installGeneration: 1, now: 100)
            #expect(predecessor.layout == layout)
            #expect(!predecessor.binaryPath.contains("DarkbloomProvider.app"))
            try store.verifyPredecessor(predecessor)
            try store.restorePredecessorCopy(predecessor, stagingName: ".recovery-restore-test")
            #expect(try store.liveMatches(predecessor.release, layout: layout))
        }
    }
}
