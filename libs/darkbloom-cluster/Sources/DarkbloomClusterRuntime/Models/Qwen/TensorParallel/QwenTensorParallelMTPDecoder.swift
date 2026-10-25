import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// Wall-clock split of one speculative round on this rank, for the
/// `darkbloom-tp-mtp-profile-v1` diagnostic (never fields of the audited
/// round marker). Each phase ends at a host synchronization, so GPU work is
/// counted in the phase whose evaluation waited for it: with the single-row
/// draft chain pipelined (`QwenTensorParallelMTPDecoder.pipelinesDrafts`),
/// `draft` and `build` are host submission time and the drafts' GPU work
/// lands in `verify`.
struct QwenTensorParallelMTPRoundProfile: Equatable {
    var rows = 0
    /// Assistant proposals: draft steps, their evaluation and exchange.
    var draft: UInt64 = 0
    /// Target window graph construction.
    var build: UInt64 = 0
    /// Target window evaluation and its confirmation.
    var verify: UInt64 = 0
    /// Target logits gathered across the ranks.
    var gather: UInt64 = 0
    /// Rank 0's choices, their exchange and the acceptance decision.
    var choose: UInt64 = 0
    /// Rollback, assistant history, their evaluation and confirmation.
    var settle: UInt64 = 0

    var fields: String {
        "rows=\(rows) draft_us=\(draft / 1000) build_us=\(build / 1000) verify_us=\(verify / 1000)"
            + " gather_us=\(gather / 1000) choose_us=\(choose / 1000) settle_us=\(settle / 1000)"
    }

    /// Nanoseconds since the previous lap.
    struct Clock {
        private var last = DispatchTime.now().uptimeNanoseconds
        mutating func lap() -> UInt64 {
            let now = DispatchTime.now().uptimeNanoseconds
            defer { last = now }
            return now - last
        }
    }
}

/// One text request's assistant and target state. Both ranks execute each
/// announced round together; only rank0 samples and publishes. The enclosing
/// owner checks request cancellation at shared round boundaries, never halfway
/// through a collective, and retains admission until checked retirement.
final class QwenTensorParallelMTPDecoder {
    struct Emitted {
        let tokens: [Int]
        let logprobs: [ClusterWorkerTokenLogprobs]
        let speculative: Bool
    }
    private let target: any QwenTensorParallelMTPTarget
    private let head: QwenTensorParallelMTPHead
    private let group: any QwenTensorParallelReduction
    private let state: any CBv2MTPRequestState
    private let depth: Int
    private let stops: Set<Int>
    private let captureFrontier: Int
    private let captureLimitBytes: Int
    /// Leading complete history blocks move into head K/V during the prompt
    /// (`flushCompleteHistoryBlocks`); off only to compare against the
    /// whole-prompt first-draft flush.
    private let flushesHistoryDuringPrompt: Bool
    private let allocationBound: (Int) throws -> Int
    private var captured: QwenTensorParallelMTPPrefixState?
    private var promptFrontier: MLXArray?
    private var carry: (token: Int, hidden: MLXArray)?
    private var selectedCount = 0
    private(set) var retired = false
    private var failed = false
    private(set) var statistics: QwenMTPStatistics
    /// The last speculative round this request took part in.
    private(set) var lastProfile: QwenTensorParallelMTPRoundProfile?
    private var request: QwenLayerStageGenerationRequest { target.request }

