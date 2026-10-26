import DarkbloomClusterProtocol
import Foundation
import MLX

final class QwenTensorParallelNativeBatchLane: QwenTensorParallelBatchLane {
    let session: QwenTensorParallelBatchSession
    var pendingLogprobs: ClusterWorkerTokenLogprobs?
    var assistant: QwenTensorParallelMTPDecoder?
    var accepted = QwenTensorParallelAcceptedSelections()
    var selectedCount = 0
    var canSelectNext: Bool { !accepted.isEmpty || nextFrame?.phase == .decode }
    var prefixKey: String?
    /// This request's scope on the SSD tier, kept for its persist after a
    /// confirmed clean retirement.
    var prefixDiskScope: String?
    var storedPrefixFrontiers: [Int] = []
    var reusedPrefixTokens: Int { session.request.reusedPrefixTokens }
    private let releaseResources: () throws -> Void
    private(set) var resourcesReleased = false
    init(_ session: QwenTensorParallelBatchSession, releaseResources: @escaping () throws -> Void) {
        self.session = session; self.releaseResources = releaseResources
    }
    func releaseAfterNativeDrain() throws {
        guard session.retired && session.state.isClosed else { throw ProbeError("Qwen TP lane native state is not retired") }
        if !resourcesReleased { try releaseResources(); resourcesReleased = true }
    }
    var nextFrame: QwenLayerStageFrame? {
        guard !session.retired else { return nil }
        return try? session.request.frame(sequence: session.schedule.nextSequence)
    }
    var committedTokens: Int { session.committedTokens }
    var isClosed: Bool { session.retired && session.state.isClosed && resourcesReleased }
}

/// The TP driver's native adapter. The owner validates the exact model,
/// sealed group, load agreement and full admission before constructing this
/// value. `prepare` performs the bilateral full request/media agreement and
/// returns request-owned positions/features without model-global mutation.
final class QwenTensorParallelNativeBatchExecutor<Reservation: QwenTensorParallelBatchReservation>: QwenTensorParallelBatchExecutor {
    typealias Lane = QwenTensorParallelNativeBatchLane
    let rank: Int
    private let model: QwenTensorParallelModel
    private let configuration: Data
    private let host: CBv2StageKVHost
    private let group: any QwenTensorParallelReduction
    private let prepare: (Reservation, () throws -> Void) throws -> QwenTensorParallelBatchInputs?
    private let completedDecode: (Int) -> Void
    private let completedPrefill: () -> Void
    private let releaseResources: (Reservation) throws -> Void
    private let prefix: QwenTensorParallelBatchPrefixCache?
    private let prefixBudget: QwenTensorParallelBatchPrefixBudget?
    /// A request's resident and SSD scopes; nil for a request whose cache is
    /// off, which then votes nothing, captures nothing and stores nothing.
    private let prefixScope: ((Reservation) -> String?)?
    private let prefixDisk: QwenTensorParallelPrefixDisk?
    private let prefixDiskScope: ((Reservation) -> String?)?
    private let allocationBound: ((Int) throws -> Int)?
    private let prefixObserved: (String, Int, Int) -> Void
    private let assistant: QwenTensorParallelBatchAssistant?
    private let openedLane: (UUID, String) -> Void
    private let completedSpeculation: (UUID, Int, QwenMTPStatistics) -> Void
    private let profiledRound: (QwenTensorParallelMTPRoundProfile) -> Void
    private var incompleteOpenings: [UUID: Lane] = [:]
    /// Cohort synchronization (`cohortFrontiers`). Off only to measure or
    /// test the earlier empty-queue-only cohort; both ranks must agree.
    private let cohortJoinsAhead: Bool
    /// A cohort's proposals through one head call per draft step
    /// (`QwenTensorParallelMTPDecoder.stepBatch`); off only to compare.
    private let cohortBatchesDrafts: Bool

