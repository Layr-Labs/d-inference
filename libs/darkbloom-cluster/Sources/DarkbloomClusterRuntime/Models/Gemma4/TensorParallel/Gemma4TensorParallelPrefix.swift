import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLMCommon

/// One Gemma 4 tensor-parallel rank's prompt prefixes: the Gemma pipeline's
/// memory tier (`QwenStagePrefixCache`) and, when the owner configured one,
/// its encrypted SSD tier (`QwenStagePrefixDiskTier`, `cache.disk`), holding
/// only this rank's own KV heads of every layer (26B: 4 sliding, 1 full).
///
/// The pipeline's frontiers and record shape: a request keeps its state at
/// chunk-grid boundaries strictly before the prompt end, on the cache's
/// stride (`QwenLayerStageGenerationRequest.prefixCaptureFrontiers`), the
/// deepest first and then the deepest grid boundaries its capture limit
/// holds; full-attention rows are copied once, at the deepest boundary, and
/// each sliding layer's window at every kept boundary, in the recurrent
/// slots (`QwenLayerStageSession.capturePrefix`). Entries are inserted only
/// after the request retired cleanly on both ranks, and written to the SSD
/// tier behind serving.
///
/// Both ranks key a boundary identically: the load agreement and the
/// request's chunk grid (and on SSD the persistent plan scope), in the
/// request's tenant partition (`ClusterWorkerPrefixCache.scope`). Nothing is
/// assumed: the ranks vote every capture-grid boundary of the prompt in one
/// sealed sum (`QwenTensorParallelPrefixCache.offer`: 1 in memory, 3 only on
/// SSD), take the deepest both offer, read it from their own tiers, and a
/// second sealed sum (`QwenTensorParallelPrefixCache.confirm`) shows both
/// read it before either writes a page; otherwise both prefill from zero.
final class Gemma4TensorParallelPrefix {
    let cache: QwenStagePrefixCache
    /// The resident scope's base: the pair's load agreement.
    let load: String
    /// The SSD tier's persistent scope (`planScope`); nil without the tier.
    let diskPlanScope: String?

    init(cache: QwenStagePrefixCache, load: String, diskPlanScope: String?) {
        self.cache = cache; self.load = load; self.diskPlanScope = cache.disk == nil ? nil : diskPlanScope
    }

    var disk: QwenStagePrefixDiskTier? { cache.disk }

    /// Everything a restored state's bytes depend on that each rank knows at
    /// load, never the membership epoch, so a restarted pair finds what the
    /// last one kept: the plan and its arithmetic terms, the prompt policy,
    /// the arithmetic receipt and profile, the verified artifact and storage,
    /// and both ranks' builds.
    static func planScope(admission: Gemma4ResidentAdmission, aggregateSHA256: String,
                          storageCommitmentSHA256: String) -> String {
        QwenStagePrefixDiskTier.planScope(
            planFingerprint: ([Gemma4TensorParallelPlan.name, "shares=1:1", "arithmetic=" + admission.arithmeticSHA256,
                               "profile=" + admission.profile.fingerprint]
                + Gemma4TensorParallelLoadAgreement.termsFields + Gemma4TensorParallelLoadAgreement.promptPolicyFields)
                .joined(separator: "|"),
            artifactAggregateSHA256: aggregateSHA256, storageCommitmentSHA256: storageCommitmentSHA256,
            rankBuildSHA256: admission.configuration.identity.peers.map(\.buildSHA256),
            generationMode: ClusterGenerationMode.tensorParallel.rawValue, prefillSchedule: "serial|gemma4-tp-prefix-v1")
    }

    /// A request's partition of each tier; nil when it keeps no prefix (the
    /// cache off on this rank or for the request). Both ranks derive the
    /// same value from the request and load they agreed.
    struct Scopes: Equatable {
        let resident: String
        let disk: String?
    }