    init(target: any QwenTensorParallelMTPTarget, head: QwenTensorParallelMTPHead,
         group: any QwenTensorParallelReduction, depth: Int,
         restored: QwenTensorParallelMTPPrefixState? = nil, captureFrontier: Int = 0,
         captureLimitBytes: Int = 0, allocationBound: ((Int) throws -> Int)? = nil,
         flushesHistoryDuringPrompt: Bool = true) throws {
        guard (1...4).contains(depth), head.assistant.maximumDraftTokens.map({ depth <= $0 }) == true,
              head.assistant.maximumSpeculativeBatch == 1,
              case .shard(let rank, let size) = target.model.role,
              rank == group.rank, size == group.size, size == 2,
              head.projection.vocabulary == target.model.vocabularyRange,
              head.projection.vocabularySize == target.model.plan.vocabularySize,
              target.request.qwenMedia == nil,
              target.request.reusedPrefixTokens == (restored?.committedTokens ?? 0),
              captureLimitBytes >= 0,
              captureFrontier == 0 || (allocationBound != nil && captureFrontier > max(1, target.request.reusedPrefixTokens)
                && captureFrontier < target.request.promptCount && captureFrontier % target.request.chunkSize == 0) else {
            throw ProbeError("Qwen TP MTP decoder differs from its request-owned dense target")
        }
        self.target = target; self.head = head; self.group = group; self.depth = depth
        stops = Set(target.request.stopTokenIDs)
        self.captureFrontier = captureFrontier; self.captureLimitBytes = captureLimitBytes
        self.flushesHistoryDuringPrompt = flushesHistoryDuringPrompt
        self.allocationBound = allocationBound ?? { _ in throw ProbeError("Unpriced TP assistant prefix capture") }
        if let restored {
            guard restored.assistant.targetInputCount == restored.committedTokens,
                  let value = try head.assistant.restorePagedPrefixCheckpoint(restored.assistant,
                    maximumSequenceLength: target.request.maximumTokens) else {
                throw ProbeError("Qwen TP assistant prefix belongs to another loaded head")
            }
            state = value
        } else {
            state = try head.assistant.makePagedRequestState(maximumSequenceLength: target.request.maximumTokens)
        }
        statistics = .init(depth: depth)
    }

    func prefill(check: () throws -> Void) throws -> MLXArray? {
        do {
            return try MLX.withError { error in
                func checked() throws { try error.check(); try check() }
                guard !retired, !failed, selectedCount == 0 else { throw ProbeError("Qwen TP MTP prompt is closed") }
                let start = target.state.committedTokens
                let output = try target.prefillForMTP(check: checked)
                let end = target.state.committedTokens
                let tokens = MLXArray(request.promptTokenIDs[start..<end].map(Int32.init)).reshaped([1, end - start])
                head.assistant.observeCommittedTarget(.init(tokens: tokens, hidden: output.hidden), requestState: state)
                promptFrontier = output.hidden[0..., (end - start - 1)..<(end - start), 0...]
                eval(head.assistant.evaluationTargets(for: state) + [promptFrontier!]); try checked()
                if end == captureFrontier {
                    guard captured == nil else { throw ProbeError("Qwen TP assistant prefix is already captured") }
                    captured = try .capture(target: target, assistant: head.assistant, requestState: state,
                        frontier: captureFrontier, limitBytes: captureLimitBytes,
                        allocationBound: allocationBound, check: checked)
                }
                // Past any prompt checkpoint, move the leading complete history
                // blocks the first round would flush first into head K/V now,
                // so a long prompt does not hold its whole trusted history.
                if flushesHistoryDuringPrompt, captureFrontier == 0 || end >= captureFrontier {
                    if head.assistant.flushCompleteHistoryBlocks(requestState: state) > 0 {
                        eval(head.assistant.evaluationTargets(for: state)); try checked()
                    }
                }
                return output.logits
            }
        } catch { failed = true; throw error }
    }

    /// The owner selects the ordinary final-prompt token before beginning.
    /// Its sampler must already have committed that token on rank0.
    func begin(firstToken: Int) throws {
        guard !retired, !failed, selectedCount == 0, target.state.committedTokens == request.promptCount,
              (0..<request.profile.vocabularySize).contains(firstToken), let promptFrontier,
              group.rank != 0 || request.sampler == nil || request.sampler?.nextOutputIndex == 1 else {
            throw ProbeError("Qwen TP MTP begins without a committed prompt selection")
        }
        carry = (firstToken, promptFrontier); self.promptFrontier = nil; selectedCount = 1
    }

