import ArgumentParser
import Darwin
import Foundation
import Testing
import TOMLKit
@testable import darkbloom
@testable import ProviderCore

@Suite("Lifecycle recovery rollback")
struct LifecycleRecoveryRollbackTests {
    enum PreviousSelection: CaseIterable, Sendable {
        case pinned, unpinned, missing

        var content: Data? {
            guard self != .missing else { return nil }
            let selection = self == .pinned ? "enabled_models = ['old-a', 'old-b']\n" : ""
            return Data(("# Keep operator comments and legacy selection semantics.\n"
                + "[provider]\nname = 'prior-provider'\n\n"
                + "[backend]\nmodel = 'legacy-selection'\nidle_timeout_mins = 60\n"
                + selection).utf8)
        }
    }

    enum SetupFailure: CaseIterable, Sendable {
        case disable, publication
    }

    struct Fixture {
        let root: URL
        let configPath: URL
        let recoveryPath: URL
        let original: Data?
        let mailbox: LifecycleMailbox
        let request: ProviderDrainRequest
        let fallbackConfig = ProviderConfig(provider: ProviderSettings(name: "resolved-custom-provider"))

        init(previous: PreviousSelection = .pinned) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            configPath = root.appendingPathComponent("provider.toml")
            recoveryPath = root.appendingPathComponent("recovery-state")
            original = previous.content
            let identity = try #require(ProcessIdentity.current())
            mailbox = LifecycleMailbox(identity: identity, directory: root.appendingPathComponent("lifecycle"))
            request = ProviderDrainRequest(target: identity, timeoutSeconds: 0)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try original?.write(to: configPath)
            try Data("enabled".utf8).write(to: recoveryPath)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func expectOriginalSelection() throws {
            if let original {
                #expect(try Data(contentsOf: configPath) == original)
                let config = try ConfigManager.load(from: configPath)
                let wasPinned = tomlKeyPresent(String(decoding: original, as: UTF8.self),
                    section: "backend", key: "enabled_models")
                #expect(config.backend.enabledModels == (wasPinned ? ["old-a", "old-b"] : []))
                #expect(config.backend.model == "legacy-selection")
            } else {
                #expect(!FileManager.default.fileExists(atPath: configPath.path))
            }
        }
    }