    func scopes(_ request: QwenLayerStageGenerationRequest) -> Scopes? {
        guard cache.enabled,
              let resident = ClusterWorkerPrefixCache.scope(load + "|gemma4-tp-prefix-v1|chunk=\(request.chunkSize)",
                                                            request.prefixCache) else { return nil }
        let disk = diskPlanScope.flatMap {
            ClusterWorkerPrefixCache.scope($0 + "|chunk=\(request.chunkSize)|kv=paged", request.prefixCache)
        }
        return Scopes(resident: resident, disk: disk)
    }

    /// The boundaries a state of `request` may be kept at and is voted on:
    /// every multiple of the cache's stride (whole chunks) before the
    /// prompt's final token.
    func candidates(_ request: QwenLayerStageGenerationRequest) -> [Int] {
        let step = cache.stride(chunkSize: request.chunkSize)
        guard request.promptCount > step else { return [] }
        return Array(Swift.stride(from: step, through: request.promptCount - 1, by: step))
    }

    /// Both ranks: one sealed sum of this rank's offer for every candidate.
    /// The deepest boundary both offer, and whether either offers it only
    /// from SSD; nil when none (both then prefill from zero).
    func vote(_ request: QwenLayerStageGenerationRequest, scopes: Scopes, candidates: [Int],
              group: any QwenTensorParallelReduction) throws -> (boundary: Int, ssd: Bool)? {
        guard group.size == 2, !candidates.isEmpty else { throw ProbeError("The Gemma tensor-parallel prefix vote takes two ranks") }
        let prompt = request.promptTokenIDs
        let held = Set(cache.frontiers(scope: scopes.resident, tokens: prompt, maximumFrontier: request.promptCount - 1))
        let onDisk = scopes.disk.flatMap { scope in
            disk.map { Set($0.frontiers(scope: scope, tokens: prompt, maximumFrontier: request.promptCount - 1)) }
        } ?? []
        let offers = candidates.map { QwenTensorParallelPrefixCache.offer(inMemory: held.contains($0), onDisk: onDisk.contains($0)) }
        let summed = group.allSum(MLXArray(offers))
        try MLX.withError { error in eval(summed); try error.check() }
        let sums = summed.asArray(Float.self)
        guard sums.count == candidates.count else { throw ProbeError("The Gemma tensor-parallel prefix vote changed shape") }
        return QwenTensorParallelPrefixCache.agreed(sums: sums, candidates: candidates)
    }

    /// This rank's state at the agreed `boundary`: from memory when it holds
    /// it there (the record of the same boundary is touched), else read from
    /// its SSD record and checked to adopt (`adopts`) before anything is
    /// written; nil when this rank cannot restore it (an unreadable record is
    /// deleted by the tier, one that does not adopt here). Only a failed
    /// `check` throws.
    func read(_ boundary: Int, request: QwenLayerStageGenerationRequest, scopes: Scopes,
              geometry: CBv2RequestGeometry, check: () throws -> Void) throws -> (state: QwenStagePrefixState, tier: String)? {
        let prompt = request.promptTokenIDs
        if let state = cache.state(scope: scopes.resident, tokens: prompt, frontier: boundary) {
            if let diskScope = scopes.disk { disk?.touch(scope: diskScope, tokens: prompt, frontier: boundary) }
            return Self.adopts(state, into: geometry) ? (state, "resident") : nil
        }
        guard let disk, let diskScope = scopes.disk,
              let state = try disk.restore(scope: diskScope, tokens: prompt, frontier: boundary, check: check) else {
            return nil
        }
        guard Self.adopts(state, into: geometry) else {
            log("darkbloom-prefix-ssd-v1 rank=\(disk.rank) event=restore-rejected frontier=\(boundary) reason=not_adoptable")
            disk.forget(scope: diskScope, tokens: prompt, frontier: boundary)
            return nil
        }
        return (state, "ssd")
    }

