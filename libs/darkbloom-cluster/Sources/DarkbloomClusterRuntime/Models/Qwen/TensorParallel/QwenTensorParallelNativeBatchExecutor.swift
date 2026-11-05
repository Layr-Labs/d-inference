import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLMCommon

final class QwenTensorParallelNativeBatchLane: QwenTensorParallelBatchLane {
    let session: QwenTensorParallelBatchSession
    var pendingLogprobs: ClusterWorkerTokenLogprobs?
    var assistant: QwenTensorParallelMTPDecoder?
    var accepted = QwenTensorParallelAcceptedSelections()
    var selectedCount = 0
    var canSelectNext: Bool { !accepted.isEmpty || nextFrame?.phase == .decode }
    var plainSelection: Bool { assistant == nil }
    /// The keys of the boundaries this request captures, by boundary.
    var prefixKeys: [Int: String] = [:]
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
    /// An assisted lane's prompt keeps one frame a step (its history takes each frame's hidden rows).
    func promptStep(frames: Int) -> QwenLayerStageFrame? {
        QwenTensorParallelPromptWavefront.step(session.promptFrames(limit: assistant == nil ? frames : 1))
    }
    func promptStep(tokens: Int) -> QwenLayerStageFrame? {
        let frames = session.promptFrames(limit: assistant == nil ? QwenTensorParallelPromptWavefront.maximumFrames : 1)
        return (1...max(1, frames.count)).lazy.compactMap { QwenTensorParallelPromptWavefront.step(Array(frames.prefix($0))) }
            .first { $0.tokenCount == tokens }
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
    /// Submits plain decode rectangles without reading them (`submitDecode`),
    /// for the driver's build-ahead (overlapping only on a paged host, whose
    /// frontiers the host holds). Off by default:
    /// the product turns it on with `QwenTensorParallelBatchSettings.buildsAhead`.
    let buildsAhead: Bool
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
         cohortJoinsAhead: Bool = true, cohortBatchesDrafts: Bool = true, buildsAhead: Bool = false) throws {
        self.buildsAhead = buildsAhead
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
                // LOAD quoted the memory plan's request; a longer one, up to
                // the host's bound, was charged at its own context.
                guard cohort.maximumSpeculativeWidth == host.lanes, cohort.target.lanes == host.lanes,
                      cohort.depth == assistant.depth,
                      cohort.allowance.maximumContextTokens <= host.maximumTokensPerRequest,
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
        QwenTensorParallelBatchSession.logCensusOnce(rank: rank, model: model)
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
        var captureFrontier = 0, captureKeys: [Int: String] = [:], diskScope: String?
        var capture: QwenTensorParallelPrefixCapture?
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
                if let last = candidates.last, last > agreed.frontier, let key = keys[last] {
                    captureFrontier = last; captureKeys = [last: key]
                }
            }
        } else if admittedAssistant == nil, let prefix, prefix.enabled, let budget = prefixBudget, let scope = prefixScope?(reservation),
                  let allocationBound {
            // To the request's own context, as its reservation charged its capture; LOAD's memory plan is shorter.
            let candidates = QwenTensorParallelBatchPrefixCache.candidates(promptCount: request.promptCount,
                chunkSize: request.chunkSize, maximumTokens: request.maximumTokens)
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
            }
            // The boundaries this request keeps after what it restored, within its own charged capture.
            let frontiers = QwenTensorParallelBatchPrefixBudget.frontiers(promptCount: request.promptCount,
                chunkSize: request.chunkSize, restored: request.reusedPrefixTokens, maximumTokens: request.maximumTokens)
            if !frontiers.isEmpty {
                captureKeys = QwenTensorParallelBatchPrefixCache.keys(scope: scope, tokens: request.promptTokenIDs, frontiers: frontiers)
                capture = .init(frontiers: frontiers, limitBytes: try budget.captureBytes(promptCount: request.promptCount,
                    chunkSize: request.chunkSize, allocationBound: allocationBound), allocationBound: allocationBound)
            }
        }
        let lane = try Lane(.init(model: model, configuration: configuration, host: host,
            request: request, inputs: inputs, restored: restored, capture: admittedAssistant == nil ? capture : nil),
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
        lane.prefixKeys = captureKeys; lane.prefixDiskScope = captureKeys.isEmpty ? nil : diskScope
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
    /// SSD becomes resident when the tier's budget holds it, and stays there
    /// even when its peer could not restore, so the next offer finds it in
    /// memory; one the tier cannot hold is restored once, within the
    /// request's own charged capture (no deeper than the boundaries it keeps).
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
                if let adopted {
                    state = adopted
                    if !cache.insert(key: key, state: adopted) {
                        log("darkbloom-prefix-ssd-v1 rank=\(rank) event=restore-unkept frontier=\(frontier) reason=over_resident_budget")
                    }
                } else {
                    log("darkbloom-prefix-ssd-v1 rank=\(rank) event=restore-rejected frontier=\(frontier) reason=not_adoptable")
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
        guard lane.promptStep(tokens: frame.tokenCount) == frame else { throw ProbeError("Qwen TP native prefill frame changed") }
        let output: MLXArray?
        if let decoder = lane.assistant { output = try decoder.prefill(check: check) }
        else { output = try lane.session.prefill(step: frame, check: check) }
        completedPrefill()
        guard let logits = output else { return nil }
        let token = try select(logits, lanes: [lane], control: nil, check: check).tokens[0]
        try lane.assistant?.begin(firstToken: token)
        lane.selectedCount = 1
        return token
    }

    var carriesSelectionControl: Bool { true }

    func decode(_ lanes: [Lane], tokens: [Int], check: () throws -> Void) throws -> [Int] {
        try decode(lanes, tokens: tokens, control: { nil }, check: check).tokens
    }

    func decode(_ lanes: [Lane], tokens: [Int], control: () throws -> [Float]?,
                check: () throws -> Void) throws -> (tokens: [Int], control: [Float]?) {
        try GPU.withCommandBufferLimits(QwenTensorParallelBatchSession.decodeCommandBuffers) {
            try decodeRound(lanes, tokens: tokens, control: control, check: check)
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

    private func decodeRound(_ lanes: [Lane], tokens: [Int], control: () throws -> [Float]?,
                             check: () throws -> Void) throws -> (tokens: [Int], control: [Float]?) {
        guard !lanes.isEmpty, lanes.count == tokens.count, lanes.count <= host.lanes,
              Set(lanes.map { ObjectIdentifier($0) }).count == lanes.count else {
            throw ProbeError("Qwen TP accepted selections require distinct scheduled lanes")
        }
        var summedControl: [Float]?
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
            // Control words ride only a plain rectangle's own selection sum.
            let words = try control()
            guard words == nil || (ordinary.count == lanes.count && lanes.allSatisfy(\.plainSelection)) else {
                throw ProbeError("Qwen TP control words need a plain decode rectangle")
            }
            let selection = try select(result.logits, lanes: active, control: words, check: check)
            let selected = selection.tokens
            summedControl = selection.control
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
        return (selections.map { $0! }, summedControl)
    }

    /// `control`: this rank's words for the selection's own sealed sum (after
    /// greedy rows' words, or after sampled rows' choices); both ranks' sum
    /// of them returns. Exact limbs plus zeros leave the selection words' bits.
    private func select(_ logits: MLXArray, lanes: [Lane], control: [Float]?,
                        check: () throws -> Void) throws -> (tokens: [Int], control: [Float]?) {
        try readSelection(try buildSelection(logits, lanes: lanes, control: control, checksGatheredRows: true, check: check),
                          lanes: lanes, check: check)
    }

    /// One decode rectangle's selection as graph nodes: the tokens, the
    /// non-finite counts the read checks, the summed control words and, on
    /// rank 0, each sampled row's lazy logprob gather.
    struct Selection {
        let selected: MLXArray
        let nonfinite: MLXArray?
        /// Sampled rows: the gathered rows' non-finite count, when not checked at build.
        let gatheredNonfinite: MLXArray?
        let summedControl: MLXArray?
        let controlCount: Int?
        let logprobs: [CBv2StepLogprobs?]
        var roots: [MLXArray] { [selected] + [nonfinite, gatheredNonfinite, summedControl].compactMap { $0 } }
    }

    /// `checksGatheredRows`: sampled rows' gathered rows are evaluated and
    /// checked before the draw (the read-then-build order); a submitted step
    /// (build-ahead) defers that check to its read, which fails both ranks
    /// alike before any history advances.
    private func buildSelection(_ logits: MLXArray, lanes: [Lane], control: [Float]?, checksGatheredRows: Bool,
                                check: () throws -> Void) throws -> Selection {
        let width = lanes.count
        guard (1...host.lanes).contains(width), logits.shape == [width, model.vocabularyRange.count],
              lanes.allSatisfy({ !$0.isClosed && $0.session.model === model }) else {
            throw ProbeError("Qwen TP selection rows do not match native lanes")
        }
        let values = logits.asType(.float32)
        let selected: MLXArray
        var nonfinite: MLXArray?, gatheredNonfinite: MLXArray?, summedControl: MLXArray?
        var logprobs = [CBv2StepLogprobs?](repeating: nil, count: width)
        /// `own` words, then the control words, in one sealed sum.
        func sum(_ own: MLXArray) -> MLXArray {
            guard let control else { return group.allSum(own) }
            let count = own.size
            let summed = group.allSum(concatenated([own.reshaped([count]), MLXArray(control)], axis: 0))
            summedControl = summed[count ..< (count + control.count)]
            return summed[0 ..< count].reshaped(own.shape)
        }
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
            let gathered = (1 - isFinite(full).asType(.float32)).sum()
            guard full.shape == [width, model.plan.vocabularySize] else {
                throw ProbeError("Qwen TP gathered sampling rows are invalid")
            }
            if checksGatheredRows {
                eval(full, gathered); try check()
                guard gathered.item(Float.self) == 0 else { throw ProbeError("Qwen TP gathered sampling rows are invalid") }
            } else {
                gatheredNonfinite = gathered
            }
            var choices = MLXArray.zeros([width], dtype: .float32)
            if rank == 0 {
                let rows = lanes.enumerated().map { index, lane in
                    let row = full[index..<index + 1]
                    guard let sampler = lane.session.request.sampler else { return argMax(row, axis: -1).asType(.float32).reshaped([1]) }
                    let drawn = sampler.sample(row)
                    // Kept with this step: a step built ahead draws again before this one is read.
                    logprobs[index] = sampler.takePendingStepLogprobs()
                    return drawn.asType(.float32).reshaped([1])
                }
                choices = concatenated(rows, axis: 0)
            }
            selected = sum(choices).asType(.int32)
        } else {
            // Greedy rows retain the scalar TP tie rule: lower rank wins an
            // equal maximum, hence lower global vocabulary index wins. Each
            // rank's non-finite count rides the same sum, so a non-finite
            // logit on either rank fails both, read from this one evaluation.
            let local = stacked([values.max(axis: -1),
                argMax(values, axis: -1).asType(.float32) + Float(model.vocabularyRange.lowerBound),
                (1 - isFinite(values).asType(.float32)).sum(axis: -1)], axis: 1)
            let empty = MLXArray.zeros([width, 3], dtype: .float32)
            let both = sum(concatenated(rank == 0 ? [local, empty] : [empty, local], axis: 1))
            selected = which(both[0..., 3] .> both[0..., 0], both[0..., 4], both[0..., 1]).asType(.int32)
            nonfinite = both[0..., 2] + both[0..., 5]
        }
        return Selection(selected: selected, nonfinite: nonfinite, gatheredNonfinite: gatheredNonfinite,
                         summedControl: summedControl, controlCount: control?.count, logprobs: logprobs)
    }

    /// Reads a built selection: checks every row and the words, then (rank 0)
    /// advances each sampled request's history and keeps its token's logprobs.
    private func readSelection(_ selection: Selection, lanes: [Lane], check: () throws -> Void) throws -> (tokens: [Int], control: [Float]?) {
        let width = lanes.count
        eval(selection.roots); try check()
        guard selection.gatheredNonfinite.map({ $0.item(Float.self) == 0 }) ?? true else {
            throw ProbeError("Qwen TP gathered sampling rows are invalid")
        }
        guard selection.nonfinite?.asArray(Float.self).allSatisfy({ $0 == 0 }) ?? true else {
            throw ProbeError("Qwen TP selection rows have a non-finite logit")
        }
        let tokens = selection.selected.asArray(Int32.self).map(Int.init); try check()
        guard tokens.count == width, tokens.allSatisfy({ (0..<model.plan.vocabularySize).contains($0) }) else {
            throw ProbeError("Qwen TP selection produced an invalid token")
        }
        let words = selection.summedControl?.asArray(Float.self)
        guard words.map({ $0.count == selection.controlCount && $0.allSatisfy(\.isFinite) }) ?? (selection.controlCount == nil) else {
            throw ProbeError("Qwen TP folded control words changed length or are not finite")
        }
        // No request history advances until every row and the collective
        // succeeded. Penalties and random streams remain request-local.
        if rank == 0 {
            for (index, (lane, token)) in zip(lanes, tokens).enumerated() {
                if let sampler = lane.session.request.sampler {
                    lane.pendingLogprobs = selection.logprobs[index].map(QwenStageTokenSampler.tokenLogprobs); sampler.commit(token)
                }
            }
        }
        return (tokens, words)
    }

    // MARK: - Build-ahead (`QwenTensorParallelBatchDriver.serveAhead`)

    /// A submitted, unread decode rectangle.
    final class Submitted {
        let lanes: [Lane]
        let selection: Selection
        init(lanes: [Lane], selection: Selection) { self.lanes = lanes; self.selection = selection }
    }

    /// Submits a plain decode rectangle (no assistant, nothing accepted) on
    /// the host's tokens or the previous rectangle's unread selection: the
    /// forward (`QwenTensorParallelBatchSession.submitDecode`), then `control`
    /// once the forward committed, then the selection and its sum, all as
    /// graph nodes. Nothing is read; `readDecode` reads it.
    func submitDecode(_ lanes: [Lane], inputs: QwenBatchDecodeInputs<Submitted>, control: () throws -> [Float],
                      check: () throws -> Void) throws -> Submitted {
        guard buildsAhead, !lanes.isEmpty, lanes.count <= host.lanes,
              Set(lanes.map { ObjectIdentifier($0) }).count == lanes.count,
              lanes.allSatisfy({ $0.assistant == nil && $0.accepted.isEmpty && !$0.isClosed }) else {
            throw ProbeError("Qwen TP build-ahead needs distinct plain lanes on an executor that builds ahead")
        }
        let tokens: MLXArray
        switch inputs {
        case .tokens(let values):
            guard values.count == lanes.count, values.allSatisfy({ (0..<model.plan.vocabularySize).contains($0) }) else {
                throw ProbeError("Qwen TP submitted decode tokens differ from its lanes")
            }
            tokens = MLXArray(values.map(Int32.init))
        case .after(let previous, let rows):
            guard rows.count == lanes.count, rows.allSatisfy({ previous.lanes.indices.contains($0) }),
                  zip(rows, lanes).allSatisfy({ previous.lanes[$0.0] === $0.1 }) else {
                throw ProbeError("Qwen TP build-ahead rows differ from the previous step's lanes")
            }
            tokens = rows == Array(previous.lanes.indices)
                ? previous.selection.selected : take(previous.selection.selected, MLXArray(rows.map(Int32.init)))
        }
        return try GPU.withCommandBufferLimits(QwenTensorParallelBatchSession.decodeCommandBuffers) {
            let logits = try QwenTensorParallelBatchSession.submitDecode(lanes.map(\.session), tokens: tokens, check: check)
            completedDecode(lanes.count)
            let words = try control()
            let selection = try buildSelection(logits, lanes: lanes, control: words, checksGatheredRows: false, check: check)
            asyncEval(selection.roots)
            try check()
            for lane in lanes { lane.selectedCount += 1 }
            return Submitted(lanes: lanes, selection: selection)
        }
    }

    func readDecode(_ submitted: Submitted, check: () throws -> Void) throws -> (tokens: [Int], control: [Float]) {
        let result = try readSelection(submitted.selection, lanes: submitted.lanes, check: check)
        return (result.tokens, result.control ?? [])
    }

    func takeLogprobs(_ lane: Lane) throws -> ClusterWorkerTokenLogprobs? {
        guard rank == 0 else { throw ProbeError("Only Qwen TP rank0 publishes token logprobs") }
        defer { lane.pendingLogprobs = nil }
        return lane.pendingLogprobs
    }

    func confirmedRetirement(_ lane: Lane, clean: Bool) throws {
        guard lane.isClosed else { throw ProbeError("Qwen TP prefix publication precedes resource retirement") }
        if let decoder = lane.assistant {
            if clean, let context = assistant, let prefix = context.prefix, let key = lane.prefixKeys.values.first,
               let captured = try decoder.takeCapturedPrefix(), prefix.insert(key: key, state: captured) {
                lane.storedPrefixFrontiers = [captured.committedTokens]
                prefixObserved("stored-assistant", captured.committedTokens, prefix.bytesInUse)
                persist(captured.stageState(assistant: context.head.assistant).map { [$0] }, lane: lane)
            } else { decoder.discardCapturedPrefix() }
        } else if clean, let prefix, let captured = try lane.session.takeCapturedPrefix() {
            // The tier keeps what its budget holds; the SSD tier gets the
            // whole capture, which its request was charged for.
            let keyed = captured.states.compactMap { state in lane.prefixKeys[state.committedTokens].map { (key: $0, state: state) } }
            lane.storedPrefixFrontiers = prefix.insert(keyed, sharedBytes: captured.sharedBytes)
            prefixObserved("stored", lane.storedPrefixFrontiers.last ?? 0, prefix.bytesInUse)
            persist(captured.states.map(\.stageState), lane: lane)
        } else { lane.session.discardCapturedPrefix() }
        lane.prefixKeys = [:]; lane.prefixDiskScope = nil
    }

    /// A clean request's capture is written behind serving to this rank's
    /// SSD tier: the deepest boundary's rows and the recurrent state of each
    /// boundary on the tier's grid.
    private func persist(_ states: [QwenStagePrefixState]?, lane: Lane) {
        guard let disk = prefixDisk, let scope = lane.prefixDiskScope else { return }
        guard let states, !states.isEmpty else {
            log("darkbloom-prefix-ssd-v1 rank=\(rank) event=persist-dropped reason=unencodable prompt=\(lane.session.request.promptCount)")
            return
        }
        disk.tier.persist(scope: scope, tokens: lane.session.request.promptTokenIDs, states: states,
            blockTokens: lane.session.request.chunkSize)
    }

    func retire(_ lane: Lane, reason: QwenLayerStageGenerationFinishReason?, selected: Int, last: Int?) throws {
        if let reason {
            // A client stop may drop the selection made after the owner's last answer.
            guard let last, selected <= lane.selectedCount else {
                throw ProbeError("Qwen TP clean retirement has no selected token")
            }
            var schedule = lane.session.schedule
            try schedule.finish(reason, selectedTokenCount: selected, lastTokenID: last,
                discardedDecodeForwards: lane.accepted.count + lane.selectedCount - selected)
        }
        if reason == nil {
            lane.session.discardCapturedPrefix(); lane.prefixKeys = [:]; lane.prefixDiskScope = nil; lane.storedPrefixFrontiers = []
        }
        if let decoder = lane.assistant { try decoder.retire() }
        else { try lane.session.retire() }
        try lane.releaseAfterNativeDrain()
        lane.pendingLogprobs = nil; lane.accepted.removeAll()
    }
}