    func step(lastToken: Int, remaining: Int, check: () throws -> Void) throws -> Emitted {
        do {
            return try MLX.withError { error in
                func checked() throws { try error.check(); try check() }
                guard !retired, !failed, selectedCount > 0, remaining > 0,
                      remaining == request.outputCount - selectedCount,
                      (0..<request.profile.vocabularySize).contains(lastToken) else {
                    throw ProbeError("Qwen TP MTP stepped outside its output allowance")
                }
                let speculative = carry?.token == lastToken && remaining >= depth
                    && (request.sampler?.admitsSpeculativeVerification ?? true)
                let count = speculative ? depth : 0
                let seed = MLXArray([Int32(lastToken)]).reshaped([1, 1])
                var feed = (tokens: seed, hidden: carry?.hidden)
                var drafted: [MLXArray] = []
                let started = DispatchTime.now().uptimeNanoseconds
                var clock = QwenTensorParallelMTPRoundProfile.Clock(), profile = QwenTensorParallelMTPRoundProfile(rows: 1)
                // Pipelined (`pipelinesDrafts`): each draft step is submitted
                // and the next built on its unevaluated output, and the window
                // is built on the unevaluated drafts, so the GPU runs the
                // chain and the window back to back while the host builds
                // ahead. The collectives keep their order (each rank submits
                // the same steps in the same order); only waits move.
                let pipelined = Self.pipelinesDrafts
                for _ in 0..<count {
                    let next = head.assistant.draftStep(tokens: feed.tokens, hidden: feed.hidden!, shortlist: nil,
                        requestState: state)
                    let roots = [next.tokens, next.hidden] + head.assistant.evaluationTargets(for: state)
                    if pipelined { asyncEval(roots) } else { eval(roots) }
                    try checked()
                    // Both ranks read the proposal from the same exchanged
                    // (maximum, index) pairs (`QwenTensorParallelMTPProjection`),
                    // so their argmax is the same token without a broadcast.
                    let token = next.tokens.reshaped([1, 1])
                    drafted.append(token); feed = (token, next.hidden)
                }
                let drafts = drafted.isEmpty ? nil : concatenated(drafted, axis: 1)
                let inputs = drafts.map { concatenated([seed, $0], axis: 1) } ?? seed
                profile.draft = clock.lap()
                let built = try QwenTensorParallelTargetWindow.$deferTokenRangeCheck.withValue(pipelined && speculative) {
                    try target.beginWindow(tokens: inputs, offset: target.state.committedTokens)
                }
                profile.build = clock.lap()
                eval(built.outputs + built.roots); try checked(); try target.confirmWindow(check: checked)
                profile.verify = clock.lap()
                let selected: MLXArray
                if request.sampling == nil {
                    // Greedy: both ranks derive the same choices from one exchange.
                    selected = try greedyChoices(built.outputs[0], count: count + 1, check: checked).reshaped([count + 1])
                    profile.gather = clock.lap()
                } else {
                    let full = try gathered(built.outputs[0], count: count + 1, check: checked)
                    profile.gather = clock.lap()
                    let choices: MLXArray
                    if group.rank == 0 {
                        if speculative { choices = request.sampler?.verifyRound(full) ?? argMax(full, axis: -1) }
                        else { choices = request.sampler?.sample(full[0..., 0, 0...]) ?? argMax(full[0..., 0, 0...], axis: -1) }
                    } else { choices = MLXArray.zeros([count + 1], dtype: .int32) }
                    selected = try broadcast(choices.reshaped([count + 1]), count: count + 1, check: checked)
                }
                let targetIDs = selected.asArray(Int32.self).map(Int.init)
                let draftIDs = drafts?.asArray(Int32.self).map(Int.init) ?? []
                let decision = try Self.accept(drafts: draftIDs, targets: targetIDs, remaining: remaining,
                    stopTokens: stops, vocabularySize: request.profile.vocabularySize)
                let emitted = decision.tokens.count
                let evaluated = DispatchTime.now().uptimeNanoseconds
                profile.choose = clock.lap()
                let roots = try target.settleWindow(keeping: emitted)
                if speculative {
                    let trustedDrafts = min(decision.accepted, emitted - 1)
                    head.assistant.finalizeRound(requestState: state, confirmedInputTokens: 1 + trustedDrafts,
                        committedDraftTokens: drafts![0..., 0..<trustedDrafts],
                        committedTargetHidden: built.outputs[1][0..., 0..<trustedDrafts, 0...])
                    // Restore the last actual committed target frontier after
                    // finalizeRound cleared the drafting frontier. This is an
                    // observation of the real target input/hidden, not a draft.
                    // If a wider ordinary batch runs next, its first input is
                    // paired with this frontier exactly once by the assistant.
                    head.assistant.observeCommittedTarget(.init(
                        tokens: inputs[0..., (emitted - 1)..<emitted],
                        hidden: built.outputs[1][0..., (emitted - 1)..<emitted, 0...]), requestState: state)
                } else {
                    head.assistant.observeCommittedTarget(.init(tokens: inputs,
                        hidden: built.outputs[1]), requestState: state)
                    head.assistant.flushTrustedHistory(requestState: state)
                }
                carry = (decision.tokens.last!, built.outputs[1][0..., (emitted - 1)..<emitted, 0...])
                eval(roots + head.assistant.evaluationTargets(for: state) + (carry.map { [$0.hidden] } ?? []))
                try checked(); try target.confirmSettled(check: checked)
                var logprobs: [ClusterWorkerTokenLogprobs] = []
                if group.rank == 0, let sampler = request.sampler {
                    if speculative {
                        logprobs = sampler.takeRoundLogprobs(tokens: decision.tokens)
                        sampler.commitRound(decision.tokens)
                    } else {
                        logprobs = sampler.takePendingLogprobs().map { [$0] } ?? []
                        sampler.commit(decision.tokens[0])
                    }
                }
                try checked(); selectedCount += emitted
                statistics.emittedTokens += emitted
                if speculative {
                    statistics.rounds += 1
                    for i in 0..<min(decision.accepted + 1, depth) { statistics.examinedByPosition[i] += 1 }
                    for i in 0..<decision.accepted { statistics.acceptedByPosition[i] += 1 }
                } else { statistics.plainSteps += 1 }
                statistics.evaluateNanoseconds += evaluated - started
                statistics.settleNanoseconds += DispatchTime.now().uptimeNanoseconds - evaluated
                profile.settle = clock.lap()
                lastProfile = speculative ? profile : nil
                return .init(tokens: decision.tokens, logprobs: logprobs, speculative: speculative)
            }
        } catch {
            failed = true
            // A pipelined round may leave submitted steps running: let them
            // (and their collectives, which every rank submitted in the same
            // order) finish before the caller retires this request.
            if Self.pipelinesDrafts { Stream.gpu.synchronize(); Stream.cpu.synchronize() }
            throw error
        }
    }