    /// Whether `state` adopts into a request of `geometry` exactly as
    /// `CBv2OwnedRequestState` adopts it: every full-attention layer's rows
    /// at the boundary and every sliding layer's window, with this rank's
    /// head counts, widths and element type, nothing else.
    static func adopts(_ state: QwenStagePrefixState, into geometry: CBv2RequestGeometry) -> Bool {
        let committed = state.committedTokens
        guard committed > 0, state.speculativeHistory == nil, geometry.recurrent.layers.isEmpty,
              state.attention.count + state.recurrent.count == geometry.kinds.count else { return false }
        for kind in geometry.kinds {
            guard let layer = kind.modelLayerIndex else { return false }
            let shape = [1, kind.kvHeads, kind.retainedTokens(atFrontier: committed), kind.headDim]
            let pair: (keys: MLXArray, values: MLXArray)?
            if case .slidingWindow = kind.attention {
                pair = state.recurrent[layer].map { (keys: $0.conv, values: $0.ssm) }
            } else {
                pair = state.attention[layer]
            }
            guard let pair, pair.keys.shape == shape, pair.values.shape == shape,
                  pair.keys.dtype == geometry.kvDType, pair.values.dtype == geometry.kvDType else { return false }
        }
        return true
    }

    /// Opens `request`'s session on this rank, both ranks alike: with the
    /// cache on and a prompt longer than one stride, one sealed vote and, on
    /// an agreed boundary, each rank reads it from its own tiers (`read`) and
    /// restores it into a new session, then one sealed confirmation: unless
    /// both restored, both discard what they restored and prefill from zero.
    /// A state read from SSD becomes resident here, confirmed or not (it is
    /// this rank's valid state there), so the next offer finds it in memory.
    /// `captureLimit`: what this request's capture may hold (0 keeps none).
    /// `stop`: a cancel or deadline while a record is read declines it.
    func open(_ request: QwenLayerStageGenerationRequest, model: Gemma4TensorParallelModel, host: CBv2StageKVHost,
              group: any QwenTensorParallelReduction, captureLimit: Int, stop: @escaping () -> Bool = { false })
        throws -> Gemma4TensorParallelPagedSession {
        let rank = group.rank, prompt = request.promptTokenIDs
        var restored: Gemma4TensorParallelPagedSession?, tier: String?, agreed = 0
        let scopes = scopes(request)
        if let scopes, case let candidates = candidates(request), !candidates.isEmpty,
           let vote = try vote(request, scopes: scopes, candidates: candidates, group: group) {
            agreed = vote.boundary
            struct Stopped: Error {}
            var local: (state: QwenStagePrefixState, tier: String)?
            do {
                let geometry = try Gemma4TensorParallelPagedSession.geometry(model: model, host: host,
                    maximumTokens: request.maximumTokens)
                local = try read(vote.boundary, request: request, scopes: scopes, geometry: geometry,
                    check: { if stop() { throw Stopped() } })
            } catch is Stopped {
                local = nil
            }
            if let local {
                do {
                    restored = try Gemma4TensorParallelPagedSession(model: model, host: host,
                        promptCount: request.promptCount, outputCount: request.outputCount, restoring: local.state)
                    tier = local.tier
                } catch {
                    // This rank could not restore; the confirmation says so.
                    log("darkbloom-prefix-v1 rank=\(rank) family=gemma4 restore-failed frontier=\(vote.boundary): \(error)")
                    if local.tier == "ssd", let diskScope = scopes.disk {
                        disk?.forget(scope: diskScope, tokens: prompt, frontier: vote.boundary)
                    }
                }
            }
            let both: Bool
            do { both = try QwenTensorParallelPrefixCache.confirm(restored != nil, group: group) } catch {
                try? restored?.retire(failed: true)
                throw error
            }
            if let local, local.tier == "ssd", restored != nil {
                cache.insert(scope: scopes.resident, tokens: prompt, states: [local.state], sharedBytes: local.state.sharedBytes)
            }
            if !both {
                log("darkbloom-prefix-ssd-v1 rank=\(rank) event=restore-declined frontier=\(vote.boundary)"
                    + " tier=\(tier ?? "none") local=\(restored != nil ? 1 : 0) kept=\(tier == "ssd" ? 1 : 0)")
                try restored?.retire()
                restored = nil; tier = nil
            }
        }
        let session = try restored ?? Gemma4TensorParallelPagedSession(model: model, host: host,
            promptCount: request.promptCount, outputCount: request.outputCount)
        if scopes != nil, captureLimit > 0 {
            // The pipeline's rule for chunk-grid families: existing grid ends after
            // the restored prefix, strictly before the prompt end.
            let step = cache.stride(chunkSize: request.chunkSize)
            let frontiers = Set(Swift.stride(from: (session.reusedPrefixTokens / step + 1) * step,
                                             to: request.promptCount, by: step))
            if !frontiers.isEmpty {
                session.prefixCapture = .init(frontiers: frontiers, limitBytes: captureLimit,
                    maximumFrontiers: cache.frontiersPerPrompt)
            }
        }
        if agreed > 0 {
            log("darkbloom-prefix-v1 rank=\(rank) family=gemma4 mode=tensor_parallel agreed=\(agreed)"
                + " reused=\(session.reusedPrefixTokens) prompt=\(request.promptCount) tier=\(tier ?? "none")")
        }
        return session
    }

