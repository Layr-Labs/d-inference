import Foundation

/// Persists the set of models currently loaded by the serving daemon so the
/// NEXT boot can preload them before registering with the coordinator.
///
/// This is the default input to the startup preload (`preload_models` empty):
/// "warm what you were serving before the restart". The daemon rewrites the
/// file on every model load and on every non-shutdown unload (idle timeout,
/// eviction, retirement), so the file always describes the live serving set.
/// Shutdown teardown deliberately does NOT clear it — a stop/update/restart
/// must remember what was being served, which is the entire point.
///
/// The file lives in the provider's data dir (`~/.darkbloom/`, the same place
/// as `daemon-state.json`) so it survives auto-updates, which replace the
/// install layout but never touch the data dir. Best-effort like the daemon
/// state file: read/write failures degrade to "no preload", never a crash.
public enum LoadedModelsStore {
    /// Schema version; bump on incompatible shape changes. A mismatched schema
    /// reads as empty (safe: worst case the next boot preloads nothing).
    public static let currentSchema = 1

    /// Persisted shape: schema + loaded model ids + write timestamp.
    public struct State: Codable, Sendable, Equatable {
        public var schema: Int
        public var models: [String]
        public var updatedAt: Double

        public init(schema: Int = LoadedModelsStore.currentSchema, models: [String], updatedAt: Double) {
            self.schema = schema
            self.models = models
            self.updatedAt = updatedAt
        }
    }

    /// `~/.darkbloom/loaded-models.json`, overridable with
    /// `DARKBLOOM_LOADED_MODELS_FILE` (mirrors `DARKBLOOM_STATE_FILE`).
    public static func path() -> URL {
        if let override = ProcessInfo.processInfo.environment["DARKBLOOM_LOADED_MODELS_FILE"],
            !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".darkbloom/loaded-models.json")
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    /// Atomically writes the loaded-model set. Best-effort: failures are
    /// swallowed (persistence is an optimization, never worth crashing the
    /// serving daemon over).
    public static func write(_ models: [String], to url: URL = LoadedModelsStore.path()) {
        let state = State(models: models, updatedAt: Date().timeIntervalSince1970)
        do {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try encoder().encode(state)
            try data.write(to: url, options: .atomic)
        } catch {
            // Intentionally ignored: worst case the next boot preloads nothing.
        }
    }

    /// Reads the persisted loaded-model set. Missing / unreadable / corrupt /
    /// wrong-schema files all read as empty.
    public static func read(from url: URL = LoadedModelsStore.path()) -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let state = try? decoder().decode(State.self, from: data) else { return [] }
        guard state.schema == currentSchema else { return [] }
        return state.models
    }
}
