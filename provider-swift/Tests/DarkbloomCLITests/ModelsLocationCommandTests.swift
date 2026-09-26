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

        var ambientEnvironment: [String: String] {
            ["HF_HUB_CACHE": selected.path, "HUGGINGFACE_HUB_CACHE": selected.path,
             "HF_HOME": selected.path, "XDG_CACHE_HOME": selected.path]
        }

        var ambientEnvironments: [[String: String]] {
            ambientEnvironment.map { [$0.key: $0.value] } + [ambientEnvironment]
        }
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

        let result = try fixture.execute(["--check", fixture.selected.path], environment: fixture.ambientEnvironment)
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

    @Test func ambientVariablesDoNotRedirectSavedCacheOrConsumePipedInput() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try makeModel(in: fixture.current, id: "acme/Current-4bit")
        try makeModel(in: fixture.selected, id: "acme/Environment-4bit")
        let before = try fixture.contents()
        for environment in fixture.ambientEnvironments {
            for arguments in [[], ["--check"]] {
                let result = try fixture.command(arguments).execute(
                    isInteractive: false, environment: environment, homeDirectory: fixture.home,
                    readInput: { Issue.record("inspection must not consume piped input"); return "4" },
                    writeLine: { _ in })
                #expect(result?.directory.path == fixture.current.path)
                #expect(result?.modelIDs == ["acme/Current-4bit"])
            }
        }
        #expect(try fixture.contents() == before)
        #expect(!fixture.hasLockFile)
    }

    @Test func ambientVariablesLeaveMissingConfigAndDefaultCacheUnchanged() throws {
        for hasConfig in [false, true] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            if hasConfig {
                var config = try ConfigManager.load(from: fixture.config)
                config.backend.modelCacheDirectory = nil
                try ConfigManager.save(config, to: fixture.config)
            } else {
                try FileManager.default.removeItem(at: fixture.config)
            }
            let before = try? fixture.contents()
            let legacy = fixture.home.appendingPathComponent(".cache/huggingface/hub")
            try makeModel(in: legacy, id: "acme/Legacy-4bit")
            try makeModel(in: fixture.selected, id: "acme/Environment-4bit")
            for environment in fixture.ambientEnvironments {
                for arguments in [[], ["--check"]] {
                    let result = try fixture.execute(arguments, environment: environment)
                    #expect(result?.directory.path == legacy.path)
                    #expect(result?.modelIDs == ["acme/Legacy-4bit"])
                }
            }
            #expect((try? fixture.contents()) == before)
            #expect(!fixture.hasLockFile)
        }
    }

    @Test func inspectionAndCancellationNeverCreateAMissingConfigDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let missing = fixture.root.appendingPathComponent("no-config/provider.toml")
        for arguments in [[], ["--check", fixture.selected.path], ["--from-env"]] {
            let command = try #require(try Darkbloom.parseAsRoot(
                ["models", "location", "--config", missing.path] + arguments) as? Models.Location)
            try command.execute(
                isInteractive: true, environment: fixture.ambientEnvironment, homeDirectory: fixture.home,
                readInput: { nil }, writeLine: { _ in })
            #expect(!FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path))
        }
    }

    @Test func resetRemovesSavedSettingAndIgnoresAmbientEnvironment() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let legacy = fixture.home.appendingPathComponent(".cache/huggingface/hub")
        try makeModel(in: legacy, id: "acme/Legacy-4bit")
        try makeModel(in: fixture.selected, id: "acme/Environment-4bit")
        let result = try fixture.execute(["--reset"], environment: fixture.ambientEnvironment)
        #expect(result?.directory.path == legacy.path)
        #expect(result?.modelIDs == ["acme/Legacy-4bit"])
        let config = try ConfigManager.load(from: fixture.config)
        #expect(config.backend.modelCacheDirectory == nil)
        #expect(config.backend.idleTimeoutMins == 45)
        #expect(try fixture.execute(environment: fixture.ambientEnvironment)?.directory.path == legacy.path)
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

    @Test func explicitSelectionAndImportReplaceAnInvalidSavedPath() throws {
        for arguments in [["selected cache"], ["--from-env"]] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            var config = try ConfigManager.load(from: fixture.config)
            config.backend.modelCacheDirectory = ""
            try ConfigManager.save(config, to: fixture.config)
            try makeModel(in: fixture.selected, id: "acme/Selected-4bit")
            let result = try fixture.execute(arguments, environment: fixture.ambientEnvironment)
            #expect(result?.modelIDs == ["acme/Selected-4bit"])
            #expect(try ConfigManager.load(from: fixture.config).backend.modelCacheDirectory == fixture.selected.path)
        }
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

    @Test func explicitPathSelectsAndPinsCacheDespiteAmbientEnvironment() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let environment = ["HF_HUB_CACHE": fixture.current.path]
        let result = try fixture.execute([fixture.selected.path], environment: environment)
        #expect(result?.directory.path == fixture.selected.path)
        #expect(try fixture.execute(environment: environment)?.directory.path == fixture.selected.path)
        #expect(try ConfigManager.load(from: fixture.config).backend.modelCacheDirectory == fixture.selected.path)
        #expect(try fixture.execute()?.directory.path == fixture.selected.path)
    }

    @Test func environmentImportPinsPriorityWinnerAndNeverReadsPipedInput() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let candidates = [
            ("HF_HUB_CACHE", fixture.selected, fixture.selected),
            ("HUGGINGFACE_HUB_CACHE", fixture.root.appendingPathComponent("old-hf"),
             fixture.root.appendingPathComponent("old-hf")),
            ("HF_HOME", fixture.root.appendingPathComponent("hf-home"),
             fixture.root.appendingPathComponent("hf-home/hub")),
            ("XDG_CACHE_HOME", fixture.root.appendingPathComponent("xdg"),
             fixture.root.appendingPathComponent("xdg/huggingface/hub")),
        ]
        var environment = Dictionary(uniqueKeysWithValues: candidates.map { ($0.0, $0.1.path) })
        for (index, candidate) in candidates.enumerated() {
            try makeModel(in: candidate.2, id: "acme/Import-\(index)-4bit")
        }
        for (index, candidate) in candidates.enumerated() {
            let result = try fixture.command(["--from-env"]).execute(
                isInteractive: false, environment: environment, homeDirectory: fixture.home,
                migrateOnDisk: false,
                readInput: { Issue.record("explicit piped import must not prompt"); return nil },
                writeLine: { _ in })
            #expect(result?.directory.path == candidate.2.path)
            #expect(result?.modelIDs == ["acme/Import-\(index)-4bit"])
            let saved = try ConfigManager.load(from: fixture.config)
            #expect(saved.backend.modelCacheDirectory == candidate.2.path)
            #expect(saved.backend.idleTimeoutMins == 45)
            let changedEnvironment = ["HF_HUB_CACHE": fixture.current.path]
            #expect(try fixture.execute(environment: changedEnvironment)?.directory.path == candidate.2.path)
            #expect(try fixture.execute()?.directory.path == candidate.2.path)
            environment.removeValue(forKey: candidate.0)
        }
    }

    @Test func environmentImportNormalizesHomeRelativePathBeforeSaving() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let expected = fixture.home.appendingPathComponent(".cache/huggingface/hub")
        try fixture.execute(["--from-env"], environment: ["HF_HUB_CACHE": "~/.cache/huggingface/hub"])
        #expect(try ConfigManager.load(from: fixture.config).backend.modelCacheDirectory == expected.path)
    }

    @Test func missingEnvironmentImportRefusesWithoutMutation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let before = try fixture.contents()
        for environment in [[:], ["HF_HUB_CACHE": "  ", "HF_HOME": "~missing-user-\(UUID().uuidString)"]] {
            #expect(throws: ValidationError.self) {
                try fixture.execute(["--from-env"], environment: environment)
            }
            try fixture.execute(interactive: true, environment: environment, answers: ["4", "yes"])
            #expect(try fixture.contents() == before)
            #expect(!fixture.hasLockFile)
        }
    }

    @Test func menuShowsCandidateWithoutDiscoveringItsModelsUntilSelected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try makeModel(in: fixture.current, id: "acme/Current-4bit")
        try makeModel(in: fixture.selected, id: "acme/Environment-4bit")
        let before = try fixture.contents()
        var lines: [String] = []
        let result = try fixture.command().execute(
            isInteractive: true, environment: fixture.ambientEnvironment, homeDirectory: fixture.home,
            readInput: { "1" }, writeLine: { lines.append($0) })
        #expect(result?.directory.path == fixture.current.path)
        #expect(result?.modelIDs == ["acme/Current-4bit"])
        #expect(lines.contains { $0.contains(fixture.selected.path) })
        #expect(!lines.contains { $0.contains("acme/Environment-4bit") })
        #expect(try fixture.contents() == before)
        #expect(!fixture.hasLockFile)
    }

    @Test func blankEOFAndNegativeConfirmationNeverSave() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let before = try fixture.contents()
        let dialogues: [[String?]] = [
            [], [""], ["  "], ["1"], ["3"], ["3", ""],
            ["3", fixture.selected.path], ["3", fixture.selected.path, ""],
            ["3", fixture.selected.path, "no"], ["2"], ["2", ""],
            ["4"], ["4", ""], ["4", "no"],
        ]
        for answers in dialogues {
            try fixture.execute(interactive: true, environment: fixture.ambientEnvironment, answers: answers)
            #expect(try fixture.contents() == before)
            #expect(!fixture.hasLockFile)
        }
        let confirmations: [String?] = [nil, "", "y", "no"]
        for arguments in [[fixture.selected.path], ["--reset"], ["--from-env"]] {
            for answer in confirmations {
                try fixture.execute(arguments, interactive: true, environment: fixture.ambientEnvironment, answers: [answer])
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
        try fixture.execute(interactive: true, environment: fixture.ambientEnvironment, answers: ["4", "yes"])
        #expect(try ConfigManager.load(from: fixture.config).backend.modelCacheDirectory == fixture.selected.path)
        try fixture.execute(["--reset"])
        try fixture.execute(["--from-env"], interactive: true, environment: fixture.ambientEnvironment, answers: ["yes"])
        #expect(try ConfigManager.load(from: fixture.config).backend.modelCacheDirectory == fixture.selected.path)
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
            #expect(throws: ValidationError.self) {
                try fixture.execute(["--from-env"], environment: ["HF_HUB_CACHE": path])
            }
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
            #expect(throws: ValidationError.self) {
                try fixture.execute(["--from-env"], environment: fixture.ambientEnvironment)
            }
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
        for arguments in [["--reset", "--check"], ["--reset", fixture.selected.path],
                          ["--from-env", fixture.selected.path], ["--from-env", "--reset"],
                          ["--from-env", "--check"], ["--from-env", "--check", fixture.selected.path]] {
            #expect(throws: (any Error).self) { try fixture.command(arguments) }
        }
        #expect(try fixture.contents() == before)
        #expect(!fixture.hasLockFile)
    }
}