    /// What `request`'s capture may hold on this rank: the pipeline's limit
    /// (`QwenStagePrefixCache.captureLimit`: after the deepest prefix this
    /// rank holds for it, at the measured cost, within the budget); 0 when it
    /// keeps no prefix.
    func captureLimit(_ request: QwenLayerStageGenerationRequest) -> Int {
        guard let scopes = scopes(request) else { return 0 }
        return cache.captureLimit(scope: scopes.resident, tokens: request.promptTokenIDs, chunkSize: request.chunkSize)
    }

    /// After a request retired cleanly on both ranks: its capture becomes
    /// reusable in memory and is written to the SSD tier behind serving.
    /// Returns the boundaries kept.
    @discardableResult
    func store(_ capture: Gemma4TensorParallelPrefixCapture, request: QwenLayerStageGenerationRequest, scopes: Scopes,
               rank: Int) -> [Int] {
        defer { capture.discard() }
        let states = capture.states()
        guard !states.isEmpty else { return [] }
        let prompt = request.promptTokenIDs
        cache.insert(scope: scopes.resident, tokens: prompt, states: states, sharedBytes: capture.sharedBytes)
        if let diskScope = scopes.disk {
            disk?.persist(scope: diskScope, tokens: prompt, states: states, blockTokens: cache.stride(chunkSize: request.chunkSize))
        }
        if let cost = capture.cost { cache.record(cost) }
        log("darkbloom-prefix-v1 rank=\(rank) family=gemma4 mode=tensor_parallel held_bytes=\(cache.bytesInUse)"
            + " budget_bytes=\(cache.budgetBytes) capture_limit=\(capture.limitBytes) captured_shared=\(capture.sharedBytes)"
            + " stored=\(states.map { String($0.committedTokens) }.joined(separator: ","))")
        return states.map(\.committedTokens)
    }
}