    init(model: QwenTensorParallelModel, configuration: Data, host: CBv2StageKVHost,
         group: any QwenTensorParallelReduction,
         prepare: @escaping (Reservation, () throws -> Void) throws -> QwenTensorParallelBatchInputs?,
         completedDecode: @escaping (Int) -> Void, completedPrefill: @escaping () -> Void,
         releaseResources: @escaping (Reservation) throws -> Void,
         prefix: QwenTensorParallelBatchPrefixCache? = nil,
         prefixBudget: QwenTensorParallelBatchPrefixBudget? = nil,
         prefixScope: ((Reservation) -> String?)? = nil,
         prefixDisk: QwenTensorParallelPrefixDisk? = nil,
         prefixDiskScope: ((Reservation) -> String?)? = nil,
         allocationBound: ((Int) throws -> Int)? = nil,
         prefixObserved: @escaping (String, Int, Int) -> Void = { _, _, _ in },
         assistant: QwenTensorParallelBatchAssistant? = nil,
         openedLane: @escaping (UUID, String) -> Void = { _, _ in },
         completedSpeculation: @escaping (UUID, Int, QwenMTPStatistics) -> Void = { _, _, _ in },
         profiledRound: @escaping (QwenTensorParallelMTPRoundProfile) -> Void = { _ in },
         cohortJoinsAhead: Bool = true, cohortBatchesDrafts: Bool = true) throws {
        guard case .shard(let rank, let size) = model.role, size == 2, rank == group.rank, size == group.size,
              sha256(configuration) == model.configurationSHA256,
              model.plan.vocabularySize < (1 << 24),
              prefix == nil || (prefixBudget != nil && prefixScope != nil && allocationBound != nil),
              prefixDisk == nil || (prefixDiskScope != nil && prefixScope != nil) else {
            throw ProbeError("Qwen TP native batch executor has a mismatched shard or group")
        }
        if let assistant {
            guard host.kind == .paged, (1...4).contains(assistant.depth),
                  assistant.head.projection.vocabulary == model.vocabularyRange,
                  assistant.head.projection.reduction.rank == rank,
                  assistant.prefix == nil || prefixScope != nil else {
                throw ProbeError("Qwen TP resident assistant differs from its paged batch owner")
            }
            if let cohort = assistant.cohortBudget {
                guard cohort.maximumSpeculativeWidth == host.lanes, cohort.target.lanes == host.lanes,
                      cohort.depth == assistant.depth,
                      cohort.allowance.maximumContextTokens == host.maximumTokensPerRequest,
                      cohort.maximumSpeculativeWidth > 1, cohort.retainedCohortBytesPerLane > 0,
                      cohort.cohortTransientBytes > 0 else {
                    throw ProbeError("Qwen TP multirow assistant lacks a complete target-cohort quote")
                }
            }
        }
        self.assistant = assistant; self.openedLane = openedLane; self.completedSpeculation = completedSpeculation
        self.profiledRound = profiledRound; self.cohortJoinsAhead = cohortJoinsAhead
        self.cohortBatchesDrafts = cohortBatchesDrafts
        self.rank = rank; self.model = model; self.configuration = configuration; self.host = host
        self.prefix = prefix; self.prefixBudget = prefixBudget; self.prefixScope = prefixScope
        self.prefixDisk = prefixDisk; self.prefixDiskScope = prefixDiskScope
        self.allocationBound = allocationBound; self.prefixObserved = prefixObserved
        self.group = group; self.prepare = prepare; self.completedDecode = completedDecode; self.completedPrefill = completedPrefill; self.releaseResources = releaseResources
    }

    func exchange(_ words: [Float], check: () throws -> Void) throws -> [Float] {
        try check()
        let result = group.allSum(MLXArray(words)); eval(result); try check()
        guard result.shape == [words.count], result.dtype == .float32 else {
            throw ProbeError("Qwen TP batch control reduction changed shape or dtype")
        }
        let output = result.asArray(Float.self); try check()
        guard output.allSatisfy(\.isFinite) else { throw ProbeError("Qwen TP batch control reduction is not finite") }
        return output
    }

    func discard(_ reservation: Reservation) throws {
        if let lane = incompleteOpenings[reservation.request.requestID] {
            try retire(lane, reason: nil, selected: 0, last: nil)
            guard lane.isClosed else { throw ProbeError("Qwen TP failed assistant opening retained its target") }
            incompleteOpenings[reservation.request.requestID] = nil
        } else { try releaseResources(reservation) }
    }

