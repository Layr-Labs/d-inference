import ArgumentParser
import Foundation
import ProviderCore
#if canImport(Darwin)
import Darwin
#endif

extension Models {
    struct Location: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Inspect or choose the model-cache directory.",
            discussion: """
            With no arguments, show the effective location and offer a simple menu
            in an interactive terminal; piped input only shows status. A PATH sets
            an existing readable, writable cache directory, including an empty one
            for future downloads. Interactive changes require typing 'yes'.

            --check [PATH] only inspects; --reset clears the saved setting.
            Environment overrides still win: HF_HUB_CACHE, HUGGINGFACE_HUB_CACHE,
            HF_HOME/hub, XDG_CACHE_HOME/huggingface/hub, then the saved setting,
            then ~/.cache/huggingface/hub. No weights are moved, deleted or downloaded.
            Discovery does not verify weight integrity or network eligibility.
            Changes require darkbloom stop && darkbloom start to refresh config and environment.
            """
        )

        @OptionGroup var configOptions: ConfigOptions

        @Argument(help: "Existing cache directory to select (or inspect with --check).")
        var path: String?

        @Flag(help: "Inspect PATH, or the effective directory, without saving anything.")
        var check = false

        @Flag(help: "Clear the saved location and return to environment/default resolution.")
        var reset = false

        func validate() throws {
            guard !(reset && (check || path != nil)) else {
                throw ValidationError("--reset cannot be combined with --check or PATH.")
            }
        }

        mutating func run() async throws {
            Darkbloom.ensureLogging()
            try execute()
        }

        /// Inject only terminal/environment inputs; tests still exercise real
        /// directory discovery and locked config persistence in isolated fixtures.
        @discardableResult
        func execute(
            isInteractive: Bool = isatty(STDIN_FILENO) != 0,
            environment: [String: String] = ProcessInfo.processInfo.environment,
            homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
            currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            migrateOnDisk: Bool = true,
            readInput: () -> String? = { readLine() },
            writeLine: (String) -> Void = { print($0) }
        ) throws -> ModelCacheLocationInspection? {
            try validate()
            // Explicit inspection is independent of even malformed configuration.
            if check, let path {
                let directory = try Self.normalize(path, home: homeDirectory, cwd: currentDirectory)
                let inspected = inspectModelCacheLocation(directory)
                writeLine("Checking: \(directory.path) (explicit PATH; not saved)")
                Self.printInspection(inspected, writeLine: writeLine)
                if let problem = inspected.problem { throw ValidationError(problem) }
                return inspected
            }
            let configPath = try configOptions.config.map {
                URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
            } ?? ConfigManager.defaultConfigPath()
            // Do not use a runtime snapshot: inspection/cancellation must not
            // migrate config, scan other caches, or initialize serving state.
            let config = try FileManager.default.fileExists(atPath: configPath.path)
                ? ConfigManager.load(from: configPath)
                : ProviderConfig(provider: ProviderSettings(name: "darkbloom"))
            writeLine("Config: \(configPath.path)")
            writeLine("Saved location: \(config.backend.modelCacheDirectory ?? "not set")")
            var current: ModelScanner.ResolvedCache?
            if !reset && path == nil {
                do {
                    let saved = try ConfigManager.modelCacheDirectory(in: config, relativeTo: configPath)
                    current = ModelScanner.resolveCache(
                        environment: environment, homeDirectory: homeDirectory, configuredDirectory: saved)
                } catch {
                    guard isInteractive && !check else { throw error }
                    writeLine("Current effective location unavailable: \(error). Choose a valid directory or clear the saved setting.")
                }
            }
            let currentInspection = current.map { inspectModelCacheLocation($0.url) }
            if let current, let currentInspection {
                writeLine("Effective location: \(current.url.path) (\(Self.source(current)))")
                Self.printInspection(currentInspection, writeLine: writeLine)
                if config.backend.modelCacheDirectory != nil, let key = current.environmentKey {
                    writeLine("The saved location is shadowed by $\(key). Unset higher-priority cache variables to use it.")
                }
            }

            if check {
                guard let inspected = currentInspection else {
                    throw ValidationError("No effective location is available to inspect.")
                }
                if let problem = inspected.problem { throw ValidationError(problem) }
                return inspected
            }

            let choice: LocationChoice
            if reset {
                choice = .reset
            } else if let path {
                choice = .set(path)
            } else if isInteractive {
                choice = Self.choose(readInput: readInput, writeLine: writeLine)
            } else {
                return currentInspection
            }

            let selected: URL?
            let selectedInspection: ModelCacheLocationInspection?
            switch choice {
            case .keep:
                writeLine("No changes saved.")
                return currentInspection
            case .reset:
                selected = nil
                selectedInspection = nil
            case .set(let raw):
                let directory = try Self.normalize(raw, home: homeDirectory, cwd: currentDirectory)
                let inspected = currentInspection.flatMap { $0.directory == directory ? $0 : nil }
                    ?? inspectModelCacheLocation(directory)
                writeLine("Selected location: \(directory.path)")
                if directory != current?.url { Self.printInspection(inspected, writeLine: writeLine) }
                if let problem = inspected.problem { throw ValidationError(problem) }
                selected = directory
                selectedInspection = inspected
            }

            var proposed: ModelScanner.ResolvedCache?
            if let selected {
                let resolution = ModelScanner.resolveCache(
                    environment: environment, homeDirectory: homeDirectory, configuredDirectory: selected.path)
                proposed = resolution
                writeLine("Effective location after saving: \(resolution.url.path) (\(Self.source(resolution)))")
                if let key = resolution.environmentKey {
                    writeLine("$\(key) overrides this selection. Unset higher-priority cache variables to use the saved location.")
                }
            } else {
                writeLine("Clear the saved setting and resolve the environment/default location; existing weights stay untouched.")
            }
            if isInteractive {
                writeLine(selected == nil
                    ? "Clear the saved location? Type 'yes' to confirm, or press Enter to cancel:"
                    : "Save this location? Type 'yes' to confirm, or press Enter to cancel:")
                guard readInput()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "yes" else {
                    writeLine("No changes saved.")
                    return currentInspection
                }
            }

            let result = try setModelCacheLocation(
                selected, configPath: configOptions.config, migrateOnDisk: migrateOnDisk)
            writeLine(result.changed ? "Saved configuration: \(result.path.path)" : "Configuration unchanged.")
            let effective = proposed ?? ModelScanner.resolveCache(
                environment: environment, homeDirectory: homeDirectory, configuredDirectory: nil)
            // SET inspects only the selected root, even if an environment variable
            // shadows it. Do not scan an unrelated (possibly unavailable) old cache.
            let inspection: ModelCacheLocationInspection
            if let selectedInspection {
                inspection = selectedInspection
            } else if let currentInspection, effective.url == currentInspection.directory {
                inspection = currentInspection
            } else {
                inspection = inspectModelCacheLocation(effective.url)
                Self.printInspection(inspection, writeLine: writeLine)
            }
            writeLine("Effective location: \(effective.url.path) (\(Self.source(effective)))")
            writeLine("No weights were moved, deleted or downloaded. The running provider was not changed.")
            writeLine("Apply config and environment changes with: darkbloom stop && darkbloom start")
            return inspection
        }

        private enum LocationChoice {
            case keep
            case reset
            case set(String)
        }

        private static func choose(
            readInput: () -> String?, writeLine: (String) -> Void
        ) -> LocationChoice {
            writeLine("  1. Keep the current location")
            writeLine("  2. Use environment/default location (clear saved setting)")
            writeLine("  3. Choose a custom directory")
            while true {
                writeLine("Choose 1, 2 or 3, or press Enter to cancel:")
                guard let answer = readInput() else { return .keep }
                switch answer.trimmingCharacters(in: .whitespacesAndNewlines) {
                case "", "1": return .keep
                case "2": return .reset
                case "3":
                    writeLine("Existing cache directory (blank cancels):")
                    guard let raw = readInput(), !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return .keep
                    }
                    return .set(raw)
                default: writeLine("Please enter 1, 2 or 3. No changes have been made.")
                }
            }
        }

        private static func normalize(_ raw: String, home: URL, cwd: URL) throws -> URL {
            guard let directory = ModelScanner.normalizedCacheDirectory(raw, homeDirectory: home, relativeTo: cwd) else {
                throw ValidationError("Enter a non-empty filesystem path with a valid home-directory expansion.")
            }
            return directory
        }

        private static func source(_ cache: ModelScanner.ResolvedCache) -> String {
            if let key = cache.environmentKey { return "$\(key)" }
            return cache.isConfigured ? "[backend] model_cache_directory" : "default"
        }

        private static func printInspection(
            _ inspection: ModelCacheLocationInspection, writeLine: (String) -> Void
        ) {
            if let problem = inspection.problem { writeLine(problem) }
            if inspection.modelIDs.isEmpty {
                writeLine("No cached MLX models discovered. An empty writable directory is valid for future downloads.")
            } else {
                writeLine("Discovered cache model IDs:")
                for id in inspection.modelIDs { writeLine("  \(id)") }
            }
            writeLine("Discovery only: this does not verify weight integrity or network eligibility.")
        }
    }
}