extension Gemma4TensorParallelModel {
    /// Oracles and tests: what a rank's prompt-prefix memory tier gives a
    /// repeated prompt, on this shard's own paged host. `prompt` is served
    /// cold and keeps its boundaries (every `chunk`), then `repeated` (by
    /// default the same prompt) votes, restores the deepest boundary both
    /// ranks hold and continues from it, as the resident runtime serves it.
    /// Both ranks call it with the same values.
    public func generatePagedRepeatingPrefix(prompt: [Int], repeated: [Int]? = nil, outputCount: Int, chunk: Int,
                                             recordTop: Int = 0)
        throws -> (cold: Generation, restored: Generation, reusedPromptTokens: Int, storedFrontiers: [Int]) {
        let second = repeated ?? prompt
        guard case .shard = role, let reduction, !prompt.isEmpty, !second.isEmpty, outputCount >= 1, chunk >= 1,
              (prompt + second).allSatisfy({ (0 ..< plan.vocabularySize).contains($0) }), (0 ... 64).contains(recordTop) else {
            throw ProbeError("Gemma tensor-parallel prefix oracle: a shard, two prompts in the vocabulary, bounded options")
        }
        let longest = max(prompt.count, second.count)
        let activation = String(describing: activationDType)
        let profile = try QwenLayerStageGenerationProfile(identifier: "gemma4-tensor-parallel-prefix",
            vocabularySize: plan.vocabularySize, hiddenSize: plan.hiddenSize, activationDType: activation,
            maximumPromptTokens: longest, maximumChunkTokens: chunk, maximumOutputTokens: outputCount,
            maximumContextTokens: longest + outputCount, logitsDType: activation == "float32" ? nil : "float32")
        let prefix = Gemma4TensorParallelPrefix(cache: QwenStagePrefixCache(strideTokens: chunk),
            load: "gemma4-tensor-parallel-prefix-oracle|" + Gemma4TensorParallelPlan.name, diskPlanScope: nil)
        let host = try pagedHost(lanes: 1, maximumTokens: longest + outputCount, chunkTokens: chunk)
        func serve(_ tokens: [Int], index: Int) throws -> (generation: Generation, reused: Int, stored: [Int]) {
            let request = try QwenLayerStageGenerationRequest(profile: profile,
                requestID: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index))!,
                promptTokenIDs: tokens, chunkSize: chunk, outputCount: outputCount, stopTokenIDs: [])
            let session = try MLX.withError { error -> Gemma4TensorParallelPagedSession in
                let value = try prefix.open(request, model: self, host: host, group: reduction,
                    captureLimit: prefix.captureLimit(request))
                try error.check()
                return value
            }
            let generation = try generatePaged(session: session, host: host, prompt: tokens, outputCount: outputCount,
                chunk: chunk, recordTop: recordTop)
            var stored: [Int] = []
            if let capture = session.prefixCapture, let scopes = prefix.scopes(request) {
                stored = prefix.store(capture, request: request, scopes: scopes, rank: reduction.rank)
            }
            return (generation, session.reusedPrefixTokens, stored)
        }
        let cold = try serve(prompt, index: 0)
        let restored = try serve(second, index: 1)
        return (cold.generation, restored.generation, restored.reused, cold.stored)
    }
}

/// One request's prefix capture on a Gemma 4 tensor-parallel rank: the
/// boundaries it was asked to keep, what it keeps within its limit (measured
/// at its first boundary, `QwenStagePrefixCaptureCost.kept`), and the copies,
/// as the pipeline's stage session keeps them (`QwenLayerStageSession.capturePrefix`).
final class Gemma4TensorParallelPrefixCapture {
    let frontiers: Set<Int>
    let limitBytes: Int
    let maximumFrontiers: Int
    private(set) var cost: QwenStagePrefixCaptureCost?
    private var kept: Set<Int>?
    private(set) var withdrawn = false
    /// Each kept boundary's sliding windows, keyed by layer.
    private var windows: [Int: [Int: (conv: MLXArray, ssm: MLXArray)]] = [:]
    /// Full-attention rows copied once, at the deepest boundary.
    private var deepest: (committed: Int, layers: [Int: (keys: MLXArray, values: MLXArray)])?

    init(frontiers: Set<Int>, limitBytes: Int, maximumFrontiers: Int) {
        self.frontiers = frontiers; self.limitBytes = max(0, limitBytes); self.maximumFrontiers = maximumFrontiers
    }

