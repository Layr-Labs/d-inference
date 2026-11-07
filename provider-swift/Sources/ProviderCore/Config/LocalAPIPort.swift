import Foundation

/// This Mac's local API port: one per Mac, chosen once, saved in `[local] port`, then used by every local API this Mac
/// serves (Only me, Both, the desktop app's local mode) and by every tool pointed at it.
///
/// A port already saved, or one the person names (`--port`), always wins, so tools that point at it keep working; a
/// named port is saved. Otherwise the first free port from `firstTried` is chosen and saved, never one of `neverChosen`.
public enum LocalAPIPort {
    /// Never chosen: 8000, where other local AI apps listen (oMLX on the owner's Mac), and 47420–47423, which two-Mac
    /// pairs use (`LocalSettings.neverChosenPorts`).
    public static let neverChosen = LocalSettings.neverChosenPorts
    /// How far past the first port a choice looks.
    public static let span: UInt16 = 20

    /// Where a choice starts: the build's default local port. Production's is 8000, never chosen, so its first is 8001.
    public static var firstTried: UInt16 { BuildEnvironment.current.defaultLocalPort }

    /// This Mac's port for one start, and whether `[local] port` gets it.
    public struct Choice: Equatable, Sendable {
        public let port: UInt16
        /// A new choice, or a named port other than the saved one: saved, so that every later start and every tool
        /// keep it.
        public let saves: Bool
        /// The line that says which port and why; nil when the saved port serves.
        public let note: String?

        public init(port: UInt16, saves: Bool, note: String?) {
            self.port = port
            self.saves = saves
            self.note = note
        }
    }

    /// The named port; else the saved one; else the first free one from `firstTried`. `ownLivePort` (this install's
    /// running local API, which the new start replaces) and `isFree` are asked only for a new choice.
    public static func choose(named: UInt16?, saved: UInt16?, ownLivePort: () -> UInt16?,
                              isFree: (UInt16) -> Bool) throws -> Choice {
        // Today's `--local` and `--local-endpoint`: the named port, else the saved one, else the build's default.
        Choice(port: named ?? saved ?? firstTried, saves: false, note: nil)
    }

    /// This Mac's port for a local API that starts now (the desktop app's local mode; a pair's local API): the saved
    /// `[local] port`, else a new choice, saved at once in the config at `configPath` (`fallbackConfig` when that file
    /// doesn't exist yet). A port another start saved meanwhile stands. Throws `LocalAPIPortError` when no port is
    /// free, and the config's own errors.
    @discardableResult
    public static func thisMac(configPath: URL, fallbackConfig: ProviderConfig,
                               ownLivePort: () -> UInt16? = { LocalEndpoint.readLiveInfo()?.port },
                               isFree: (UInt16) -> Bool = { ClusterLocalServing.portIsFree(Int($0)) }) throws -> Choice {
        let config = try FileManager.default.fileExists(atPath: configPath.path)
            ? ConfigManager.load(from: configPath) : fallbackConfig
        return try choose(named: nil, saved: config.local?.port, ownLivePort: ownLivePort, isFree: isFree)
    }

    /// The first of `start`…`start + span` that isn't one of `neverChosen` and that no other program listens on, or
    /// that this install's own running local API holds (the new start replaces it). `isFree` is never asked about
    /// `neverChosen`, so a choice never even test-binds them.
    public static func pick(from start: UInt16, ownLivePort: UInt16?, isFree: (UInt16) -> Bool) -> UInt16? {
        (start...last(from: start)).first { !neverChosen.contains($0) && ($0 == ownLivePort || isFree($0)) }
    }

    static func last(from start: UInt16) -> UInt16 { start > UInt16.max - span ? UInt16.max : start + span }

    /// Says which port was chosen, and why not the first one.
    public static func note(chosen: UInt16, start: UInt16) -> String {
        guard chosen != start else { return "Local API port: \(chosen) (saved)." }
        let why = neverChosen.contains(start) ? "is left for other apps" : "is in use"
        return "Local API port: \(chosen) (saved; \(start) \(why))."
    }

    /// Says that a named port replaces the saved one, and that tools set up for the old one need setting up again.
    public static func note(named: UInt16, saved: UInt16?) -> String {
        guard let saved else { return "Local API port: \(named) (saved)." }
        let cli = BuildEnvironment.current.cliName
        return "Local API port: \(named) (saved, instead of \(saved): tools set up for \(saved) need "
            + "`\(cli) start --opencode` or `--hermes` again)."
    }

    public static func noneFree(from start: UInt16) -> String {
        "No free port for this Mac's API from \(start) to \(last(from: start)) (8000 and "
            + "\(ClusterLocalServing.pairPortsWords) are never chosen). Free one, or name one with --port <n>."
    }

    /// For a local API that couldn't listen on `port`, which another program holds: the port a new choice would take
    /// now, for the line that names `start --port`; nil when none is free.
    public static func nextFree(besides port: UInt16,
                                isFree: (UInt16) -> Bool = { ClusterLocalServing.portIsFree(Int($0)) }) -> UInt16? {
        nil
    }
}

/// No port was free for a new choice (`LocalAPIPort.noneFree`).
public struct LocalAPIPortError: Error, Equatable, CustomStringConvertible {
    public let start: UInt16
    public var description: String { LocalAPIPort.noneFree(from: start) }
}
