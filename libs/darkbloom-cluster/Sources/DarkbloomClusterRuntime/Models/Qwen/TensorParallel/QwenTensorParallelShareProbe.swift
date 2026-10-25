import DarkbloomClusterProtocol
import Foundation
import MLX

/// The reduction a product shard is loaded with: the pair's own
/// (`QwenTensorParallelGroup`), except inside `locally`, where every all-sum
/// returns this rank's partial unchanged (`QwenTensorParallelLocalReduction`):
/// nothing crosses the cable and the outputs are no tensor-parallel result.
/// A graph takes the reduction it is built with, so only graphs built and
/// evaluated inside `locally` are local. Only the share probe uses it, at
/// load, on the owner's serial executor, before the runtime serves.
final class QwenTensorParallelSwitchableReduction: QwenTensorParallelReduction {
    let peer: any QwenTensorParallelReduction
    private(set) var local = false
    var rank: Int { peer.rank }
    var size: Int { peer.size }

    init(_ peer: any QwenTensorParallelReduction) { self.peer = peer }

    func allSum(_ value: MLXArray) -> MLXArray { local ? value : peer.allSum(value) }

    /// `body` with every all-sum local; the pair's own again after it, whatever it throws.
    func locally<T>(_ body: () throws -> T) throws -> T {
        guard !local else { throw ProbeError("Tensor-parallel reduction is already local") }
        local = true
        defer { local = false }
        return try body()
    }
}

/// What a dense Qwen tensor-parallel rank measures of its own share at load,
/// after its weights and before its ready record, with no peer traffic: every
/// reduction local (`QwenTensorParallelSwitchableReduction`), so each rank
/// times only what its share computes between reductions. One throwaway
/// request of `promptTokens` synthetic tokens on a KV host of its own (the
/// load's backend, one lane) is prefilled, then a few warm-up rounds and the
/// timed ones of the plain decode step (one row, one token) and, when the load
/// serves the model's speculative head, of the verify window (one row, depth
/// + 1 tokens, verified and settled); medians in microseconds. The request is
/// retired and its pages freed before the runtime serves.
///
/// The same local timing (`QwenTensorParallelVerifyBenchTests`, 27B, c38
/// kernels, 2026-10-24) put the slower rank's step plus about 8.5 ms of
/// reductions a token within about 1 ms of the pair's served decode at 2:1,
/// 1:1 and 2:3. The pair's owner keeps the probes (`ClusterShareProbeHistory`)
/// and the planner balances the shares by them.
///
/// It never fails or holds up a load: memory the gate does not admit, a load
/// deadline too close, or any error gives no probe, and the timed rounds stop
/// at `budgetNanoseconds`. Only a throwaway state that cannot be retired
/// fails the load, since its native work may still be running.
enum QwenTensorParallelShareProbe {
    static let promptTokens = 64
    static let warmupRounds = 2
    static let timedRounds = 7
    /// Fewest timed rounds a figure is given from.
    static let minimumRounds = 3
    static let budgetNanoseconds: UInt64 = 1_500_000_000
    /// No probe when the load's deadline is nearer than this.
    static let deadlineMarginNanoseconds: UInt64 = 10_000_000_000

    /// This rank's share in per mille of every divided part; nil outside 1...999.
    static func sharePerMille(shares: [Int], rank: Int) -> Int? {
        guard shares.indices.contains(rank), shares.allSatisfy({ $0 > 0 }) else { return nil }
        let value = Int((Double(shares[rank]) / Double(shares.reduce(0, +)) * 1000).rounded())
        return (1...999).contains(value) ? value : nil
    }

    /// The probe request's prompt (one chunk) and answer: room for every round.
    static func requestShape(profile: QwenLayerStageGenerationProfile, windowColumns: Int?) -> (prompt: Int, outputs: Int) {
        (min(promptTokens, profile.maximumChunkTokens, profile.maximumPromptTokens),
         1 + (warmupRounds + timedRounds) * (1 + (windowColumns ?? 0)))
    }