    func open(_ reservation: Reservation, check: () throws -> Void) throws -> Lane {
        let inputs = try prepare(reservation, check)
        try check()
        var request = reservation.request
        let admittedAssistant = request.qwenMedia == nil && (request.sampler?.admitsSpeculativeVerification ?? true) ? assistant : nil
        var restored: QwenTensorParallelBatchPrefixState?
        var restoredAssistant: QwenTensorParallelMTPPrefixState?
        var captureFrontier = 0, captureKey: String?, diskScope: String?
        if let assistant = admittedAssistant, let prefix = assistant.prefix, prefix.enabled,
           let scope = prefixScope?(reservation) {
            let candidates = QwenTensorParallelMTPPrefixCache.candidates(promptCount: request.promptCount,
                chunkSize: request.chunkSize, maximumTokens: assistant.prefixBudget.maximumTokens).filter { $0 > 1 }
            let keys = QwenTensorParallelMTPPrefixCache.keys(scope: scope + "|assistant-prefix", tokens: request.promptTokenIDs, frontiers: candidates)
            diskScope = prefixDisk == nil ? nil : (prefixDiskScope?(reservation)).map { $0 + "|assistant-prefix" }
            if !candidates.isEmpty {
                let prompt = request.promptTokenIDs
                let agreed = try agreePrefix(cache: prefix, candidates: candidates, keys: keys, diskScope: diskScope,
                    prompt: prompt, check: check, read: { [request] stage in
                        let state = try QwenTensorParallelMTPPrefixState(stage: stage, assistant: assistant.head.assistant,
                            prompt: prompt, allocationBound: assistant.allocationBound)
                        return try self.adopts(state.target, request: request) ? state : nil
                    })
                if let state = agreed.state {
                    restoredAssistant = state; restored = state.target
                    request = try request.planned(reusedPrefix: agreed.frontier, splitFinalToken: false)
                }
                if let last = candidates.last, last > agreed.frontier { captureFrontier = last; captureKey = keys[last] }
            }
        } else if admittedAssistant == nil, let prefix, prefix.enabled, let budget = prefixBudget, let scope = prefixScope?(reservation),
                  let allocationBound {
            let candidates = QwenTensorParallelBatchPrefixCache.candidates(promptCount: request.promptCount,
                chunkSize: request.chunkSize, maximumTokens: budget.maximumTokens)
            let keys = QwenTensorParallelBatchPrefixCache.keys(scope: scope,
                tokens: request.promptTokenIDs, frontiers: candidates)
            diskScope = prefixDisk == nil ? nil : prefixDiskScope?(reservation)
            if !candidates.isEmpty {
                let agreed = try agreePrefix(cache: prefix, candidates: candidates, keys: keys, diskScope: diskScope,
                    prompt: request.promptTokenIDs, check: check, read: { [request] stage in
                        let state = try QwenTensorParallelBatchPrefixState(stage: stage, allocationBound: allocationBound)
                        return try self.adopts(state, request: request) ? state : nil
                    })
                if let state = agreed.state {
                    restored = state
                    request = try request.planned(reusedPrefix: agreed.frontier, splitFinalToken: false)
                }
                if let last = candidates.last, last > agreed.frontier {
                    captureFrontier = last; captureKey = keys[last]
                }
            }
        }
        let lane = try Lane(.init(model: model, configuration: configuration, host: host,
            request: request, inputs: inputs, restored: restored, captureFrontier: admittedAssistant == nil ? captureFrontier : 0,
            captureLimitBytes: prefixBudget?.captureBytes ?? 0, allocationBound: allocationBound),
            releaseResources: { [releaseResources] in try releaseResources(reservation) })
        // Keep custody before assistant checkpoint restoration can allocate.
        // If opening throws, the driver's existing discard path retires this
        // exact lane; a failed drain remains retained by the failed executor.
        incompleteOpenings[request.requestID] = lane
        if let assistant = admittedAssistant {
            lane.assistant = try .init(target: lane.session, head: assistant.head, group: group,
                depth: assistant.depth, restored: restoredAssistant, captureFrontier: captureFrontier,
                captureLimitBytes: assistant.prefixBudget.captureBytes, allocationBound: assistant.allocationBound)
        }
        lane.prefixKey = captureKey; lane.prefixDiskScope = captureKey == nil ? nil : diskScope
        incompleteOpenings[request.requestID] = nil
        prefixObserved(admittedAssistant == nil ? "opened" : "opened-assistant", request.reusedPrefixTokens,
            admittedAssistant?.prefix?.bytesInUse ?? prefix?.bytesInUse ?? 0)
        if assistant != nil {
            let route = admittedAssistant != nil ? "assistant" : request.qwenMedia != nil ? "ordinary_media" : "ordinary_sampler"
            openedLane(request.requestID, route)
        }
        return lane
    }

