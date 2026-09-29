import Foundation
import MLXLMCommon

/// Each registered runtime shares one tracker. A begin marks overlap on both
/// intervals; capture never clears it. This catches other-model work that ended
/// before the next heartbeat, without putting an actor hop on the engine queue.
final class EngineMeasurementActivity: @unchecked Sendable {
    struct Overlap: Sendable {
        var contended = false
        var otherModel = false
    }
    private struct Entry {
        let model: String
        var overlap = Overlap()
    }
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]

    func begin(model: String) -> UUID {
        lock.withLock {
            let id = UUID()
            var entry = Entry(model: model)
            for (key, old) in entries {
                entry.overlap.contended = true
                entry.overlap.otherModel = entry.overlap.otherModel || old.model != model
                entries[key]?.overlap.contended = true
                entries[key]?.overlap.otherModel = old.overlap.otherModel || old.model != model
            }
            entries[id] = entry
            return id
        }
    }

    func snapshot(_ id: UUID) -> Overlap {
        lock.withLock { entries[id]?.overlap ?? Overlap(contended: true, otherModel: true) }
    }

    func end(_ id: UUID) { _ = lock.withLock { entries.removeValue(forKey: id) } }
}

/// One receipt per submission, never keyed solely by a reusable request ID.
final class EnginePrefillReceipt: @unchecked Sendable {
    struct Sample: Sendable {
        let usage: CBv2Usage
        let at: ContinuousClock.Instant
        let overlap: EngineMeasurementActivity.Overlap
    }
    let activity: EngineMeasurementActivity
    let activityID: UUID
    private let lock = NSLock()
    private var sample: Sample?
    private var consumed = false
    private var ended = false
    private var retirementOwned = false

    init(activity: EngineMeasurementActivity, model: String) {
        self.activity = activity
        activityID = activity.begin(model: model)
    }

    func complete(_ usage: CBv2Usage) {
        let overlap = activity.snapshot(activityID)
        lock.withLock {
            guard sample == nil else { return }
            sample = Sample(usage: usage, at: .now, overlap: overlap)
        }
    }

    func take() -> Sample? {
        lock.withLock {
            guard !consumed, let sample else { return nil }
            consumed = true
            return sample
        }
    }

    var overlap: EngineMeasurementActivity.Overlap { activity.snapshot(activityID) }

    /// A consumer terminal can precede engine cleanup. The retirement owner
    /// keeps this interval visible after active-state accounting ends.
    func retainUntilRetirement() {
        lock.withLock { retirementOwned = true }
    }

    func end() {
        end(retirementComplete: false)
    }

    func endAfterRetirement() {
        end(retirementComplete: true)
    }

    private func end(retirementComplete: Bool) {
        let release = lock.withLock {
            guard !ended, !retirementOwned || retirementComplete else { return false }
            ended = true
            return true
        }
        if release { activity.end(activityID) }
    }
    deinit { endAfterRetirement() }
}

/// Actor-owned bounded EWMAs. Equal new rates still increment count and refresh
/// age, while unchanged heartbeat snapshots never rejuvenate an observation.
struct EnginePerformanceMeasurements {
    private struct Rate {
        var value: Double
        var count: Int64 = 1
        var at: ContinuousClock.Instant
        mutating func observe(_ tps: Double, at now: ContinuousClock.Instant) {
            value = 0.3 * tps + 0.7 * value
            count = count == .max ? .max : count + 1
            at = now
        }
        func wire(now: ContinuousClock.Instant) -> PerformanceRateObservation {
            let seconds = max(0, WedgeMonitor.seconds(now - at))
            return .init(tokensPerSecond: value, sampleCount: count,
                sampleAgeMs: Int64(min(Double(Int64.max), seconds * 1_000)))
        }
    }
    private struct Key: Hashable {
        let phase: String
        let prompt: Int
        let context: Int
        let cache: String
        let contended: Bool
        let otherModel: Bool
    }
    let epoch = UUID().uuidString
    private var rates: [String: Rate] = [:]
    private var buckets: [Key: Rate] = [:]
    static let maxBuckets = 32

    mutating func observe(
        _ name: String, tps: Double, prompt: Int, context: Int,
        cache: String, overlap: EngineMeasurementActivity.Overlap,
        at now: ContinuousClock.Instant = .now
    ) {
        guard tps.isFinite, tps > 0 else { return }
        if var rate = rates[name] { rate.observe(tps, at: now); rates[name] = rate }
        else { rates[name] = Rate(value: tps, at: now) }
        guard name == "isolated_prefill" || name == "contended_prefill" || name == "reuse_prefill" || name == "decode" else { return }
        let key = Key(phase: name == "decode" ? "decode" : "prefill",
            prompt: Self.bucket(prompt), context: Self.bucket(context), cache: cache,
            contended: overlap.contended, otherModel: overlap.otherModel)
        if var rate = buckets[key] { rate.observe(tps, at: now); buckets[key] = rate }
        else {
            if buckets.count >= Self.maxBuckets,
                let oldest = buckets.min(by: { $0.value.at < $1.value.at })?.key {
                buckets.removeValue(forKey: oldest)
            }
            buckets[key] = Rate(value: tps, at: now)
        }
    }

    static func bucket(_ tokens: Int) -> Int {
        for ceiling in [1_024, 4_096, 16_384, 32_768, 65_536] where tokens <= ceiling { return ceiling }
        return 131_072
    }

    func snapshot(now: ContinuousClock.Instant = .now) -> PerformanceMeasurements {
        let workload = buckets.map { key, rate in
            PerformanceWorkloadBucket(phase: key.phase, promptTokenBucket: key.prompt,
                contextTokenBucket: key.context, cacheState: key.cache,
                contention: key.contended ? "contended" : "isolated",
                otherModelActivity: key.otherModel, observation: rate.wire(now: now))
        }.sorted {
            ($0.phase, $0.promptTokenBucket, $0.contextTokenBucket, $0.cacheState, $0.contention, $0.otherModelActivity ? 1 : 0)
                < ($1.phase, $1.promptTokenBucket, $1.contextTokenBucket, $1.cacheState, $1.contention, $1.otherModelActivity ? 1 : 0)
        }
        return PerformanceMeasurements(epoch: epoch,
            isolatedPrefill: rates["isolated_prefill"]?.wire(now: now),
            contendedPrefill: rates["contended_prefill"]?.wire(now: now),
            decode: rates["decode"]?.wire(now: now),
            deliveredDecode: rates["delivered_decode"]?.wire(now: now),
            endToEnd: rates["end_to_end"]?.wire(now: now), workloadBuckets: workload)
    }
}
