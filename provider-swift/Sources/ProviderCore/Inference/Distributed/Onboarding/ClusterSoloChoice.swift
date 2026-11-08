import Foundation

/// Whether single-Mac serving on a paired Mac was the person's own choice, made after the pair was last started here.
///
/// Tonight's 0.10.8 → 0.10.9 update runs 0.10.8's updater, which can restart single-Mac serving on a paired Mac (its job
/// was left set up by a `darkbloom start` from before 0.10.8). Single-Mac serving then holds the Mac's one serving lock,
/// and the pair can never start again. So on a Mac whose pair is started and wants its part, the cluster service stops
/// single-Mac serving by itself, as `darkbloom stop --solo` does (`stepsAside`), unless the person chose it: `start
/// --solo` records the choice here (`record`), and an explicit start of the pair or `stop --solo` on this Mac clears it
/// (`clear`). A Mac updated from 0.10.8 has no record, so the started pair wins.
public enum ClusterSoloChoice {
    /// The choice's file in this Mac's cluster setup directory.
    static func file(in directory: URL) -> URL { directory.appendingPathComponent("solo-choice.json") }
    /// What the last step aside did, for `darkbloom status` (`steppedAside`).
    static func noteFile(in directory: URL) -> URL { directory.appendingPathComponent("solo-stepped-aside.json") }

    struct Choice: Codable { var chosenAt: Double }
    public struct SteppedAside: Codable, Equatable, Sendable {
        public var at: Double
        public var pid: Int32?
        public init(at: Double, pid: Int32?) { self.at = at; self.pid = pid }
    }

    /// The person chose single-Mac serving on this Mac now (seconds since 1970).
    public static func record(in directory: URL, now: Double = Date().timeIntervalSince1970) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(Choice(chosenAt: now)) else { return }
        try? data.write(to: file(in: directory), options: .atomic)
        try? FileManager.default.removeItem(at: noteFile(in: directory))
    }

    /// The pair was started on this Mac, or single-Mac serving was stopped here: no choice stands any more.
    public static func clear(in directory: URL) {
        try? FileManager.default.removeItem(at: file(in: directory))
    }

    /// When the person chose single-Mac serving here; nil when no choice stands.
    public static func chosenAt(in directory: URL) -> Double? {
        guard let data = try? Data(contentsOf: file(in: directory)) else { return nil }
        return (try? JSONDecoder().decode(Choice.self, from: data))?.chosenAt
    }

    /// Single-Mac serving steps aside for the pair: the pair is started and wants this Mac's part ("cluster:" key, never
    /// the degraded server of a pair that doesn't run, nor no part at all, so it never fights "the pair isn't running:
    /// serve alone"), and the person didn't choose single-Mac serving since the pair was last started here.
    public static func stepsAside(wantedKey: String?, chosenAt: Double?) -> Bool {
        guard let wantedKey, wantedKey.hasPrefix("cluster:") else { return false }
        return chosenAt == nil
    }

    public static func noteSteppedAside(_ note: SteppedAside, in directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(note) else { return }
        try? data.write(to: noteFile(in: directory), options: .atomic)
    }

    public static func steppedAside(in directory: URL) -> SteppedAside? {
        guard let data = try? Data(contentsOf: noteFile(in: directory)) else { return nil }
        return try? JSONDecoder().decode(SteppedAside.self, from: data)
    }

    /// The line `darkbloom status` and the service log say after a step aside.
    public static func line(_ note: SteppedAside, cli: String) -> String {
        let time = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: note.at))
        return "Single-Mac serving stepped aside for the pair at \(time)" + (note.pid.map { " (process \($0))" } ?? "")
            + ": the pair is started here and nobody chose single-Mac serving since. `\(cli) start --solo` serves this Mac alone again."
    }
}