    /// One request's prefix plan on this rank. Each rank offers the candidate
    /// frontiers it holds in its resident tier or as a complete record on its
    /// SSD tier; both take the deepest frontier both offer and restore it from
    /// their own tiers (resident first). A second exchange confirms that both
    /// restored it; otherwise both prefill from zero. A state read from the
    /// SSD is charged to the resident tier at once, as a stored capture is
    /// (one that does not fit is not restored), and stays there even when its
    /// peer could not restore, so the next offer finds it in memory.
    private func agreePrefix<Snapshot: QwenTensorParallelPrefixSnapshot>(
        cache: QwenTensorParallelSnapshotCache<Snapshot>, candidates: [Int], keys: [Int: String], diskScope: String?,
        prompt: [Int], check: () throws -> Void, read: (QwenStagePrefixState) throws -> Snapshot?
    ) throws -> (frontier: Int, state: Snapshot?) {
        let disk = diskScope == nil ? nil : prefixDisk
        let onDisk = diskScope.flatMap { scope in
            disk?.frontiers(scope: scope, tokens: prompt, maximumFrontier: candidates.last ?? 0)
        } ?? []
        let offers = zip(candidates, cache.held(keys: keys, candidates: candidates)).map { frontier, held in
            held == 1 || onDisk.contains(frontier) ? Float(1) : 0
        }
        let frontier = try QwenTensorParallelSnapshotCache<Snapshot>.agreed(candidates: candidates,
            votes: try exchange(offers, check: check))
        guard frontier > 0, let key = keys[frontier] else { return (0, nil) }
        var state: Snapshot?, tier = "resident"
        if cache.holds(key: key, frontier: frontier) {
            state = try cache.restore(key: key, frontier: frontier)
            if let disk, let diskScope { disk.tier.touch(scope: diskScope, tokens: prompt, frontier: frontier) }
        } else if let disk, let diskScope {
            tier = "ssd"
            if let stage = try disk.tier.restore(scope: diskScope, tokens: prompt, frontier: frontier, check: check) {
                var adopted: Snapshot?
                do { adopted = try read(stage) } catch {
                    log("darkbloom-prefix-ssd-v1 rank=\(rank) event=restore-rejected frontier=\(frontier) error=\(qwenPrefixLogWord(error))")
                }
                if let adopted, cache.insert(key: key, state: adopted) { state = adopted } else {
                    log("darkbloom-prefix-ssd-v1 rank=\(rank) event=restore-rejected frontier=\(frontier)"
                        + " reason=\(adopted == nil ? "not_adoptable" : "over_resident_budget")")
                    disk.tier.forget(scope: diskScope, tokens: prompt, frontier: frontier)
                }
            }
            try check()
        }
        let confirmed = try exchange([state == nil ? 0 : 1], check: check)
        guard confirmed == [2] else {
            if disk != nil {
                log("darkbloom-prefix-ssd-v1 rank=\(rank) event=restore-declined frontier=\(frontier) tier=\(tier)"
                    + " local=\(state == nil ? 0 : 1) kept=\(state != nil && tier == "ssd" ? 1 : 0)")
            }
            return (0, nil)
        }
        if tier == "ssd" {
            log("darkbloom-prefix-ssd-v1 rank=\(rank) event=restore-confirmed frontier=\(frontier) prompt=\(prompt.count)")
        }
        return (frontier, state)
    }

    /// Whether a shard read from the SSD adopts into this request's state:
    /// every layer present with this rank's shapes and dtypes (the checks of
    /// the adoption itself, before any page is written), so a record that
    /// cannot be adopted makes both ranks prefill from zero, never fail.
    private func adopts(_ state: QwenTensorParallelBatchPrefixState, request: QwenLayerStageGenerationRequest) throws -> Bool {
        let geometry = try QwenTensorParallelBatchSession.geometry(model: model, configuration: configuration,
            host: host, maximumTokens: request.maximumTokens)
        return state.adopts(into: geometry)
    }

    func prefill(_ lane: Lane, frame: QwenLayerStageFrame, check: () throws -> Void) throws -> Int? {
        guard lane.nextFrame == frame else { throw ProbeError("Qwen TP native prefill frame changed") }
        let output: MLXArray?
        if let decoder = lane.assistant { output = try decoder.prefill(check: check) }
        else { output = try lane.session.prefill(check: check) }
        completedPrefill()
        guard let logits = output else { return nil }
        let token = try select(logits, lanes: [lane], check: check)[0]
        try lane.assistant?.begin(firstToken: token)
        lane.selectedCount = 1
        return token
    }

