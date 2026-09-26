import Foundation
import ProviderAppAttest

/// `provider-run.json` beside the daemon state file (0600). Written `running`
/// when a serve process starts and `clean` when it finishes its drain or
/// hands off to a relaunch, so the next process can tell a clean stop from a
/// crash, SIGKILL, jetsam, power loss or a reboot without a drain.
public struct ProviderRunMarker: Sendable {
    public static let fileName = "provider-run.json"

    public enum State: String, Codable, Sendable { case running, clean }

    /// What the previous process recorded about how it ended.
    public enum ExitCause: String, Codable, Sendable {
        case lifecycleCommand = "lifecycle_command"
        case update
        case stallRestart = "stall_restart"
        case shutdown
    }

    public struct Record: Codable, Sendable, Equatable {
        public var state: State
        /// Kernel start time in microseconds: the run identity. Whole seconds
        /// would merge two launches that start within the same second.
        public var processStartMicros: UInt64?
        public var version: String?
        public var exitCause: ExitCause?
        public var exitedAt: Double?
        /// What this run itself reported as `previous_exit`, so an in-place
        /// exec (same kernel process, new image) keeps the real answer.
        public var previousExit: AppAttestPreviousExit?

        public init(state: State, processStartMicros: UInt64?, version: String?, exitCause: ExitCause? = nil,
                    exitedAt: Double? = nil, previousExit: AppAttestPreviousExit? = nil) {
            self.state = state
            self.processStartMicros = processStartMicros
            self.version = version
            self.exitCause = exitCause
            self.exitedAt = exitedAt
            self.previousExit = previousExit
        }

        enum CodingKeys: String, CodingKey {
            case state, version
            case processStartMicros = "process_start_micros"
            case exitCause = "exit_cause"
            case exitedAt = "exited_at"
            case previousExit = "previous_exit"
        }
    }

    public let url: URL

    public init(directory: URL) {
        url = directory.appendingPathComponent(Self.fileName)
    }

    public func read() -> Record? {
        OwnerOnlyFile.read(url).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
    }

    public func markRunning(processStartMicros: UInt64?, version: String, previousExit: AppAttestPreviousExit?) throws {
        try write(Record(state: .running, processStartMicros: processStartMicros, version: version, previousExit: previousExit))
    }

    /// Only the process that wrote `running` may mark it clean; a stale
    /// process (e.g. an old binary still draining) cannot overwrite a newer run.
    public func markClean(processStartMicros: UInt64?, cause: ExitCause, now: Date = Date()) throws {
        guard var record = read(), record.processStartMicros == processStartMicros else { return }
        record.state = .clean
        record.exitCause = cause
        record.exitedAt = now.timeIntervalSince1970
        try write(record)
    }

    private func write(_ record: Record) throws {
        try OwnerOnlyFile.write(JSONEncoder().encode(record), to: url)
    }

    /// Pure: how the previous process ended, from the marker read before this
    /// process overwrote it. The same kernel process re-running (in-place
    /// exec after a startup update) inherits what it reported before.
    public static func previousExit(_ previous: Record?, processStartMicros: UInt64?) -> AppAttestPreviousExit {
        if let previous, let processStartMicros, previous.processStartMicros == processStartMicros {
            return previous.previousExit ?? .unknown
        }
        switch previous?.state {
        case .clean: return .clean
        case .running: return .unclean
        case nil: return .unknown
        }
    }
}