    /// The live memory the probe request needs (`bytes`, its complete quote)
    /// with the loading headroom on top, and the allocator room, as a
    /// reservation entering a ready owner is asked; no reclaim is started.
    static func memoryAdmits(bytes: Int) throws -> Bool {
        let os = try QwenDenseStageLoadResources.observeOS()
        let required = try QwenLongPrefillCheckedBytes.sum([bytes, QwenDenseStageLoadPolicy.loadingHeadroomBytes])
        let allocator = try QwenLongPrefillCheckedBytes.sum([Memory.activeMemory, Memory.cacheMemory, bytes,
            QwenDenseStageLoadPolicy.allocatorHeadroomBytes])
        let decision = try QwenDenseStageLoadPolicy.decide(os, requiredBytes: required, purpose: "Tensor-parallel share probe",
            now: DispatchTime.now().uptimeNanoseconds, floor: QwenDenseStageLoadPolicy.loadingHeadroomBytes)
        return decision.admitted && Memory.memoryLimit >= allocator
    }

    /// Nil when the probe does not run or does not finish: the reason is
    /// logged. `admit` answers whether memory admits a probe request of that
    /// many tokens and that chunk; `check` is the load's own (cancellation,
    /// deadline); `deadline` its absolute uptime deadline.
    static func measure(model: QwenTensorParallelModel, reduction: QwenTensorParallelSwitchableReduction,
                        configuration: Data, profile: QwenLayerStageGenerationProfile, shares: [Int],
                        kind: ClusterStageKVBackendKind, windowColumns: Int?, deadline: UInt64,
                        admit: (_ maximumTokens: Int, _ chunkTokens: Int) throws -> Bool, check: () throws -> Void,
                        clock: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) throws -> ClusterWorkerShareProbe? {
        let rank = reduction.rank
        func skipped(_ reason: String) -> ClusterWorkerShareProbe? {
            log("darkbloom-share-probe-v1 rank=\(rank) skipped=\(reason)"); return nil
        }
        guard case .shard(let shardRank, let size) = model.role, shardRank == rank, size == 2, reduction.size == 2,
              !model.plan.routedExperts, let share = sharePerMille(shares: shares, rank: rank),
              windowColumns.map({ (2...5).contains($0) }) ?? true else { return skipped("unsupported") }
        let shape = requestShape(profile: profile, windowColumns: windowColumns)
        let started = clock()
        guard deadline > started, deadline - started >= deadlineMarginNanoseconds else { return skipped("deadline") }
        do {
            guard try admit(shape.prompt + shape.outputs, shape.prompt) else { return skipped("memory") }
        } catch { return skipped("memory") }
        // As a ready rank steps: with its bounded freed-buffer cache, emptied afterwards (`QwenTensorParallelLinkProbe`).
        let previousCacheLimit = Memory.cacheLimit
        Memory.cacheLimit = max(previousCacheLimit, QwenTensorParallelLaunch.freedBufferCacheBytes(
            allocatorHeadroomBytes: QwenDenseStageLoadPolicy.allocatorHeadroomBytes))
        defer { Memory.cacheLimit = previousCacheLimit; Memory.clearCache() }
        var session: QwenTensorParallelBatchSession?
        do {
            let times = try reduction.locally { () throws -> (plain: [UInt64], window: [UInt64]) in
                try MLX.withError { error -> (plain: [UInt64], window: [UInt64]) in
                    func checked() throws { try error.check(); try check() }
                    let host = try CBv2StageKVHost(model: model.model, kind: kind, lanes: 1,
                        maximumTokensPerRequest: shape.prompt + shape.outputs,
                        maximumChunkTokens: max(shape.prompt, windowColumns ?? 1))
                    let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
                        promptTokenIDs: (0..<shape.prompt).map { ($0 * 131 + 17) % profile.vocabularySize },
                        chunkSize: shape.prompt, outputCount: shape.outputs, stopTokenIDs: [])
                    let value = try QwenTensorParallelBatchSession(model: model, configuration: configuration,
                        host: host, request: request)
                    session = value
                    while value.schedule.committedPromptTokens < request.promptCount { _ = try value.prefill(check: checked) }
                    // Any token will do: the outputs are not a tensor-parallel result.
                    var token = 1
                    func next() -> Int { token = (token * 37 + 11) % profile.vocabularySize; return token }
                    func timed(_ round: () throws -> Void) throws -> [UInt64] {
                        var times: [UInt64] = []
                        for index in 0..<(warmupRounds + timedRounds) {
                            if index >= warmupRounds, clock() - started >= budgetNanoseconds { break }
                            let roundStarted = clock()
                            // Encoded as the native executor encodes a decode round (`decodeCommandBuffers`).
                            try GPU.withCommandBufferLimits(QwenTensorParallelBatchSession.decodeCommandBuffers) { try round() }
                            if index >= warmupRounds { times.append(clock() - roundStarted) }
                        }
                        return times
                    }
                    let plain = try timed {
                        _ = try QwenTensorParallelBatchSession.decode([value], tokens: [next()], check: checked)
                    }
                    var window: [UInt64] = []
                    if let columns = windowColumns, plain.count >= minimumRounds, clock() - started < budgetNanoseconds {
                        window = try timed {
                            let tokens = MLXArray((0..<columns).map { _ in Int32(next()) }).reshaped([1, columns])
                            let built = try QwenTensorParallelBatchSession.beginWindows([value], tokens: tokens)
                            eval(built.outputs + built.roots)
                            try QwenTensorParallelBatchSession.confirmWindows([value], check: checked)
                            eval(try QwenTensorParallelBatchSession.settleWindows([value], keeping: [columns]))
                            try QwenTensorParallelBatchSession.confirmSettledWindows([value], check: checked)
                        }
                    }
                    try value.retire()
                    guard host.isDrained else { throw ProbeError("Tensor-parallel share probe kept its pages") }
                    return (plain, window)
                }
            }
            func median(_ values: [UInt64]) -> Int { max(1, Int(values.sorted()[values.count / 2] / 1000)) }
            guard times.plain.count >= minimumRounds else { return skipped("budget") }
            let windowed = times.window.count >= minimumRounds
            let probe = ClusterWorkerShareProbe(sharePerMille: share, plainStepMicroseconds: median(times.plain),
                windowColumns: windowed ? windowColumns : nil, windowStepMicroseconds: windowed ? median(times.window) : nil,
                rounds: times.plain.count)
            return probe.valid ? probe : skipped("bounds")
        } catch {
            // The throwaway request goes whatever failed; one that cannot be retired fails the load.
            if let session, !session.retired {
                do { try session.retire() } catch {
                    throw ProbeError("Tensor-parallel share probe could not retire its request (\(error))")
                }
            }
            return skipped("error_" + qwenPrefixLogWord(error))
        }
    }

    /// The probe a resident load runs (`QwenTensorParallelResidentRuntime.load`):
    /// the probe request's memory priced by the load's own batch ledger
    /// (`QwenTensorParallelBatchBudget`, one lane of the probe's tokens), the
    /// load's own check and deadline, the window when it serves the head; logged.
    static func atLoad(model: QwenTensorParallelModel, reduction: QwenTensorParallelSwitchableReduction,
                       admission: QwenResidentAdmission, profile: QwenRegisteredDenseModelProfile, shares: [Int],
                       backend: ClusterStageKVBackendKind, depth: Int?, control: QwenResidentControl) throws -> ClusterWorkerShareProbe? {
        let probe = try measure(model: model, reduction: reduction, configuration: admission.configBytes,
            profile: admission.profile, shares: shares, kind: backend, windowColumns: depth.map { $0 + 1 },
            deadline: control.deadline, admit: { tokens, chunk in
                try memoryAdmits(bytes: QwenTensorParallelBatchBudget.derive(geometry: profile.geometry, plan: model.plan,
                    tensors: profile.canonicalTensors, maximumTokens: tokens, chunkSize: chunk, lanes: 1,
                    paged: backend == .paged, rank: reduction.rank,
                    allocationBound: QwenResidentResourceEnvironment.allocationBound).allowance.reservedBytes)
            }, check: { try control.check() })
        if let probe { log(line(probe, rank: reduction.rank)) }
        return probe
    }

    static func line(_ p: ClusterWorkerShareProbe, rank: Int) -> String {
        "darkbloom-share-probe-v1 rank=\(rank) share_per_mille=\(p.sharePerMille) plain_step_us=\(p.plainStepMicroseconds)"
            + " window_columns=\(p.windowColumns ?? 0) window_step_us=\(p.windowStepMicroseconds ?? 0) rounds=\(p.rounds)"
    }
}