    func decode(_ lanes: [Lane], tokens: [Int], check: () throws -> Void) throws -> [Int] {
        try GPU.withCommandBufferLimits(QwenTensorParallelBatchSession.decodeCommandBuffers) {
            try decodeRound(lanes, tokens: tokens, check: check)
        }
    }

    /// One decode step's speculative cohort, the same on both ranks (every
    /// input is agreed lane state), as each row's round input and allowance.
    /// Rows with an empty accepted queue that can speculate on the driver's
    /// input start a round. When one does, every row that still holds at most
    /// `depth` queued selections and can speculate from its own settled carry
    /// joins it. Without that, rows whose rounds started a step apart verify
    /// alternately, one row per round, for as long as both run (measured on
    /// the installed pair: 1,677 of 1,863 capacity-2 rounds verified one row).
    /// A joined row's round is the one it would run once its queue drained:
    /// same input, same allowance, same per-row arithmetic.
    private func cohortFrontiers(_ lanes: [Lane], tokens: [Int], depth: Int) -> [Int: (lastToken: Int, remaining: Int)] {
        var frontiers: [Int: (lastToken: Int, remaining: Int)] = [:]
        for index in lanes.indices where lanes[index].accepted.isEmpty {
            let lane = lanes[index], remaining = lane.session.request.outputCount - lane.selectedCount
            if lane.assistant?.canSpeculate(lastToken: tokens[index], remaining: remaining) == true {
                frontiers[index] = (tokens[index], remaining)
            }
        }
        guard cohortJoinsAhead, !frontiers.isEmpty else { return frontiers }
        for index in lanes.indices where !lanes[index].accepted.isEmpty && lanes[index].accepted.count <= depth {
            if let frontier = lanes[index].assistant?.settledFrontier() { frontiers[index] = frontier }
        }
        return frontiers
    }