    /// Whether single-row rounds pipeline the assistant's draft chain into the
    /// verify window (on; diagnostic only:
    /// `DARKBLOOM_QWEN_TP_MTP_PIPELINED_DRAFT=0` waits for each draft step).
    static let pipelinesDraftsByEnvironment =
        ProcessInfo.processInfo.environment["DARKBLOOM_QWEN_TP_MTP_PIPELINED_DRAFT"] != "0"
    /// A test's own choice (nil: the environment's).
    @TaskLocal static var pipelinesDraftsOverride: Bool?
    static var pipelinesDrafts: Bool { pipelinesDraftsOverride ?? pipelinesDraftsByEnvironment }

    /// Draft each request through its existing B=1 assistant state, then
    /// verify the entire cohort in one captured target rectangle. This does
    /// not widen the assistant SDK's supported draft shape. Admission must
    /// quote the simultaneous target windows and their retained backings.
    /// With `batchesDrafts` (and an assistant that `splitsDrafts`), each row
    /// keeps its own B=1 history and graph, and one head call per draft step
    /// chooses every row's proposal.
    static func stepBatch(_ decoders: [QwenTensorParallelMTPDecoder], lastTokens: [Int],
                          remaining: [Int], batchesDrafts: Bool = true,
                          check: () throws -> Void) throws -> [Emitted] {
        do {
            return try MLX.withError { error in
                func checked() throws { try error.check(); try check() }
                guard let first = decoders.first, (2...8).contains(decoders.count),
                      lastTokens.count == decoders.count, remaining.count == decoders.count,
                      Set(decoders.map { ObjectIdentifier($0) }).count == decoders.count,
                      decoders.allSatisfy({ $0.head === first.head && $0.group === first.group
                        && $0.target.model === first.target.model && $0.depth == first.depth }) else {
                    throw ProbeError("Qwen TP speculative cohort differs from one loaded head and target")
                }
                let sessions = try decoders.enumerated().map { row, decoder -> QwenTensorParallelBatchSession in
                    guard let session = decoder.target as? QwenTensorParallelBatchSession,
                          decoder.canSpeculate(lastToken: lastTokens[row], remaining: remaining[row]) else {
                        throw ProbeError("Qwen TP speculative cohort includes an ineligible request")
                    }
                    return session
                }
                guard Set(sessions.map { ObjectIdentifier($0) }).count == sessions.count else {
                    throw ProbeError("Qwen TP speculative cohort reuses target history")
                }
                let columns = first.depth + 1, started = DispatchTime.now().uptimeNanoseconds
                var clock = QwenTensorParallelMTPRoundProfile.Clock()
                var profile = QwenTensorParallelMTPRoundProfile(rows: decoders.count)
                let seeds = lastTokens.map { MLXArray([Int32($0)]).reshaped([1, 1]) }
                var feeds = decoders.indices.map { (tokens: seeds[$0], hidden: decoders[$0].carry!.hidden) }
                var proposed = [[MLXArray]](repeating: [], count: decoders.count)
                for _ in 0..<first.depth {
                    var next: [(tokens: MLXArray, hidden: MLXArray)] = []
                    if batchesDrafts, first.head.assistant.splitsDrafts {
                        // Each row's assistant forward is its own B=1 graph over
                        // its own history; the vocabulary-sharded head chooses
                        // every row's proposal in one call, so a draft step holds
                        // two collectives for the whole cohort (rank 0's hidden
                        // rows, then the score exchange), in one evaluation, in
                        // the same order on both ranks. Each row's choice is its
                        // own call's: both sums are element-wise, the head shard
                        // multiplies its rows with MLX's vector kernel (below the
                        // vector limit every vector's reduction is the same at
                        // any count) and the first maximum is taken per row.
                        let hiddens = decoders.indices.map { row in
                            decoders[row].head.assistant.draftHidden(tokens: feeds[row].tokens,
                                hidden: feeds[row].hidden, requestState: decoders[row].state)
                        }
                        let scores = first.head.projection(concatenated(hiddens, axis: 0))
                        let choices = argMax(scores[0..., -1, 0...], axis: -1).asType(.int32)
                        var roots = [choices]
                        for (row, decoder) in decoders.enumerated() {
                            let draft = choices[row ..< row + 1]
                            decoder.head.assistant.recordDraft(lastHidden: hiddens[row], draft: draft,
                                requestState: decoder.state)
                            roots += [hiddens[row]] + decoder.head.assistant.evaluationTargets(for: decoder.state)
                            next.append((draft, hiddens[row]))
                        }
                        eval(roots); try checked()
                    } else {
                        // One row at a time, each row's proposal evaluated alone:
                        // its two collectives must not interleave with another
                        // row's in a schedule that can differ by rank.
                        for (row, decoder) in decoders.enumerated() {
                            let step = decoder.head.assistant.draftStep(tokens: feeds[row].tokens, hidden: feeds[row].hidden,
                                shortlist: nil, requestState: decoder.state)
                            eval([step.tokens, step.hidden] + decoder.head.assistant.evaluationTargets(for: decoder.state))
                            try checked()
                            next.append(step)
                        }
                    }
                    // Both ranks read every proposal from the same exchanged
                    // (maximum, index) pairs, so no broadcast is needed.
                    for row in decoders.indices {
                        let token = next[row].tokens.reshaped([1, 1])
                        proposed[row].append(token); feeds[row] = (token, next[row].hidden)
                    }
                }
                let drafts = proposed.map { concatenated($0, axis: 1) }
                let inputs = decoders.indices.map { concatenated([seeds[$0], drafts[$0]], axis: 1) }
                profile.draft = clock.lap()
                let built = try QwenTensorParallelBatchSession.beginWindows(sessions,
                    tokens: concatenated(inputs, axis: 0))
                profile.build = clock.lap()
                eval(built.outputs + built.roots); try checked()
                try QwenTensorParallelBatchSession.confirmWindows(sessions, check: checked)
                profile.verify = clock.lap()
                let selected: MLXArray
                if decoders.allSatisfy({ $0.request.sampling == nil }) {
                    // A greedy cohort: both ranks derive the same choices from one exchange.
                    selected = try first.greedyChoices(built.outputs[0], count: columns, rows: decoders.count,
                        check: checked)
                    profile.gather = clock.lap()
                } else {
                    let full = try first.gathered(built.outputs[0], count: columns, rows: decoders.count, check: checked)
                    profile.gather = clock.lap()
                    let choices: MLXArray
                    if first.group.rank == 0 {
                        let rows = decoders.enumerated().map { row, decoder -> MLXArray in
                            let logits = full[row..<row + 1]
                            return (decoder.request.sampler?.verifyRound(logits) ?? argMax(logits, axis: -1)).reshaped([columns])
                        }
                        choices = concatenated(rows, axis: 0)
                    } else { choices = MLXArray.zeros([decoders.count * columns], dtype: .int32) }
                    selected = try first.broadcast(choices, count: decoders.count * columns, check: checked)
                        .reshaped([decoders.count, columns])
                }
                let decisions = try decoders.enumerated().map { row, decoder in
                    try accept(drafts: drafts[row].asArray(Int32.self).map(Int.init),
                        targets: selected[row].asArray(Int32.self).map(Int.init), remaining: remaining[row],
                        stopTokens: decoder.stops, vocabularySize: decoder.request.profile.vocabularySize)
                }
                let evaluated = DispatchTime.now().uptimeNanoseconds
                profile.choose = clock.lap()
                var roots = try QwenTensorParallelBatchSession.settleWindows(sessions,
                    keeping: decisions.map { $0.tokens.count })
                for (row, decoder) in decoders.enumerated() {
                    let decision = decisions[row], emitted = decision.tokens.count
                    let trusted = min(decision.accepted, emitted - 1)
                    let hidden = built.outputs[1][row..<row + 1]
                    decoder.head.assistant.finalizeRound(requestState: decoder.state, confirmedInputTokens: 1 + trusted,
                        committedDraftTokens: drafts[row][0..., 0..<trusted],
                        committedTargetHidden: hidden[0..., 0..<trusted, 0...])
                    decoder.head.assistant.observeCommittedTarget(.init(
                        tokens: inputs[row][0..., (emitted - 1)..<emitted],
                        hidden: hidden[0..., (emitted - 1)..<emitted, 0...]), requestState: decoder.state)
                    decoder.carry = (decision.tokens.last!, hidden[0..., (emitted - 1)..<emitted, 0...])
                    roots += decoder.head.assistant.evaluationTargets(for: decoder.state) + [decoder.carry!.hidden]
                }
                eval(roots); try checked()
                try QwenTensorParallelBatchSession.confirmSettledWindows(sessions, check: checked)
                var result: [Emitted] = []
                for (row, decoder) in decoders.enumerated() {
                    let decision = decisions[row]
                    var logprobs: [ClusterWorkerTokenLogprobs] = []
                    if first.group.rank == 0, let sampler = decoder.request.sampler {
                        logprobs = sampler.takeRoundLogprobs(tokens: decision.tokens)
                        sampler.commitRound(decision.tokens)
                    }
                    decoder.selectedCount += decision.tokens.count
                    decoder.statistics.emittedTokens += decision.tokens.count
                    decoder.statistics.rounds += 1
                    for index in 0..<min(decision.accepted + 1, decoder.depth) { decoder.statistics.examinedByPosition[index] += 1 }
                    for index in 0..<decision.accepted { decoder.statistics.acceptedByPosition[index] += 1 }
                    decoder.statistics.evaluateNanoseconds += evaluated - started
                    decoder.statistics.settleNanoseconds += DispatchTime.now().uptimeNanoseconds - evaluated
                    result.append(.init(tokens: decision.tokens, logprobs: logprobs, speculative: true))
                }
                try checked()
                profile.settle = clock.lap()
                decoders.forEach { $0.lastProfile = profile }
                return result
            }
        } catch { decoders.forEach { $0.failed = true }; throw error }
    }

