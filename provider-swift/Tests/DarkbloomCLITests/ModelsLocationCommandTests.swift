import ArgumentParser
import Foundation
import ProviderCore
import Testing
#if canImport(Darwin)
import Darwin
#endif

@testable import darkbloom

@Suite("Model-cache location command")
struct ModelsLocationCommandTests {
    private struct Fixture {
        let root: URL
        let config: URL
        let current: URL
        let selected: URL
        let home: URL

        init() throws {
            // Use a canonical fixture root so /var and /private/var aliases do
            // not obscure which cache the command selected.
            let temporary = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
            defer { free(temporary) }
            root = URL(fileURLWithPath: String(cString: temporary), isDirectory: true)
                .appendingPathComponent("model-location-\(UUID().uuidString)")
            config = root.appendingPathComponent("provider.toml")
            current = root.appendingPathComponent("current")
            selected = root.appendingPathComponent("selected cache")
            home = root.appendingPathComponent("home")
            for directory in [current, selected, home.appendingPathComponent(".cache/huggingface/hub")] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            var value = ProviderConfig(provider: ProviderSettings(name: "location-fixture"))
            value.backend.modelCacheDirectory = current.path
            value.backend.idleTimeoutMins = 45
            try ConfigManager.save(value, to: config)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func command(_ arguments: [String] = []) throws -> Models.Location {
            try #require(try Darkbloom.parseAsRoot(
                ["models", "location", "--config", config.path] + arguments) as? Models.Location)
        }

        @discardableResult
        func execute(
            _ arguments: [String] = [], interactive: Bool = false,
            environment: [String: String] = [:], answers: [String?] = []
        ) throws -> ModelCacheLocationInspection? {
            var input = answers
            return try command(arguments).execute(
                isInteractive: interactive, environment: environment,
                homeDirectory: home, currentDirectory: root, migrateOnDisk: false,
                readInput: { input.isEmpty ? nil : input.removeFirst() }, writeLine: { _ in })
        }