    private func decodeRound(_ lanes: [Lane], tokens: [Int], check: () throws -> Void) throws -> [Int] {
        guard !lanes.isEmpty, lanes.count == tokens.count, lanes.count <= host.lanes,
              Set(lanes.map { ObjectIdentifier($0) }).count == lanes.count else {
            throw ProbeError("Qwen TP accepted selections require distinct scheduled lanes")
        }
        if let context = assistant, let quote = context.cohortBudget {
            let frontiers = cohortFrontiers(lanes, tokens: tokens, depth: context.depth)
            let eligible = frontiers.keys.sorted()
            guard eligible.count <= quote.maximumSpeculativeWidth else {
                throw ProbeError("Qwen TP speculative cohort exceeds its complete memory quote")
            }
            if eligible.count > 1 {
                let decoders = eligible.map { lanes[$0].assistant! }
                let results = try QwenTensorParallelMTPDecoder.stepBatch(decoders,
                    lastTokens: eligible.map { frontiers[$0]!.lastToken },
                    remaining: eligible.map { frontiers[$0]!.remaining }, batchesDrafts: cohortBatchesDrafts, check: check)
                for (row, index) in eligible.enumerated() {
                    try lanes[index].accepted.append(input: frontiers[index]!.lastToken, tokens: results[row].tokens,
                        logprobs: results[row].logprobs, depth: context.depth, vocabulary: model.plan.vocabularySize)
                }
                // Observe only the completed target cohort after every row's
                // accepted queue is owned; configured capacity is not work.
                for (row, index) in eligible.enumerated() {
                    completedSpeculation(lanes[index].session.request.requestID, eligible.count, decoders[row].statistics)
                }
                if let profile = decoders.first?.lastProfile { profiledRound(profile) }
                completedDecode(eligible.count)
            } else if let index = eligible.first, let decoder = lanes[index].assistant, let frontier = frontiers[index] {
                let result = try decoder.step(lastToken: frontier.lastToken, remaining: frontier.remaining, check: check)
                guard result.speculative else { throw ProbeError("Qwen TP eligible cohort row lost its speculative round") }
                try lanes[index].accepted.append(input: frontier.lastToken, tokens: result.tokens,
                    logprobs: result.logprobs, depth: context.depth, vocabulary: model.plan.vocabularySize)
                completedDecode(1); completedSpeculation(lanes[index].session.request.requestID, 1, decoder.statistics)
                if let profile = decoder.lastProfile { profiledRound(profile) }
            }
        }
        // Without a complete cohort quote, preserve singleton-ready-set
        // speculation and ordinary wider target batching. The resident head
        // does not itself authorize a multirow verification workspace.
        if lanes.count == 1, let context = assistant, let decoder = lanes[0].assistant,
           lanes[0].accepted.isEmpty,
           decoder.canSpeculate(lastToken: tokens[0], remaining: lanes[0].session.request.outputCount - lanes[0].selectedCount) {
            let result = try decoder.step(lastToken: tokens[0],
                remaining: lanes[0].session.request.outputCount - lanes[0].selectedCount, check: check)
            guard result.speculative else { throw ProbeError("Qwen TP singleton assistant did not execute its agreed round") }
            try lanes[0].accepted.append(input: tokens[0], tokens: result.tokens, logprobs: result.logprobs,
                depth: context.depth, vocabulary: model.plan.vocabularySize)
            completedDecode(1); completedSpeculation(lanes[0].session.request.requestID, 1, decoder.statistics)
            if let profile = decoder.lastProfile { profiledRound(profile) }
        }
        let ordinary = lanes.indices.filter { lanes[$0].accepted.isEmpty }
        var selections = [Int?](repeating: nil, count: lanes.count)
        if !ordinary.isEmpty {
            let active = ordinary.map { lanes[$0] }, inputs = ordinary.map { tokens[$0] }
            let observing = active.contains { $0.assistant != nil }
            let result: (logits: MLXArray, hidden: MLXArray?)
            if observing {
                let value = try QwenTensorParallelBatchSession.decodeWithHidden(active.map(\.session), tokens: inputs, check: check)
                result = (value.logits, value.hidden)
            } else {
                result = (try QwenTensorParallelBatchSession.decode(active.map(\.session), tokens: inputs, check: check), nil)
            }
            completedDecode(active.count)
            let selected = try select(result.logits, lanes: active, check: check)
            for (row, index) in ordinary.enumerated() {
                if let decoder = active[row].assistant, let hidden = result.hidden {
                    try decoder.observeOrdinary(inputToken: inputs[row], hidden: hidden[row..<row + 1],
                        selectedToken: selected[row], check: check)
                }
                selections[index] = selected[row]
            }
        }
        for index in lanes.indices {
            let lane = lanes[index]
            if selections[index] == nil {
                let value = try lane.accepted.take(input: tokens[index])
                selections[index] = value.token; lane.pendingLogprobs = value.logprobs
            }
            lane.selectedCount += 1
        }
        return selections.map { $0! }
    }

    private func select(_ logits: MLXArray, lanes: [Lane], check: () throws -> Void) throws -> [Int] {
        let width = lanes.count
        guard (1...host.lanes).contains(width), logits.shape == [width, model.vocabularyRange.count],
              lanes.allSatisfy({ !$0.isClosed && $0.session.model === model }) else {
            throw ProbeError("Qwen TP selection rows do not match native lanes")
        }
        let values = logits.asType(.float32)
        let selected: MLXArray
        let sampled = lanes.contains { $0.session.request.sampling != nil }
        if sampled {
            // Sampling/logprobs require complete raw rows. Each rank writes
            // only its vocabulary interval and zero elsewhere; x+0 is exact.
            var pieces: [MLXArray] = []
            let before = model.vocabularyRange.lowerBound, after = model.plan.vocabularySize - model.vocabularyRange.upperBound
            if before > 0 { pieces.append(MLXArray.zeros([width, before], dtype: .float32)) }
            pieces.append(values)
            if after > 0 { pieces.append(MLXArray.zeros([width, after], dtype: .float32)) }
            let full = group.allSum(pieces.count == 1 ? values : concatenated(pieces, axis: 1))
            eval(full); try check()
            guard full.shape == [width, model.plan.vocabularySize], all(isFinite(full)).item(Bool.self) else {
                throw ProbeError("Qwen TP gathered sampling rows are invalid")
            }
            var choices = MLXArray.zeros([width], dtype: .float32)
            if rank == 0 {
                let rows = lanes.enumerated().map { index, lane in
                    let row = full[index..<index + 1]
                    return (lane.session.request.sampler?.sample(row) ?? argMax(row, axis: -1))
                        .asType(.float32).reshaped([1])
                }
                choices = concatenated(rows, axis: 0)
            }
            selected = group.allSum(choices).asType(.int32)
        } else {
            // Greedy rows retain the scalar TP tie rule: lower rank wins an
            // equal maximum, hence lower global vocabulary index wins.
            let local = stacked([values.max(axis: -1),
                argMax(values, axis: -1).asType(.float32) + Float(model.vocabularyRange.lowerBound)], axis: 1)
            let empty = MLXArray.zeros([width, 2], dtype: .float32)
            let both = group.allSum(concatenated(rank == 0 ? [local, empty] : [empty, local], axis: 1))
            selected = which(both[0..., 2] .> both[0..., 0], both[0..., 3], both[0..., 1]).asType(.int32)
        }
        eval(selected); try check()
        let tokens = selected.asArray(Int32.self).map(Int.init); try check()
        guard tokens.count == width, tokens.allSatisfy({ (0..<model.plan.vocabularySize).contains($0) }) else {
            throw ProbeError("Qwen TP selection produced an invalid token")
        }
        // No request history advances until every row and the collective
        // succeeded. Penalties and random streams remain request-local.
        if rank == 0 {
            for (lane, token) in zip(lanes, tokens) {
                if let sampler = lane.session.request.sampler {
                    lane.pendingLogprobs = sampler.takePendingLogprobs(); sampler.commit(token)
                }
            }
        }
        return tokens
    }