    func canSpeculate(lastToken: Int, remaining: Int) -> Bool {
        !retired && !failed && selectedCount > 0 && carry?.token == lastToken
            && remaining == request.outputCount - selectedCount && remaining >= depth
            && (request.sampler?.admitsSpeculativeVerification ?? true)
    }

    /// This request's next round from its own settled carry: the input and the
    /// output allowance a round may use even while earlier selections still
    /// wait for client credit (the decoder is then ahead of the driver). Nil
    /// when that round could not speculate, or when the carry is a stop token:
    /// the request ends there, so nothing may be verified past it.
    func settledFrontier() -> (lastToken: Int, remaining: Int)? {
        guard let token = carry?.token, !stops.contains(token) else { return nil }
        let remaining = request.outputCount - selectedCount
        return canSpeculate(lastToken: token, remaining: remaining) ? (token, remaining) : nil
    }

    /// A genuine ordinary batch already evaluated and committed this target
    /// input and selected the next token. Extend only this request's assistant
    /// history, allowing singleton speculation to resume without a reload.
    func observeOrdinary(inputToken: Int, hidden: MLXArray, selectedToken: Int,
                         check: () throws -> Void) throws {
        do {
            try MLX.withError { error in
                guard !retired, !failed, selectedCount > 0, selectedCount < request.outputCount,
                      carry?.token == inputToken,
                      target.state.committedTokens == request.promptCount + selectedCount,
                      hidden.shape == [1, 1, target.model.plan.hiddenSize],
                      String(describing: hidden.dtype) == request.profile.activationDType,
                      (0..<request.profile.vocabularySize).contains(selectedToken),
                      group.rank != 0 || request.sampler == nil || request.sampler?.nextOutputIndex == selectedCount + 1 else {
                    throw ProbeError("Qwen TP assistant ordinary observation differs from its committed lane")
                }
                head.assistant.observeCommittedTarget(.init(
                    tokens: MLXArray([Int32(inputToken)]).reshaped([1, 1]), hidden: hidden), requestState: state)
                head.assistant.flushTrustedHistory(requestState: state)
                carry = (selectedToken, hidden)
                eval(head.assistant.evaluationTargets(for: state) + [hidden]); try error.check(); try check()
                selectedCount += 1; statistics.emittedTokens += 1; statistics.plainSteps += 1
            }
        } catch { failed = true; throw error }
    }