    /// After the prompt chunk that committed `frontier` (`state` is the
    /// request's). A sliding row holds only its window, oldest first: its
    /// state at a boundary is its own and is copied now (the ring takes
    /// later tokens in place); full rows are copied at the deepest boundary.
    func capture(_ state: CBv2OwnedRequestState, at frontier: Int) throws {
        guard frontiers.contains(frontier), !withdrawn else { return }
        guard state.committedTokens == frontier else { throw ProbeError("Gemma tensor-parallel prefix capture differs from the committed frontier") }
        var rows: [Int: (keys: MLXArray, values: MLXArray)] = [:]
        var tails: [Int: (keys: MLXArray, values: MLXArray)] = [:], windowBytes = 0
        for (position, optionalRow) in state.rows.enumerated() {
            let kind = state.geometry.kinds[position]
            guard let row = optionalRow, let layer = kind.modelLayerIndex else {
                throw ProbeError("Gemma tensor-parallel prefix capture lacks an attention row")
            }
            let snapshot = row.snapshot()
            let retained = kind.retainedTokens(atFrontier: frontier)
            guard snapshot.offset == frontier, snapshot.keys.dim(2) == retained, retained > 0 else {
                throw ProbeError("Gemma tensor-parallel prefix capture frontier differs from a row's")
            }
            if case .slidingWindow(let window) = kind.attention {
                tails[layer] = (snapshot.keys, snapshot.values)
                // Every boundary is charged a full window: one taken before the
                // prompt filled it is shorter than every later one.
                let perPosition = (snapshot.keys.nbytes + snapshot.values.nbytes + retained - 1) / retained
                windowBytes = try QwenLongPrefillCheckedBytes.sum([windowBytes,
                    try QwenLongPrefillCheckedBytes.product([perPosition, window])])
            } else {
                rows[layer] = (snapshot.keys, snapshot.values)
            }
        }
        let planned = frontiers.sorted()
        if kept == nil {
            let attention = rows.values.reduce(0) { $0 + $1.keys.nbytes + $1.values.nbytes }
            let measured = QwenStagePrefixCaptureCost(attentionBytesPerToken: (attention + frontier - 1) / frontier,
                recurrentBytesPerFrontier: windowBytes, historyBytesPerToken: 0)
            cost = measured
            kept = measured.kept(planned, limit: limitBytes, maximum: maximumFrontiers)
        }
        guard kept?.contains(frontier) == true else { return }
        func copy(_ value: MLXArray) -> MLXArray { value * MLXArray(1).asType(value.dtype) }
        let own = tails.mapValues { (conv: copy($0.keys), ssm: copy($0.values)) }
        eval(own.values.flatMap { [$0.conv, $0.ssm] })
        windows[frontier] = own
        guard frontier == planned.last else { return }
        let copies = rows.mapValues { (keys: copy($0.keys), values: copy($0.values)) }
        eval(copies.values.flatMap { [$0.keys, $0.values] })
        deepest = (frontier, copies)
    }

    /// The kept boundaries' states, ascending, each viewing the one copy of
    /// the full rows; empty unless the deepest was reached.
    func states() -> [QwenStagePrefixState] {
        guard let deepest, !withdrawn else { return [] }
        return windows.keys.sorted().compactMap { frontier in
            guard frontier <= deepest.committed, let own = windows[frontier] else { return nil }
            let rows = deepest.layers.mapValues { pair -> (keys: MLXArray, values: MLXArray) in
                frontier == deepest.committed ? pair
                    : (keys: pair.keys[0..., 0..., 0 ..< frontier, 0...], values: pair.values[0..., 0..., 0 ..< frontier, 0...])
            }
            return QwenStagePrefixState(committedTokens: frontier, attention: rows, recurrent: own)
        }
    }

    /// Bytes of the full-row copy the kept states view together.
    var sharedBytes: Int { deepest?.layers.values.reduce(0) { $0 + $1.keys.nbytes + $1.values.nbytes } ?? 0 }

    /// Bytes this capture holds now.
    var heldBytes: Int {
        sharedBytes + windows.values.reduce(0) { total, own in total + own.values.reduce(0) { $0 + $1.conv.nbytes + $1.ssm.nbytes } }
    }

    /// The running check withdrew it: let go of what it holds, capture no more.
    func withdraw() { withdrawn = true; windows.removeAll(); deepest = nil }

    func discard() { windows.removeAll(); deepest = nil; kept = nil }
}
