import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Reports whether a process with the given PID is currently alive.
public func daemonProcessAlive(pid: Int32) -> Bool {
    pid > 0 && kill(pid, 0) == 0
}

/// Reads/writes the daemon state file at `~/.darkbloom/daemon-state.json`
/// (override with `DARKBLOOM_STATE_FILE`).
///
/// Shared location note: the daemon writes, `darkbloom status`/`doctor`
/// reads, and the Darkbloom macOS app polls this file as its provider-truth
/// stream. Keep it dependency-free (Foundation only) so the app links the
/// contract without the inference runtime.
public enum DaemonStateFile {
    public static func path() -> URL {
        if let override = ProcessInfo.processInfo.environment["DARKBLOOM_STATE_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".darkbloom/daemon-state.json")
    }

    /// Built once. `write` runs on a ~2 s tick for the life of the daemon, and
    /// a fresh `JSONEncoder` per call is pure allocation for a configuration
    /// that never changes. `.sortedKeys` is deliberately NOT set: nothing
    /// diffs this file, no signature covers it, and stable key order costs a
    /// sort of every key on every tick.
    private static let sharedEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    private static let sharedDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    /// Atomically writes the snapshot. Best-effort: write failures are swallowed
    /// (diagnostics must never crash the serving daemon).
    ///
    /// `createDirectory(withIntermediateDirectories: true)` stays on the write
    /// path deliberately. Memoizing it would save one mkdir that returns
    /// EEXIST — nothing, next to the atomic write beside it — in exchange for
    /// a lock, a mutable global, and a daemon that stops persisting state for
    /// the rest of its life if anything ever removes the directory underneath
    /// it. Keep the syscall.
    ///
    /// Moving the write off the caller's actor is the change with real value
    /// here and is deliberately NOT attempted: it is a concurrency change to
    /// the path `status`, `doctor` and the watchdog all read.
    public static func write(_ state: DaemonState, to url: URL = DaemonStateFile.path()) {
        do {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try sharedEncoder.encode(state)
            // .atomic writes to a temp file then renames — a reader never sees a
            // half-written file.
            try data.write(to: url, options: .atomic)
        } catch {
            // Intentionally ignored: state file is a diagnostic aid, not critical.
        }
    }

    /// Reads the snapshot, or nil if absent / unreadable / wrong schema.
    public static func read(from url: URL = DaemonStateFile.path()) -> DaemonState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let state = try? sharedDecoder.decode(DaemonState.self, from: data) else { return nil }
        guard state.schema == DaemonState.currentSchema else { return nil }
        return state
    }
}