    func discardCapturedPrefix() { captured = nil }

    /// Trusted target rows queued for head K/V (inspection).
    var trustedBacklogRows: Int { head.assistant.trustedBacklogRows(requestState: state) }

    static func accept(drafts: [Int], targets: [Int], remaining: Int, stopTokens: Set<Int>,
                       vocabularySize: Int) throws -> (tokens: [Int], accepted: Int) {
        guard (0...4).contains(drafts.count), targets.count == drafts.count + 1, remaining > 0,
              vocabularySize > 0, (drafts + targets).allSatisfy({ (0..<vocabularySize).contains($0) }) else {
            throw ProbeError("Qwen TP MTP target-prefix decision is malformed")
        }
        var accepted = 0
        while accepted < drafts.count, drafts[accepted] == targets[accepted] { accepted += 1 }
        var emitted = min(accepted + 1, remaining)
        if let stop = targets[..<emitted].firstIndex(where: stopTokens.contains) { emitted = stop + 1 }
        return (Array(targets[..<emitted]), accepted)
    }

    private func broadcast(_ choices: MLXArray, count: Int, check: () throws -> Void) throws -> MLXArray {
        let supplied = group.rank == 0 ? choices.asType(.float32) : MLXArray.zeros([count], dtype: .float32)
        let result = group.allSum(supplied); eval(result); try check()
        guard result.shape == [count], result.dtype == .float32,
              all(isFinite(result) .&& (result .>= 0) .&& (result .< Float(request.profile.vocabularySize))
                .&& (result .== floor(result))).item(Bool.self) else {
            throw ProbeError("Qwen TP MTP authoritative token exchange is invalid")
        }
        return result.asType(.int32)
    }