        func contents() throws -> Data { try Data(contentsOf: config) }
        var hasLockFile: Bool { FileManager.default.fileExists(atPath: config.path + ".lock") }
    }

    private func makeModel(in cache: URL, id: String) throws {
        let snapshot = cache
            .appendingPathComponent("models--" + id.replacingOccurrences(of: "/", with: "--"))
            .appendingPathComponent("snapshots/local")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data(#"{"model_type":"llama"}"#.utf8).write(to: snapshot.appendingPathComponent("config.json"))
        try Data(repeating: 1, count: 64).write(to: snapshot.appendingPathComponent("model.safetensors"))
    }

    @Test func directPathPersistsAbsoluteLocationAndPreservesOtherSettings() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("leave weights alone".utf8).write(to: fixture.current.appendingPathComponent("sentinel"))

        let result = try fixture.execute(["selected cache"])
        let config = try ConfigManager.load(from: fixture.config)
        #expect(config.backend.modelCacheDirectory == fixture.selected.path)
        #expect(config.backend.idleTimeoutMins == 45)
        #expect(config.provider.name == "location-fixture")
        #expect(result?.directory.path == fixture.selected.path)
        #expect(result?.modelIDs == [])
        #expect(result?.problem == nil)
        #expect(try String(contentsOf: fixture.current.appendingPathComponent("sentinel"), encoding: .utf8)
            == "leave weights alone")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.selected.path) == [])
    }

    @Test func symlinkParentTraversalSelectsThePOSIXDestination() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let realParent = fixture.root.appendingPathComponent("disk")
        let child = realParent.appendingPathComponent("child")
        let correctCache = realParent.appendingPathComponent("cache")
        let lexicalCache = fixture.root.appendingPathComponent("cache")
        for directory in [child, correctCache, lexicalCache] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("link"), withDestinationURL: child)
        try makeModel(in: correctCache, id: "acme/Correct-4bit")
        try makeModel(in: lexicalCache, id: "acme/Wrong-4bit")

        let result = try fixture.execute(["link/../cache"])
        #expect(result?.directory.path == correctCache.path)
        #expect(result?.modelIDs == ["acme/Correct-4bit"])
        #expect(try ConfigManager.load(from: fixture.config).backend.modelCacheDirectory == correctCache.path)
    }

    @Test func checkDiscoversOnlyRequestedCacheWithoutPersistingOrMigrating() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try makeModel(in: fixture.current, id: "acme/Current-4bit")
        try makeModel(in: fixture.selected, id: "acme/Selected-4bit")
        let before = try fixture.contents()

        // Even the normal migration-enabled command path is read-only for check.
        let result = try fixture.command(["--check", fixture.selected.path]).execute(
            isInteractive: true, environment: [:], homeDirectory: fixture.home,
            readInput: { Issue.record("--check must not prompt"); return "yes" }, writeLine: { _ in })
        #expect(result?.directory.path == fixture.selected.path)
        #expect(result?.modelIDs == ["acme/Selected-4bit"])
        #expect(try fixture.contents() == before)
        #expect(!fixture.hasLockFile)
    }

    @Test func explicitCheckIgnoresMalformedConfiguration() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try makeModel(in: fixture.selected, id: "acme/Selected-4bit")
        try Data("[backend\nmodel_cache_directory =".utf8).write(to: fixture.config)
        let before = try fixture.contents()

        let result = try fixture.execute(["--check", fixture.selected.path])
        #expect(result?.directory.path == fixture.selected.path)
        #expect(result?.modelIDs == ["acme/Selected-4bit"])
        #expect(try fixture.contents() == before)
        #expect(!fixture.hasLockFile)
    }

    @Test func statusDoesNotCreateAMissingCache() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let missing = fixture.root.appendingPathComponent("unmounted/cache")
        var config = try ConfigManager.load(from: fixture.config)
        config.backend.modelCacheDirectory = missing.path
        try ConfigManager.save(config, to: fixture.config)
        let before = try fixture.contents()

        let result = try #require(try fixture.execute())
        #expect(result.directory.path == missing.path)
        #expect(result.problem != nil)
        #expect(result.modelIDs == [])
        #expect(try fixture.contents() == before)
        #expect(!fixture.hasLockFile)
        #expect(!FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path))
    }

    @Test func noninteractiveStatusAndPathlessCheckDoNotReadInputOrWrite() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try makeModel(in: fixture.current, id: "acme/Current-4bit")
        let before = try fixture.contents()
        for arguments in [[], ["--check"]] {
            let result = try fixture.command(arguments).execute(
                isInteractive: false, environment: [:], homeDirectory: fixture.home,
                readInput: { Issue.record("status must not consume piped input"); return "3" },
                writeLine: { _ in })
            #expect(result?.modelIDs == ["acme/Current-4bit"])
        }
        #expect(try fixture.contents() == before)
        #expect(!fixture.hasLockFile)
    }

    @Test func inspectionAndCancellationNeverCreateAMissingConfigDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let missing = fixture.root.appendingPathComponent("no-config/provider.toml")
        for arguments in [[], ["--check", fixture.selected.path]] {
            let command = try #require(try Darkbloom.parseAsRoot(
                ["models", "location", "--config", missing.path] + arguments) as? Models.Location)
            try command.execute(
                isInteractive: true, environment: [:], homeDirectory: fixture.home,
                readInput: { nil }, writeLine: { _ in })
            #expect(!FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path))
        }
    }

    @Test func resetRemovesSavedSettingAndRespectsEnvironmentThenDefault() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let result = try fixture.execute(["--reset"], environment: ["HF_HUB_CACHE": fixture.selected.path])
        #expect(result?.directory.path == fixture.selected.path)
        let config = try ConfigManager.load(from: fixture.config)
        #expect(config.backend.modelCacheDirectory == nil)
        #expect(config.backend.idleTimeoutMins == 45)
        #expect(try fixture.execute()?.directory.path == fixture.home.appendingPathComponent(".cache/huggingface/hub").path)
    }

    @Test func resetRepairsInvalidMissingAndReadOnlySavedLocations() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.current.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.current.path) }
        for saved in ["", "~missing-user-\(UUID().uuidString)/cache", fixture.root.appendingPathComponent("missing").path,
                      fixture.current.path] {
            var config = try ConfigManager.load(from: fixture.config)
            config.backend.modelCacheDirectory = saved
            try ConfigManager.save(config, to: fixture.config)
            let result = try fixture.execute(["--reset"])
            #expect(try ConfigManager.load(from: fixture.config).backend.modelCacheDirectory == nil)
            #expect(result?.directory.path == fixture.home.appendingPathComponent(".cache/huggingface/hub").path)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.current.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("missing").path))
    }

    @Test func validSelectionReplacesAnInvalidSavedPath() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var config = try ConfigManager.load(from: fixture.config)
        config.backend.modelCacheDirectory = ""
        try ConfigManager.save(config, to: fixture.config)
        try fixture.execute([fixture.selected.path])
        #expect(try ConfigManager.load(from: fixture.config).backend.modelCacheDirectory == fixture.selected.path)
    }

    @Test func menuCanCancelOrRepairAnInvalidSavedPath() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var config = try ConfigManager.load(from: fixture.config)
        config.backend.modelCacheDirectory = ""
        try ConfigManager.save(config, to: fixture.config)
        let before = try fixture.contents()
        try fixture.execute(interactive: true, answers: [""])
        #expect(try fixture.contents() == before)
        #expect(!fixture.hasLockFile)

        try fixture.execute(interactive: true, answers: ["3", fixture.selected.path, "yes"])
        #expect(try ConfigManager.load(from: fixture.config).backend.modelCacheDirectory == fixture.selected.path)
        config.backend.modelCacheDirectory = ""
        try ConfigManager.save(config, to: fixture.config)
        try fixture.execute(interactive: true, answers: ["2", "yes"])
        #expect(try ConfigManager.load(from: fixture.config).backend.modelCacheDirectory == nil)
    }

    @Test func cancelledResetDoesNotRewriteAnInvalidSavedPath() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var config = try ConfigManager.load(from: fixture.config)
        config.backend.modelCacheDirectory = ""
        try ConfigManager.save(config, to: fixture.config)
        let before = try fixture.contents()
        let cancellations: [[String?]] = [[], [""]]
        for answers in cancellations {
            try fixture.execute(["--reset"], interactive: true, answers: answers)
            #expect(try fixture.contents() == before)
            #expect(!fixture.hasLockFile)
        }
    }

    @Test func environmentShadowDoesNotReplaceTheSavedChoice() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let result = try fixture.execute([fixture.selected.path], environment: ["HF_HUB_CACHE": fixture.current.path])
        #expect(result?.directory.path == fixture.selected.path)
        #expect(try fixture.execute(environment: ["HF_HUB_CACHE": fixture.current.path])?.directory.path == fixture.current.path)
        #expect(try ConfigManager.load(from: fixture.config).backend.modelCacheDirectory == fixture.selected.path)
        #expect(try fixture.execute()?.directory.path == fixture.selected.path)
    }

    @Test func blankEOFAndNegativeConfirmationNeverSave() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let before = try fixture.contents()
        let dialogues: [[String?]] = [
            [], [""], ["  "], ["1"], ["3"], ["3", ""],
            ["3", fixture.selected.path], ["3", fixture.selected.path, ""],
            ["3", fixture.selected.path, "no"], ["2"], ["2", ""],
        ]
        for answers in dialogues {
            try fixture.execute(interactive: true, answers: answers)
            #expect(try fixture.contents() == before)
            #expect(!fixture.hasLockFile)
        }
        let confirmations: [String?] = [nil, "", "y", "no"]
        for arguments in [[fixture.selected.path], ["--reset"]] {
            for answer in confirmations {
                try fixture.execute(arguments, interactive: true, answers: [answer])
                #expect(try fixture.contents() == before)
                #expect(!fixture.hasLockFile)
            }
        }
    }

    @Test func interactiveSelectionAndResetRequireExplicitYes() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.execute(interactive: true, answers: ["3", fixture.selected.path, "yes"])
        #expect(try ConfigManager.load(from: fixture.config).backend.modelCacheDirectory == fixture.selected.path)
        try fixture.execute(interactive: true, answers: ["2", "yes"])
        #expect(try ConfigManager.load(from: fixture.config).backend.modelCacheDirectory == nil)
        try fixture.execute([fixture.current.path], interactive: true, answers: ["yes"])
        #expect(try ConfigManager.load(from: fixture.config).backend.modelCacheDirectory == fixture.current.path)
    }

    @Test func missingPathFileAndEmptyPathFailWithoutWritingOrCreatingDirectories() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let missing = fixture.root.appendingPathComponent("unmounted-volume/cache")
        let file = fixture.root.appendingPathComponent("file")
        try Data("not a directory".utf8).write(to: file)
        let before = try fixture.contents()
        for path in [missing.path, file.path, "", "   "] {
            #expect(throws: ValidationError.self) { try fixture.execute([path]) }
            #expect(try fixture.contents() == before)
            #expect(!fixture.hasLockFile)
        }
        #expect(!FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path))
        #expect(throws: ValidationError.self) { try fixture.execute(["--check", missing.path]) }
        #expect(try fixture.contents() == before)
    }

    @Test func unreadableAndUnwritableDirectoriesCannotBeSaved() throws {
        guard geteuid() != 0 else { return } // Root bypasses the permission boundary being exercised.
        let fixture = try Fixture()
        defer { fixture.remove() }
        let before = try fixture.contents()
        for permissions in [0o333, 0o555, 0o666] {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: fixture.selected.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.selected.path) }
            #expect(throws: ValidationError.self) { try fixture.execute([fixture.selected.path]) }
            #expect(try fixture.contents() == before)
            #expect(!fixture.hasLockFile)
        }
    }

    @Test func relativeSavedLocationUsesConfigDirectoryNotShellDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var config = try ConfigManager.load(from: fixture.config)
        config.backend.modelCacheDirectory = "selected cache"
        try ConfigManager.save(config, to: fixture.config)
        let result = try fixture.command().execute(
            isInteractive: false, environment: [:], homeDirectory: fixture.home,
            currentDirectory: fixture.home, writeLine: { _ in })
        #expect(result?.directory.path == fixture.selected.path)
    }

    @Test func contradictoryFlagsAreRejectedBeforeMutation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let before = try fixture.contents()
        for arguments in [["--reset", "--check"], ["--reset", fixture.selected.path]] {
            #expect(throws: (any Error).self) { try fixture.command(arguments) }
        }
        #expect(try fixture.contents() == before)
        #expect(!fixture.hasLockFile)
    }
}
