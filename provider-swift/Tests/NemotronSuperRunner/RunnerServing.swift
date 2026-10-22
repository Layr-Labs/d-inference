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
    /// KV headroom the LOAD claim holds; nil claims the whole grant.
    var admissionKVBytes: Int? = nil
    /// `--emulate-physical-gib`; nil on this machine's own memory.
    var emulation: RunnerMemoryEmulation? = nil

    /// The managed slot's LOAD KV headroom under this grant
    /// (`NemotronSuperServingPolicy.loadPlan`): every configured request's
    /// fixed bytes, a speculating owner's round work at `contextTokens`, 2 GiB
    /// and the owner's prefix bank, never above the grant.
    static func managedAdmissionKVBytes(grantBytes: Int, environment: [String: String],
                                        contextTokens: Int) -> Int {
        let speculates = environment[NemotronSuperLocalMTP.enabledKey]?.trimmingCharacters(in: .whitespaces) == "1"
        let requests = (try? NemotronSuperLocalBridgeBuilder.concurrentRequests(
            environment: environment, speculates: speculates)) ?? 1
        let bank = NemotronSuperLocalPrefixCache.config(environment: environment, kvBytesCapacity: grantBytes,
            requests: requests, speculates: speculates)?.maximumBytes ?? 0
        return min(grantBytes,
            NemotronSuperServingPolicy.admissionKVBytes(requests: requests, speculates: speculates,
                environment: environment, contextTokens: contextTokens) + bank)
    }

    /// The opt-in speculation the engine environment selects; the load
    /// transaction reads the same entries. nil is the plain arm.
    func speculation() throws -> NemotronSuperLocalMTP.Setting? {
        try NemotronSuperLocalMTP.Setting.resolve(environment: engineEnvironment)
    }

    /// The identity's `speculation`, spelled with the verification switch's
    /// values; exhaustive so a new SDK mode cannot be recorded as another.
    static func speculationJSON(_ setting: NemotronSuperLocalMTP.Setting?) -> RunnerJSON {
        guard let setting else { return .null }
        let verification = switch setting.verification {
        case .rectangularExact: "rectangular"
        case .serial: "serial"
        }
        return ["depth": .count(setting.depth), "verification": .string(verification),
                "adaptive": .bool(setting.adaptive),
                "depth_by_requests": setting.depthByRequests.map { .array($0.map { .count($0) }) } ?? .null]
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

/// The bridge's KV grant against the smallest grant that serves its configured
/// requests at once: the same minimum a refused grant reports.
enum RunnerKVGrant {
    static func json(bridge: EngineV2Bridge, grantBytes: Int) async -> RunnerJSON {
        let requests = await bridge.maxConcurrentRequests
        return [
            "grant_bytes": .bytes(grantBytes),
            "minimum_grant_bytes": .bytes(await bridge.superMinimumGrantBytes(requests: requests)),
            "fixed_request_bytes": (await bridge.maximumRequestOverheadBytes()).map { .bytes($0) } ?? .null,
            "requests": .count(requests),
            "serving_concurrency": .count(await bridge.effectiveServingConcurrency),
            // Each request's shared reservation adds these per token of its
            // prompt plus max_tokens (auxiliary: the assistant's history).
            "kv_bytes_per_token": .bytes(await bridge.kvBytesPerToken),
            "auxiliary_bytes_per_token": .bytes(await bridge.auxiliaryBytesPerToken),
        ]
    }

    static func json(_ refusal: NemotronSuperLocalBridgeBuilder.UnserviceableGrant) -> RunnerJSON {
        [
            "grant_bytes": .bytes(refusal.grantBytes), "minimum_grant_bytes": .bytes(refusal.minimumGrantBytes),
            "fixed_request_bytes": .bytes(refusal.fixedRequestBytes), "requests": .count(refusal.requests),
            "suggested_kv_capacity_gib": suggestedGib(refusal.minimumGrantBytes).map { .count($0) } ?? .null,
        ]
    }

    /// Whole GiB at or above `bytes`; nil for the unprovable `Int.max` minimum.
    static func suggestedGib(_ bytes: Int) -> Int? {
        guard bytes < Int.max else { return nil }
        let (gib, remainder) = bytes.quotientAndRemainder(dividingBy: 1 << 30)
        return remainder > 0 ? gib + 1 : gib
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