    /// Greedy rows (no sampling state, agreed on both ranks) need only each
    /// logit row's first maximum. Each rank reduces its vocabulary interval to
    /// (maximum, first global index, non-finite count) and one small sum gives
    /// both ranks the same bits; the lower interval wins an equal maximum, so
    /// the choice is the gathered row's first argmax, with no second exchange.
    /// A non-finite logit on either rank fails both, as `gathered` does.
    private func greedyChoices(_ logits: MLXArray, count: Int, rows: Int = 1,
                               check: () throws -> Void) throws -> MLXArray {
        let range = target.model.vocabularyRange
        guard (1...8).contains(rows), logits.shape == [rows, count, range.count] else {
            throw ProbeError("Qwen TP MTP shard logits differ")
        }
        let values = logits.asType(.float32)
        let mine = stacked([values.max(axis: -1),
            argMax(values, axis: -1).asType(.float32) + Float(range.lowerBound),
            (1 - isFinite(values).asType(.float32)).sum(axis: -1)], axis: -1)
        let empty = MLXArray.zeros(mine.shape, dtype: .float32)
        let both = group.allSum(concatenated(group.rank == 0 ? [mine, empty] : [empty, mine], axis: -1))
        let choices = which(both[0..., 0..., 3] .> both[0..., 0..., 0], both[0..., 0..., 4], both[0..., 0..., 1])
        eval(both, choices); try check()
        guard both.shape == [rows, count, 6],
              all((both[0..., 0..., 2] .== 0) .&& (both[0..., 0..., 5] .== 0)).item(Bool.self) else {
            throw ProbeError("Qwen TP MTP gathered target rows are invalid")
        }
        let tokens = choices.asType(.int32)
        guard all((tokens .>= 0) .&& (tokens .< request.profile.vocabularySize)).item(Bool.self) else {
            throw ProbeError("Qwen TP MTP greedy choice is outside the vocabulary")
        }
        return tokens
    }