    func takeLogprobs(_ lane: Lane) throws -> ClusterWorkerTokenLogprobs? {
        guard rank == 0 else { throw ProbeError("Only Qwen TP rank0 publishes token logprobs") }
        defer { lane.pendingLogprobs = nil }
        return lane.pendingLogprobs
    }

    func confirmedRetirement(_ lane: Lane, clean: Bool) throws {
        guard lane.isClosed else { throw ProbeError("Qwen TP prefix publication precedes resource retirement") }
        if let decoder = lane.assistant {
            if clean, let context = assistant, let prefix = context.prefix, let key = lane.prefixKey,
               let captured = try decoder.takeCapturedPrefix(), prefix.insert(key: key, state: captured) {
                lane.storedPrefixFrontiers = [captured.committedTokens]
                prefixObserved("stored-assistant", captured.committedTokens, prefix.bytesInUse)
                persist(captured.stageState(assistant: context.head.assistant), lane: lane)
            } else { decoder.discardCapturedPrefix() }
        } else if clean, let prefix, let key = lane.prefixKey, let captured = try lane.session.takeCapturedPrefix() {
            if prefix.insert(key: key, state: captured) {
                lane.storedPrefixFrontiers = [captured.committedTokens]
                prefixObserved("stored", captured.committedTokens, prefix.bytesInUse)
                persist(captured.stageState, lane: lane)
            }
        } else { lane.session.discardCapturedPrefix() }
        lane.prefixKey = nil; lane.prefixDiskScope = nil
    }

    /// A stored capture is written behind serving to this rank's SSD tier
    /// (only what the resident tier holds, so a restore fits it again).
    private func persist(_ state: QwenStagePrefixState?, lane: Lane) {
        guard let disk = prefixDisk, let scope = lane.prefixDiskScope else { return }
        guard let state else {
            log("darkbloom-prefix-ssd-v1 rank=\(rank) event=persist-dropped reason=unencodable prompt=\(lane.session.request.promptCount)")
            return
        }
        disk.tier.persist(scope: scope, tokens: lane.session.request.promptTokenIDs, states: [state],
            blockTokens: lane.session.request.chunkSize)
    }

    func retire(_ lane: Lane, reason: QwenLayerStageGenerationFinishReason?, selected: Int, last: Int?) throws {
        if let reason {
            guard let last else { throw ProbeError("Qwen TP clean retirement has no selected token") }
            var schedule = lane.session.schedule
            try schedule.finish(reason, selectedTokenCount: selected, lastTokenID: last,
                discardedDecodeForwards: lane.accepted.count)
        }
        if reason == nil {
            lane.session.discardCapturedPrefix(); lane.prefixKey = nil; lane.prefixDiskScope = nil; lane.storedPrefixFrontiers = []
        }
        if let decoder = lane.assistant { try decoder.retire() }
        else { try lane.session.retire() }
        try lane.releaseAfterNativeDrain()
        lane.pendingLogprobs = nil; lane.accepted.removeAll()
    }
}
