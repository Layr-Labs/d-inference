import Darwin
import Foundation

// Per-request pair telemetry (PROD-PLAN S24).
//
// One record per request the pair served: the generation mode and the layer
// cut it ran at, its first token and decode rate as the leader observed them,
// the hand-off and MTP acceptance the ranks reported, and the prompt tokens
// both ranks restored from their prefix caches. Values only: no prompt, no
// output token, no client identity. The leader keeps the last records in
// memory and in `~/.darkbloom/cluster/pair-telemetry.json` (owner-only), which
// `darkbloom cluster status` and the console read.

/// What the leader observed of one served request.
public struct ClusterPairRequestTelemetry: Codable, Sendable, Equatable {
    /// The engine's own generation identifier: never the client's request ID.
    public let requestID: String
    /// When the request retired, seconds since 1970 (UTC).
    public let finishedAt: Double
    public let modelID: String
    /// The generation mode the pair ran (`pipeline_v1`, `phase_split_v1`, `phase_split_mtp_v1`).
    public let mode: String
    /// The layers each rank holds, rank 0 first (`0-16|16-32`).
    public let cut: String
    public let promptTokens: Int
    /// Prompt tokens both ranks restored from their prefix caches.
    public let cachedTokens: Int
    public let completionTokens: Int
    /// From the leader's admission of the request to its first committed token.
    public let firstTokenMilliseconds: Double?
    /// Committed tokens after the first, per second of the time between the first and the last.
    public let decodeTokensPerSecond: Double?
    /// The slower rank's wall time for the phase-split hand-off; nil when there was none.
    public let handoffMilliseconds: Double?
    public let handoffBytes: Int?
    /// Draft tokens the decoding rank examined and accepted with its MTP head.
    public let mtpDrafted: Int?
    public let mtpAccepted: Int?
    /// `mtpAccepted / mtpDrafted`, when any token was drafted.
    public let mtpAcceptance: Double?
    /// `stop`, `length`, `cancelled`, `engine_error`, or a terminal cause.
    public let outcome: String
    /// Which way the request went (`ClusterRequestRouter`): `pair`, or
    /// `alone:<member>` when the member that holds the whole model served it
    /// by itself. Nil in a record written before routes.
    public let route: String?
    /// Why, in plain words, with the two predicted times.
    public let routeReason: String?
    /// The members in rank order (their setup labels), so that a speed
    /// record names which Mac held which range. Nil in an older record.
    public let ranks: [String]?

    public init(requestID: String, finishedAt: Double, modelID: String, mode: String, cut: String,
                promptTokens: Int, cachedTokens: Int, completionTokens: Int, firstTokenMilliseconds: Double?,
                decodeTokensPerSecond: Double?, handoffMilliseconds: Double?, handoffBytes: Int?,
                mtpDrafted: Int?, mtpAccepted: Int?, outcome: String, route: String? = nil, routeReason: String? = nil,
                ranks: [String]? = nil) {
        self.requestID = requestID; self.finishedAt = finishedAt; self.modelID = modelID; self.mode = mode
        self.cut = cut; self.promptTokens = promptTokens; self.cachedTokens = cachedTokens
        self.completionTokens = completionTokens; self.firstTokenMilliseconds = firstTokenMilliseconds
        self.decodeTokensPerSecond = decodeTokensPerSecond; self.handoffMilliseconds = handoffMilliseconds
        self.handoffBytes = handoffBytes; self.mtpDrafted = mtpDrafted; self.mtpAccepted = mtpAccepted
        if let mtpDrafted, let mtpAccepted, mtpDrafted > 0 {
            mtpAcceptance = (Double(mtpAccepted) / Double(mtpDrafted) * 10_000).rounded() / 10_000
        } else { mtpAcceptance = nil }
        self.outcome = outcome
        self.route = route.map { String($0.prefix(80)) }
        self.routeReason = routeReason.map { String($0.prefix(240)) }
        self.ranks = ranks.flatMap { $0.count <= 8 && $0.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 }) ? $0 : nil }
    }

    /// A speed record: a completed request that computed its whole prompt
    /// (nothing restored from a prefix cache) and timed its first token.
    public var isSpeedRecord: Bool {
        cachedTokens == 0 && (outcome == "stop" || outcome == "length") && firstTokenMilliseconds != nil && promptTokens > 0
    }
}