    private func gathered(_ logits: MLXArray, count: Int, rows: Int = 1, check: () throws -> Void) throws -> MLXArray {
        let range = target.model.vocabularyRange, vocabulary = target.model.plan.vocabularySize
        guard (1...8).contains(rows), logits.shape == [rows, count, range.count] else { throw ProbeError("Qwen TP MTP shard logits differ") }
        var parts: [MLXArray] = []
        if range.lowerBound > 0 { parts.append(-MLXArray.zeros([rows, count, range.lowerBound], dtype: .float32)) }
        parts.append(logits.asType(.float32))
        if range.upperBound < vocabulary { parts.append(-MLXArray.zeros([rows, count, vocabulary - range.upperBound], dtype: .float32)) }
        let full = group.allSum(concatenated(parts, axis: -1)); eval(full); try check()
        guard full.shape == [rows, count, vocabulary], full.dtype == .float32,
              all(isFinite(full)).item(Bool.self) else { throw ProbeError("Qwen TP MTP gathered target rows are invalid") }
        return full
    }

    /// The owner may publish this only after the separate bilateral clean
    /// retirement vote. Local retirement alone never inserts a resident entry.
    func takeCapturedPrefix() throws -> QwenTensorParallelMTPPrefixState? {
        guard retired, target.retired, target.state.isClosed else {
            throw ProbeError("Qwen TP assistant prefix donation precedes checked retirement")
        }
        defer { captured = nil }
        guard !failed else { return nil }
        return captured
    }

    func retire() throws {
        guard !retired else { return }
        try MLX.withError { error in
            Stream.gpu.synchronize(); Stream.cpu.synchronize(); try error.check()
            head.assistant.releaseRequestState(state)
            try target.retire(); try error.check()
            guard state.materializedBytes == 0 else { throw ProbeError("Qwen TP MTP assistant remains live after retirement") }
            promptFrontier = nil; carry = nil; retired = true
        }
    }
}
