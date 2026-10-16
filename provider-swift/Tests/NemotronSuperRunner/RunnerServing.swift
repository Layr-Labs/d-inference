import Foundation
@testable import ProviderCore

/// Explicit load geometry. Every value lands in the ready file and receipts.
struct RunnerLoadSettings: Sendable {
    let maxContextLength: Int
    let defaultMaxTokens: Int
    let kvCapacityBytes: Int
    let backendAllowanceBytes: Int
    let kvBytesPerTokenOverride: Int?
    /// nil keeps the provider's resolved default; validated never to exceed it.
    let capFraction: Double?
    /// The only runtime-policy environment the engine sees (A/B switches).
    let engineEnvironment: [String: String]
    let verifyParallelism: Int

    /// The opt-in speculation the engine environment selects; the load
    /// transaction reads the same entries. nil is the plain arm.
    func speculation() throws -> NemotronSuperLocalMTP.Setting? {
        try NemotronSuperLocalMTP.Setting.resolve(environment: engineEnvironment)
    }

    static func speculationJSON(_ setting: NemotronSuperLocalMTP.Setting?) -> RunnerJSON {
        guard let setting else { return .null }
        return ["depth": .count(setting.depth),
                "verification": .string(setting.verification == .serial ? "serial" : "rectangular")]
    }

    /// The override may only raise the per-token reservation rate.
    func kvBytesPerToken(configured: Int) throws -> Int {
        guard let override = kvBytesPerTokenOverride else { return configured }
        guard override >= configured else {
            throw RunnerFailure.checkpoint("--kv-bytes-per-token \(override) is below the configured rate \(configured)")
        }
        return override
    }

    var json: RunnerJSON {
        [
            "max_context_length": .count(maxContextLength), "default_max_tokens": .count(defaultMaxTokens),
            "kv_capacity_bytes": .bytes(kvCapacityBytes),
            "backend_allowance_bytes": .bytes(backendAllowanceBytes),
            "kv_bytes_per_token_override": kvBytesPerTokenOverride.map { .bytes($0) } ?? .null,
            "cap_fraction": capFraction.map { .double($0) } ?? .null,
            "engine_environment": .object(engineEnvironment.mapValues { .string($0) }),
            "shard_verify_parallelism": .count(verifyParallelism),
        ]
    }
}

/// One loaded, unpublished Super owner and the only way to retire it.
struct RunnerServing: Sendable {
    let bridge: EngineV2Bridge
    let tokenizer: TokenizerHandle
    let imageHook: NemotronSuperLocalImageHTTP
    let identity: RunnerJSON
    /// Call only after HTTP admission closed and in-flight work drained.
    /// Returns facts for the retirement event; throws when ownership is retained.
    let retire: @Sendable () async throws -> RunnerJSON
}

/// Named, timed load phases with a memory snapshot at each boundary.
final class RunnerLoadPhases: @unchecked Sendable {
    private let log: RunnerEventLog
    private let lock = NSLock()
    private var completed: [String: RunnerJSON] = [:]

    init(log: RunnerEventLog) { self.log = log }

    func run<T>(_ name: String, _ body: () async throws -> T) async throws -> T {
        let start = begin(name)
        do {
            let value = try await body()
            finish(name, start: start, outcome: "ok")
            return value
        } catch {
            finish(name, start: start, outcome: "failed")
            throw error
        }
    }

    /// For phases whose body sends non-Sendable inputs to an actor and so cannot
    /// be wrapped in `run`'s closure.
    func begin(_ name: String) -> ContinuousClock.Instant {
        log.emit("load.phase.begin", ["phase": .string(name), "memory": RunnerProcessMemory.snapshot()])
        return ContinuousClock.now
    }

    func finish(_ name: String, start: ContinuousClock.Instant, outcome: String) {
        let seconds = RunnerJSON.seconds(ContinuousClock.now - start)
        lock.withLock { completed[name] = seconds }
        log.emit("load.phase.end", ["phase": .string(name), "seconds": seconds,
            "outcome": .string(outcome), "memory": RunnerProcessMemory.snapshot()])
    }

    var json: RunnerJSON { lock.withLock { .object(completed) } }
}