/// Aggregates over the records a log holds.
public struct ClusterPairTelemetrySummary: Codable, Sendable, Equatable {
    public let requests: Int
    public let completed: Int
    public let medianFirstTokenMilliseconds: Double?
    public let medianDecodeTokensPerSecond: Double?
    public let medianHandoffMilliseconds: Double?
    /// Accepted over drafted, summed over every record that drafted.
    public let mtpAcceptance: Double?
    public let cachedTokens: Int
    public let requestsWithCacheHit: Int

    public init(_ records: [ClusterPairRequestTelemetry]) {
        func median(_ values: [Double]) -> Double? {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted(), middle = sorted.count / 2
            let value = sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
            return (value * 100).rounded() / 100
        }
        requests = records.count
        let done = records.filter { $0.outcome == "stop" || $0.outcome == "length" }
        completed = done.count
        medianFirstTokenMilliseconds = median(done.compactMap(\.firstTokenMilliseconds))
        medianDecodeTokensPerSecond = median(done.compactMap(\.decodeTokensPerSecond))
        medianHandoffMilliseconds = median(done.compactMap(\.handoffMilliseconds))
        let drafted = records.compactMap(\.mtpDrafted).reduce(0, +), accepted = records.compactMap(\.mtpAccepted).reduce(0, +)
        mtpAcceptance = drafted > 0 ? (Double(accepted) / Double(drafted) * 10_000).rounded() / 10_000 : nil
        cachedTokens = records.map(\.cachedTokens).reduce(0, +)
        requestsWithCacheHit = records.filter { $0.cachedTokens > 0 }.count
    }
}

/// The file `cluster status` reads.
public struct ClusterPairTelemetryFile: Codable, Sendable, Equatable {
    public static let schemaName = "darkbloom_pair_telemetry_v1"
    public let schema: String
    /// When the file was last written, seconds since 1970 (UTC).
    public let updatedAt: Double
    /// Identifies the writing session; a new session starts a new list.
    public let sessionID: String
    public let summary: ClusterPairTelemetrySummary
    /// Oldest first.
    public let records: [ClusterPairRequestTelemetry]
}

/// Speed records written from served requests (PERF-BACKLOG item 12 / GAPS
/// (c) 4): the leader keeps every request that computed its whole prompt, per
/// setup (model, mode, cut) and route, across serving sessions, in
/// `~/.darkbloom/cluster/served-speed.json` (owner-only), beside the pair
/// telemetry. The planner reads it on the next plan (`darkbloom-cluster-plan
/// plan --served`, `ClusterServedCalibration`) and the router prices each
/// route from it. Values only, as the telemetry.
public struct ClusterServedSpeedFile: Codable, Sendable, Equatable {
    public static let schemaName = "darkbloom_served_speed_v1"
    /// Kept per setup and route; the oldest goes first.
    public static let keptPerRoute = 32
    public static let keptInAll = 512
    public let schema: String
    public let updatedAt: Double
    /// Oldest first.
    public let records: [ClusterPairRequestTelemetry]

    public static func defaultFile(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(".darkbloom/cluster/served-speed.json")
    }

    /// `records` with `value` added when it is a speed record, bounded.
    public static func adding(_ value: ClusterPairRequestTelemetry, to records: [ClusterPairRequestTelemetry]) -> [ClusterPairRequestTelemetry] {
        guard value.isSpeedRecord else { return records }
        var result = records + [value]
        func key(_ r: ClusterPairRequestTelemetry) -> String {
            [r.modelID, r.mode, r.cut, r.route ?? "pair", (r.ranks ?? []).joined(separator: ",")].joined(separator: "\u{1f}")
        }
        let same = result.indices.filter { key(result[$0]) == key(value) }
        if same.count > keptPerRoute {
            let drop = Set(same.prefix(same.count - keptPerRoute))
            result = result.indices.filter { !drop.contains($0) }.map { result[$0] }
        }
        if result.count > keptInAll { result.removeFirst(result.count - keptInAll) }
        return result
    }

