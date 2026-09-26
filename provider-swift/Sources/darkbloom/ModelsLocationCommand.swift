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

            --check [PATH] only inspects; --reset restores ~/.cache/huggingface/hub.
            --from-env imports the first valid HF_HUB_CACHE, HUGGINGFACE_HUB_CACHE,
            HF_HOME/hub or XDG_CACHE_HOME/huggingface/hub value once. The saved path
            is pinned: later environment changes do not affect it. Environment
            variables never change the cache unless you explicitly import them.
            No weights are moved, deleted or downloaded. Discovery does not verify
            weight integrity or network eligibility. Apply changes with darkbloom
            restart (or darkbloom start if stopped); this command never restarts it.
            """
        )

        @OptionGroup var configOptions: ConfigOptions

        @Argument(help: "Existing cache directory to select (or inspect with --check).")
        var path: String?

        @Flag(help: "Inspect PATH, or the effective directory, without saving anything.")
        var check = false

        @Flag(help: "Clear the saved location and return to ~/.cache/huggingface/hub.")
        var reset = false

        @Flag(help: "Import the Hugging Face environment cache once and save its absolute path.")
        var fromEnv = false

        func validate() throws {
            guard !(reset && (check || path != nil || fromEnv)) else {
                throw ValidationError("--reset cannot be combined with --check, --from-env or PATH.")
            }
            guard !(fromEnv && (check || path != nil)) else {
                throw ValidationError("--from-env cannot be combined with --check or PATH.")
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
            if !reset && !fromEnv && path == nil {
                do {
                    let saved = try ConfigManager.modelCacheDirectory(in: config, relativeTo: configPath)
                    current = ModelScanner.resolveCache(
                        homeDirectory: homeDirectory, configuredDirectory: saved)
                } catch {
                    guard isInteractive && !check else { throw error }
                    writeLine("Current effective location unavailable: \(error). Choose a valid directory or clear the saved setting.")
                }
            }
            let currentInspection = current.map { inspectModelCacheLocation($0.url) }
            if let current, let currentInspection {
                writeLine("Effective location: \(current.url.path) (\(Self.source(current)))")
                Self.printInspection(currentInspection, writeLine: writeLine)
            }

            if check {
                guard let inspected = currentInspection else {
                    throw ValidationError("No effective location is available to inspect.")
                }
                if let problem = inspected.problem { throw ValidationError(problem) }
                return inspected
            }

            // Detect a candidate for explicit import or the interactive menu,
            // but do not scan it unless the operator chooses to import it.
            let environmentCandidate = fromEnv || (isInteractive && path == nil && !reset)
                ? ModelScanner.resolveEnvironmentCache(environment: environment, homeDirectory: homeDirectory)
                : nil
            let choice: LocationChoice
            if reset {
                choice = .reset
            } else if let path {
                choice = .set(path)
            } else if fromEnv {
                choice = .importEnvironment
            } else if isInteractive {
                choice = Self.choose(
                    environmentCandidate: environmentCandidate, readInput: readInput, writeLine: writeLine)
            } else {
                return currentInspection
            }

            let selected: URL?
            switch choice {
            case .keep:
                writeLine("No changes saved.")
                return currentInspection
            case .reset:
                selected = nil
            case .set(let raw):
                selected = try Self.normalize(raw, home: homeDirectory, cwd: currentDirectory)
            case .importEnvironment:
                guard let environmentCandidate else {
                    let message = "No valid Hugging Face cache environment variable is set. Set HF_HUB_CACHE, HUGGINGFACE_HUB_CACHE, HF_HOME or XDG_CACHE_HOME, or choose a custom directory."
                    if fromEnv { throw ValidationError(message) }
                    writeLine(message)
                    writeLine("No changes saved.")
                    return currentInspection
                }
                selected = environmentCandidate.url
                writeLine("Importing Hugging Face environment cache: \(environmentCandidate.url.path) (\(Self.source(environmentCandidate)))")
                writeLine("The imported path is pinned in configuration; later environment changes will not affect it.")
            }

            let effective = ModelScanner.resolveCache(
                homeDirectory: homeDirectory, configuredDirectory: selected?.path)
            let selectedInspection: ModelCacheLocationInspection?
            if let selected {
                let inspected = currentInspection.flatMap { $0.directory == selected ? $0 : nil }
                    ?? inspectModelCacheLocation(selected)
                writeLine("Selected location: \(selected.path)")
                if selected != current?.url { Self.printInspection(inspected, writeLine: writeLine) }
                if let problem = inspected.problem { throw ValidationError(problem) }
                selectedInspection = inspected
                writeLine("Effective location after saving: \(effective.url.path) (\(Self.source(effective)))")
            } else {
                selectedInspection = nil
                writeLine("Clear the saved setting and return to \(effective.url.path); existing weights stay untouched.")
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
            // Inspect only the selected root. Do not scan an unrelated
            // (possibly unavailable) old cache for direct changes.
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
            writeLine("Apply configuration changes with: darkbloom restart (or darkbloom start if stopped).")
            return inspection
        }

        private enum LocationChoice {
            case keep
            case reset
            case set(String)
            case importEnvironment
        }

        private static func choose(
            environmentCandidate: ModelScanner.ResolvedCache?,
            readInput: () -> String?, writeLine: (String) -> Void
        ) -> LocationChoice {
            writeLine("  1. Keep the current location")
            writeLine("  2. Use the default ~/.cache/huggingface/hub (clear saved setting)")
            writeLine("  3. Choose a custom directory")
            writeLine("  4. Import Hugging Face environment cache")
            if let environmentCandidate {
                writeLine("     Detected: \(environmentCandidate.url.path) (\(source(environmentCandidate)); not inspected)")
            } else {
                writeLine("     No valid Hugging Face cache environment variable detected.")
            }
            while true {
                writeLine("Choose 1, 2, 3 or 4, or press Enter to cancel:")
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
                case "4": return .importEnvironment
                default: writeLine("Please enter 1, 2, 3 or 4. No changes have been made.")
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