    @Test func unwritableSelectionDoesNotPublishDrainOrDisableRecovery() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // A real save failure, after the original config has been read and the
        // sidecar acquired; immutability also makes this deterministic as root.
        try #require(chflags(fixture.configPath.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(fixture.configPath.path, 0) }
        #expect(throws: ConfigError.self) {
            try ProviderModelSelection.withReplacement(["replacement"], configPath: fixture.configPath, fallbackConfig: fixture.fallbackConfig) {
                try ServiceDrain.publishWithRecoveryRollback(disable: {
                    try Data("disabled".utf8).write(to: fixture.recoveryPath)
                }, publish: {
                    try fixture.mailbox.writeRequest(fixture.request)
                }, restore: {
                    // An untouched recovery configuration must not be rewritten.
                    try Data("restored".utf8).write(to: fixture.recoveryPath)
                })
            }
        }
        #expect(fixture.mailbox.readRequest() == nil)
        #expect(try String(contentsOf: fixture.recoveryPath, encoding: .utf8) == "enabled")
        try fixture.expectOriginalSelection()
        #expect(fixture.request.target.isCurrent())
    }

    @Test(arguments: PreviousSelection.allCases, SetupFailure.allCases)
    func failedSetupRestoresExactSelectionAndRecovery(previous: PreviousSelection, failure: SetupFailure) throws {
        let fixture = try Fixture(previous: previous)
        defer { fixture.remove() }
        let blocker = fixture.root.appendingPathComponent("not-a-directory")
        try Data("keep".utf8).write(to: blocker)
        if failure == .publication {
            // Force the real mailbox publisher to reject its destination.
            try Data("keep".utf8).write(to: fixture.mailbox.directory)
        }
        #expect(throws: (any Error).self) {
            try ProviderModelSelection.withReplacement(["replacement"], configPath: fixture.configPath, fallbackConfig: fixture.fallbackConfig) {
                try ServiceDrain.publishWithRecoveryRollback(disable: {
                    #expect(try ConfigManager.load(from: fixture.configPath).backend.enabledModels == ["replacement"])
                    try Data("disabled".utf8).write(to: fixture.recoveryPath)
                    if failure == .disable {
                        try Data().write(to: blocker.appendingPathComponent("cannot-disable"))
                    }
                }, publish: {
                    try fixture.mailbox.writeRequest(fixture.request)
                }, restore: {
                    try Data("enabled".utf8).write(to: fixture.recoveryPath)
                })
            }
        }
        try fixture.expectOriginalSelection()
        #expect(try String(contentsOf: fixture.recoveryPath, encoding: .utf8) == "enabled")
        #expect(fixture.mailbox.readRequest() == nil)
        #expect(fixture.request.target.isCurrent())
    }

    @Test(arguments: PreviousSelection.allCases)
    func failedRecoveryRestorationStillRestoresSelection(previous: PreviousSelection) throws {
        let fixture = try Fixture(previous: previous)
        defer { fixture.remove() }
        try Data("not-a-directory".utf8).write(to: fixture.mailbox.directory)
        let recoveryError = CocoaError(.fileWriteNoPermission)
        #expect(throws: ValidationError.self) {
            try ProviderModelSelection.withReplacement(["replacement"], configPath: fixture.configPath, fallbackConfig: fixture.fallbackConfig) {
                try ServiceDrain.publishWithRecoveryRollback(disable: {
                    try Data("disabled".utf8).write(to: fixture.recoveryPath)
                }, publish: {
                    try fixture.mailbox.writeRequest(fixture.request)
                }, restore: { throw recoveryError })
            }
        }
        try fixture.expectOriginalSelection()
        #expect(try String(contentsOf: fixture.recoveryPath, encoding: .utf8) == "disabled")
        #expect(fixture.mailbox.readRequest() == nil)
    }

    @Test func selectionRestorationFailureSurfacesSetupAndRecoveryErrors() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let setupError = CocoaError(.fileWriteOutOfSpace)
        let recoveryError = CocoaError(.fileWriteNoPermission)
        do {
            try ProviderModelSelection.withReplacement(["replacement"], configPath: fixture.configPath, fallbackConfig: fixture.fallbackConfig) {
                try ServiceDrain.publishWithRecoveryRollback(disable: {
                    try Data("disabled".utf8).write(to: fixture.recoveryPath)
                }, publish: {
                    // Make config restoration fail independently of the two
                    // lifecycle failures, without injecting a fake config store.
                    try FileManager.default.removeItem(at: fixture.configPath)
                    try FileManager.default.createDirectory(at: fixture.configPath, withIntermediateDirectories: false)
                    throw setupError
                }, restore: { throw recoveryError })
            }
            Issue.record("Failed config restoration was not reported")
        } catch let error as ProviderModelSelection.ReplacementRollbackError {
            #expect(error.configPath == fixture.configPath)
            #expect(error.setupError is ValidationError)
            #expect((error.restorationError as NSError).domain == NSCocoaErrorDomain)
        }
        #expect(fixture.mailbox.readRequest() == nil)
        #expect(try String(contentsOf: fixture.recoveryPath, encoding: .utf8) == "disabled")
    }

    @Test func publishedTimeoutKeepsReplacementAndRecoveryDisabled() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try ProviderModelSelection.withReplacement(["replacement"], configPath: fixture.configPath, fallbackConfig: fixture.fallbackConfig) {
            try ServiceDrain.publishWithRecoveryRollback(disable: {
                try Data("disabled".utf8).write(to: fixture.recoveryPath)
            }, publish: {
                try fixture.mailbox.writeRequest(fixture.request)
            }, restore: {
                try Data("enabled".utf8).write(to: fixture.recoveryPath)
            })
        }
        #expect(fixture.mailbox.readRequest()?.id == fixture.request.id)
        #expect(try ConfigManager.load(from: fixture.configPath).backend.enabledModels == ["replacement"])
        // The config lease is gone before waiting: unrelated operator writes
        // remain possible even while the published provider drain is fenced.
        try setIdleUnloadMinutes(45, configPath: fixture.configPath.path, migrateOnDisk: false)
        try fixture.mailbox.writeStatus(.init(requestID: fixture.request.id, outcome: .timedOut, remaining: 1))
        await #expect(throws: (any Error).self) {
            try await ServiceDrain.wait(request: fixture.request, mailbox: fixture.mailbox)
        }
        let config = try ConfigManager.load(from: fixture.configPath)
        #expect(config.backend.enabledModels == ["replacement"])
        #expect(config.backend.idleTimeoutMins == 45)
        #expect(try String(contentsOf: fixture.recoveryPath, encoding: .utf8) == "disabled")
        #expect(fixture.request.target.isCurrent())
    }

    @Test func replacementLeasePreservesConcurrentUnrelatedWrites() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let beginWriter = DispatchSemaphore(value: 0)
        let attemptedLock = DispatchSemaphore(value: 0)
        let (writer, completion) = AsyncThrowingStream<(Int32, Int32), Error>.makeStream()
        DispatchQueue.global().async {
            do {
                try #require(beginWriter.wait(timeout: .now() + 5) == .success)
                let fd = open(fixture.configPath.path + ".lock", O_RDWR)
                try #require(fd >= 0)
                defer { close(fd) }
                let result = flock(fd, LOCK_EX | LOCK_NB)
                let lockError = errno
                if result == 0 { _ = flock(fd, LOCK_UN) }
                attemptedLock.signal()
                try setIdleUnloadMinutes(45, configPath: fixture.configPath.path, migrateOnDisk: false)
                try setBetaFeature("mtp", enabled: false, configPath: fixture.configPath.path, migrateOnDisk: false)
                completion.yield((result, lockError))
                completion.finish()
            } catch {
                completion.finish(throwing: error)
            }
        }
        let failure = CocoaError(.fileWriteNoPermission)
        #expect(throws: CocoaError.self) {
            try ProviderModelSelection.withReplacement(["replacement"], configPath: fixture.configPath, fallbackConfig: fixture.fallbackConfig) {
                try ServiceDrain.publishWithRecoveryRollback(disable: {
                    try Data("disabled".utf8).write(to: fixture.recoveryPath)
                    beginWriter.signal()
                    try #require(attemptedLock.wait(timeout: .now() + 5) == .success)
                    throw failure
                }, publish: {
                    try fixture.mailbox.writeRequest(fixture.request)
                }, restore: {
                    try Data("enabled".utf8).write(to: fixture.recoveryPath)
                })
            }
        }
        var results = writer.makeAsyncIterator()
        let (result, lockError) = try #require(try await results.next())
        #expect(result == -1)
        #expect(lockError == EWOULDBLOCK)
        let config = try ConfigManager.load(from: fixture.configPath)
        #expect(config.backend.enabledModels == ["old-a", "old-b"])
        #expect(config.backend.idleTimeoutMins == 45)
        #expect(config.backend.mtpMode == .off)
        #expect(config.provider.name == "prior-provider")
        #expect(try String(contentsOf: fixture.recoveryPath, encoding: .utf8) == "enabled")
        #expect(fixture.mailbox.readRequest() == nil)
    }

    @Test(arguments: PreviousSelection.allCases)
    func liveRollbackPreservesConcurrentSettingsAndLegacyArgv(previous: PreviousSelection) throws {
        let fixture = try Fixture(previous: previous)
        defer { fixture.remove() }
        let replacement = try ProviderModelSelection.stageReplacement(["replacement"],
            configPath: fixture.configPath, fallbackConfig: fixture.fallbackConfig)
        let fd = open(fixture.configPath.path + ".lock", O_RDWR)
        try #require(fd >= 0)
        defer { close(fd) }
        try #require(flock(fd, LOCK_EX | LOCK_NB) == 0, "No lease may span the coordinator wait")
        _ = flock(fd, LOCK_UN)
        try setIdleUnloadMinutes(45, configPath: fixture.configPath.path, migrateOnDisk: false)
        try setBetaFeature("mtp", enabled: false, configPath: fixture.configPath.path, migrateOnDisk: false)
        try withExclusiveConfigLock(at: fixture.configPath) {
            let content = try String(contentsOf: fixture.configPath, encoding: .utf8)
            try (content + "\n[operator_metadata]\nnote = '''enabled_models = [\"not-a-selection\"]'''\n")
                .write(to: fixture.configPath, atomically: true, encoding: .utf8)
        }
        try ProviderModelSelection.restore(replacement)
        let config = try ConfigManager.load(from: fixture.configPath)
        #expect(config.backend.idleTimeoutMins == 45)
        #expect(config.backend.mtpMode == .off)
        #expect(config.backend.enabledModels == (previous == .pinned ? ["old-a", "old-b"] : []))
        let content = try String(contentsOf: fixture.configPath, encoding: .utf8)
        let table = try TOMLTable(string: content)
        #expect(table["operator_metadata"]?.table?["note"]?.string == "enabled_models = [\"not-a-selection\"]")
        let pinned = Start.usesPinnedModelSelection(configPath: fixture.configPath, launchManaged: true)
        #expect(pinned == (previous == .pinned))
        let models = ["old-a", "old-b", "legacy-argv", "replacement"].map {
            ModelInfo(id: $0, sizeBytes: 1, estimatedMemoryGb: 1)
        }
        let restarted = advertisedModels(from: models, config: config,
            modelOverrides: pinned ? [] : ["legacy-argv"])
        #expect(restarted.map(\.id) == (previous == .pinned ? ["old-a", "old-b"] : ["legacy-argv"]))
    }

    @Test(arguments: [false, true])
    func liveRollbackDoesNotOverwriteNewerSelection(removed: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let replacement = try ProviderModelSelection.stageReplacement(["replacement"],
            configPath: fixture.configPath, fallbackConfig: fixture.fallbackConfig)
        if removed {
            try FileManager.default.removeItem(at: fixture.configPath)
        } else {
            try ProviderModelSelection.save(["newer-operator-selection"],
                configPath: fixture.configPath, fallbackConfig: fixture.fallbackConfig)
        }
        let current = removed ? nil : try Data(contentsOf: fixture.configPath)
        #expect(throws: ProviderModelSelection.SelectionConflict.self) {
            try ProviderModelSelection.restore(replacement)
        }
        if let current {
            #expect(try Data(contentsOf: fixture.configPath) == current)
        } else {
            #expect(!FileManager.default.fileExists(atPath: fixture.configPath.path))
        }
    }

    @Test(arguments: [false, true])
    func missingCustomConfigUsesResolvedSnapshot(synchronousSetup: Bool) throws {
        let fixture = try Fixture(previous: .missing)
        defer { fixture.remove() }
        var resolved = fixture.fallbackConfig
        resolved.provider.autoRestart = false
        resolved.provider.autoUpdate = false
        resolved.coordinator = .init(url: "wss://custom.invalid/ws/provider", heartbeatIntervalSecs: 23, privateOnly: true)
        resolved.backend.idleTimeoutMins = 17
        resolved.backend.port = 8234
        resolved.backend.mtpMode = .off
        resolved.schedule = .init(enabled: true, windows: [.init(days: ["mon"], start: "10:00", end: "11:00")])
        if synchronousSetup {
            try ProviderModelSelection.withReplacement(["replacement"], configPath: fixture.configPath,
                fallbackConfig: resolved) {}
        } else {
            _ = try ProviderModelSelection.stageReplacement(["replacement"], configPath: fixture.configPath,
                fallbackConfig: resolved)
        }
        resolved.backend.enabledModels = ["replacement"]
        #expect(try ConfigManager.load(from: fixture.configPath) == resolved)
    }

    @Test func startAndUpdateExposeExplicitReplacementPolicy() throws {
        let start = try Start.parse(["--timeout", "50", "--force", "--model", "chosen"])
        #expect(start.drain.timeout == 50 && start.drain.force)
        let update = try Update.parse(["--check-only"])
        #expect(update.drain.timeout == 600 && !update.drain.force)
    }
}