    public static func read(_ file: URL) -> ClusterServedSpeedFile? {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= 1 << 20 else { return nil }
        var bytes = Data(count: Int(info.st_size))
        let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        guard count == Int(info.st_size),
              let value = try? JSONDecoder().decode(ClusterServedSpeedFile.self, from: bytes),
              value.schema == schemaName else { return nil }
        return value
    }
}

/// The last `capacity` records of one serving session, in memory and on disk.
/// Thread-safe. A write failure never reaches the request path: it is counted.
public final class ClusterPairTelemetryLog: @unchecked Sendable {
    public static let defaultCapacity = 64

    public static func defaultFile(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(".darkbloom/cluster/pair-telemetry.json")
    }

    public let file: URL?
    public let sessionID: String
    private let capacity: Int
    private let clock: @Sendable () -> Double
    private let lock = NSLock()
    private var records: [ClusterPairRequestTelemetry] = []
    private var failures = 0
    /// Routes this session already served a completed cold request on.
    private var warmedRoutes: Set<String> = []

    /// `file` nil keeps the records in memory only (tests).
    public init(file: URL?, sessionID: String = UUID().uuidString.lowercased(), capacity: Int = defaultCapacity,
                clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) {
        self.file = file; self.sessionID = sessionID; self.capacity = max(1, capacity); self.clock = clock
    }

    /// Appends one record and rewrites the file (atomically, under the log's
    /// lock so writes land in order). Called off the request path.
    public func record(_ value: ClusterPairRequestTelemetry) {
        lock.withLock {
            records.append(value)
            if records.count > capacity { records.removeFirst(records.count - capacity) }
            guard let file else { return }
            let snapshot = ClusterPairTelemetryFile(schema: ClusterPairTelemetryFile.schemaName, updatedAt: clock(),
                sessionID: sessionID, summary: .init(records), records: records)
            do {
                try ClusterIncidentLog.makePrivateDirectory(file.deletingLastPathComponent())
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                var bytes = try encoder.encode(snapshot); bytes.append(10)
                try ClusterIncidentLog.writeAtomically(bytes, to: file)
            } catch { failures += 1 }
            // The speed records outlive the session: read, add, write back.
            // The first request a session serves on a route pays that path's
            // one-time costs (kernel builds, first allocations at its shapes):
            // seconds on the pair, which would make the route look slower than
            // it serves. It stays in the telemetry, not in the speed records.
            guard value.isSpeedRecord else { return }
            guard warmedRoutes.insert(value.route ?? "pair").inserted == false else { return }
            let history = file.deletingLastPathComponent().appendingPathComponent("served-speed.json")
            let kept = ClusterServedSpeedFile.read(history)?.records ?? []
            let updated = ClusterServedSpeedFile(schema: ClusterServedSpeedFile.schemaName, updatedAt: clock(),
                records: ClusterServedSpeedFile.adding(value, to: kept))
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                var bytes = try encoder.encode(updated); bytes.append(10)
                try ClusterIncidentLog.writeAtomically(bytes, to: history)
            } catch { failures += 1 }
        }
    }

    public var recent: [ClusterPairRequestTelemetry] { lock.withLock { records } }
    public var summary: ClusterPairTelemetrySummary { lock.withLock { .init(records) } }
    public var writeFailures: Int { lock.withLock { failures } }

    /// Reads a telemetry file; nil when it is missing or not one.
    public static func read(_ file: URL) -> ClusterPairTelemetryFile? {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= 1 << 20 else { return nil }
        var bytes = Data(count: Int(info.st_size))
        let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        guard count == Int(info.st_size),
              let value = try? JSONDecoder().decode(ClusterPairTelemetryFile.self, from: bytes),
              value.schema == ClusterPairTelemetryFile.schemaName else { return nil }
        return value
    }
}
