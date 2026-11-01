import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing
@testable import DarkbloomClusterRuntime

/// Opt-in: speculative acceptance on real chat prompts with the TP drafts on
/// MLX's kernels and on `AffineQuantizedVectors`
/// (`QwenTensorParallelMTPDecoder.draftsOnExactVectors`), both ranks of a real
/// dense row with its real assistant in one process (two threads whose all-sum
/// adds both ranks' float32 elements in rank order, each on its own MLX
/// stream). Every prompt decodes greedily three ways: the plain target, one
/// step per token, and one speculative request per draft mode. Both
/// speculative outputs must be the plain target's tokens, identical on both
/// ranks (MTP is lossless). The bench reports each mode's rounds, tokens per
/// round and acceptance by draft position and, over the rounds both modes
/// begin at the same output position, how often and where their proposals
/// differ and which mode's proposal the target kept.
/// QWEN_TP_ACCEPT_BENCH_MODEL=<model dir with mtp-*.safetensors>
/// QWEN_TP_ACCEPT_BENCH_PROMPTS=<JSON {"prompts": [[token id]]}>
/// [QWEN_TP_ACCEPT_BENCH_OUTPUTS=128] [QWEN_TP_ACCEPT_BENCH_DEPTH=3]
/// [QWEN_TP_ACCEPT_BENCH_STOPS=248046] [QWEN_TP_ACCEPT_BENCH_LOG=<file>]
@Suite("Qwen TP MTP acceptance on real prompts by draft kernel", .serialized)
struct QwenTensorParallelMTPAcceptanceRealTests {
    private final class Wire: @unchecked Sendable {
        let condition = NSCondition()
        var leaving = 0, step = 0
        var values: [Int: [Float]] = [:], shapes: [Int: [Int]] = [:]
        var output: [Float] = []
        func sum(_ value: MLXArray, rank: Int) -> MLXArray {
            precondition(value.dtype == .float32)
            let bytes = value.asArray(Float.self)
            condition.lock()
            while leaving > 0 { condition.wait() }
            let generation = step
            precondition(values[rank] == nil)
            values[rank] = bytes; shapes[rank] = value.shape
            if values.count == 2 {
                precondition(shapes[0] == shapes[1])
                output = zip(values[0]!, values[1]!).map(+)
                leaving = 2; condition.broadcast()
            } else {
                let deadline = Date().addingTimeInterval(300)
                while leaving == 0 && step == generation { precondition(condition.wait(until: deadline)) }
            }
            let result = output; leaving -= 1
            if leaving == 0 { values = [:]; shapes = [:]; output = []; step += 1; condition.broadcast() }
            condition.unlock()
            return MLXArray(result, value.shape)
        }
    }

    private final class Rank: QwenTensorParallelReduction, @unchecked Sendable {
        let rank: Int, size = 2, wire: Wire
        init(_ rank: Int, _ wire: Wire) { self.rank = rank; self.wire = wire }
        func allSum(_ value: MLXArray) -> MLXArray {
            // Integer agreements cross as float32, as the sealed product group sends them.
            value.dtype == .float32 ? wire.sum(value, rank: rank) : wire.sum(value.asType(.float32), rank: rank).asType(value.dtype)
        }
    }

    /// One thread per rank for the whole run, with its own MLX stream, as each
    /// rank's process has (MLX's command encoders are thread-local, and the
    /// run makes hundreds of paired calls).
    private final class RankThread: @unchecked Sendable {
        private let condition = NSCondition()
        private var job: (() -> Void)?
        private var busy = false, stopping = false
        private var thread: Thread?
        init(name: String) {
            let thread = Thread { [unowned self] in
                Device.withDefaultDevice(.gpu) {
                    Stream.withNewDefaultStream(device: .gpu) {
                        while true {
                            self.condition.lock()
                            while self.job == nil && !self.stopping { self.condition.wait() }
                            guard let work = self.job else { self.condition.unlock(); return }
                            self.condition.unlock()
                            work()
                            self.condition.lock()
                            self.job = nil; self.busy = false
                            self.condition.broadcast()
                            self.condition.unlock()
                        }
                    }
                }
            }
            thread.name = name
            thread.stackSize = 16 << 20
            self.thread = thread
            thread.start()
        }
        func run(_ work: @escaping () -> Void) {
            condition.lock()
            precondition(!busy && !stopping, "Qwen TP acceptance bench: a rank thread is busy")
            busy = true; job = work
            condition.broadcast()
            condition.unlock()
        }
        func wait() {
            condition.lock()
            while busy { condition.wait() }
            condition.unlock()
        }
        func stop() {
            condition.lock()
            stopping = true
            condition.broadcast()
            condition.unlock()
        }
    }

    private final class Owner: @unchecked Sendable {
        let model: QwenTensorParallelModel, host: CBv2StageKVHost
        let head: QwenTensorParallelMTPHead, reduction: Rank, thread: RankThread
        var session: QwenTensorParallelBatchSession?
        var decoder: QwenTensorParallelMTPDecoder?
        var best: (value: Float, index: Int) = (0, 0)
        var emitted: [Int] = [], drafts: [Int] = []
        var failure: Error?
        init(_ model: QwenTensorParallelModel, _ host: CBv2StageKVHost, _ head: QwenTensorParallelMTPHead,
             _ reduction: Rank, _ thread: RankThread) {
            self.model = model; self.host = host; self.head = head; self.reduction = reduction; self.thread = thread
        }
    }

    /// Both ranks run `body` at once, each on its own thread and stream, with
    /// the draft kernel bound on each thread.
    private func paired(_ owners: [Owner], exact: Bool? = nil, _ body: @escaping (Owner) throws -> Void) throws {
        for owner in owners { owner.failure = nil }
        for owner in owners {
            owner.thread.run {
                QwenTensorParallelMTPDecoder.$draftsOnExactVectorsOverride.withValue(exact) {
                    do { try body(owner) } catch { owner.failure = error }
                }
            }
        }
        for owner in owners { owner.thread.wait() }
        for owner in owners { if let failure = owner.failure { throw failure } }
    }

    private final class Loaded: @unchecked Sendable {
        var owner: Owner?
        var failure: Error?
    }

    /// This rank's (maximum, first global index) over its vocabulary interval.
    private static func best(_ logits: MLXArray, range: Range<Int>) -> (value: Float, index: Int) {
        let values = logits.asType(.float32).reshaped([-1])
        precondition(values.size == range.count, "Qwen TP acceptance bench: shard logits differ")
        let index = argMax(values, axis: -1)
        eval(values, index)
        let local = Int(index.item(Int32.self))
        return (values[local].item(Float.self), range.lowerBound + local)
    }

    /// The gathered row's first maximum, as the decoder's greedy exchange
    /// takes it: the upper interval wins only a strictly larger maximum.
    private static func choose(_ owners: [Owner]) -> Int {
        owners[1].best.value > owners[0].best.value ? owners[1].best.index : owners[0].best.index
    }

    private struct Round { let start: Int; let drafts: [Int]; let emitted: [Int] }
    private struct Run { let tokens: [Int]; let rounds: [Round]; let statistics: QwenMTPStatistics }

    /// The plain target's greedy tokens: the prompt's choice, then one decode step per token.
    private func plain(_ owners: [Owner], configuration: Data, request: QwenLayerStageGenerationRequest,
                       stops: Set<Int>) throws -> [Int] {
        try paired(owners) { owner in
            let session = try QwenTensorParallelBatchSession(model: owner.model, configuration: configuration,
                host: owner.host, request: request)
            owner.session = session
            var logits: MLXArray?
            while session.schedule.committedPromptTokens < request.promptCount {
                logits = try session.prefill(check: {}) ?? logits
            }
            guard let logits else { throw ProbeError("Qwen TP acceptance bench: the prompt returned no logits") }
            owner.best = Self.best(logits, range: owner.model.vocabularyRange)
        }
        var tokens = [Self.choose(owners)]
        while tokens.count < request.outputCount, !stops.contains(tokens.last!) {
            let last = tokens.last!
            try paired(owners) { owner in
                let logits = try QwenTensorParallelBatchSession.decode([owner.session!], tokens: [last], check: {})
                owner.best = Self.best(logits, range: owner.model.vocabularyRange)
            }
            tokens.append(Self.choose(owners))
        }
        try paired(owners) { owner in try owner.session!.retire(); owner.session = nil }
        return tokens
    }

    /// One speculative request with the given draft kernel; both ranks must
    /// emit and propose the same tokens every round.
    private func speculative(_ owners: [Owner], exact: Bool, configuration: Data,
                             request: QwenLayerStageGenerationRequest, depth: Int, stops: Set<Int>) throws -> Run {
        try paired(owners, exact: exact) { owner in
            let session = try QwenTensorParallelBatchSession(model: owner.model, configuration: configuration,
                host: owner.host, request: request)
            let decoder = try QwenTensorParallelMTPDecoder(target: session, head: owner.head, group: owner.reduction,
                depth: depth)
            owner.session = session; owner.decoder = decoder
            var logits: MLXArray?
            while session.schedule.committedPromptTokens < request.promptCount {
                logits = try decoder.prefill(check: {}) ?? logits
            }
            guard let logits else { throw ProbeError("Qwen TP acceptance bench: the prompt returned no logits") }
            owner.best = Self.best(logits, range: owner.model.vocabularyRange)
        }
        let first = Self.choose(owners)
        try paired(owners, exact: exact) { owner in try owner.decoder!.begin(firstToken: first) }
        var tokens = [first], rounds: [Round] = []
        while tokens.count < request.outputCount, !stops.contains(tokens.last!) {
            let last = tokens.last!, remaining = request.outputCount - tokens.count
            try paired(owners, exact: exact) { owner in
                owner.emitted = try owner.decoder!.step(lastToken: last, remaining: remaining, check: {}).tokens
                owner.drafts = owner.decoder!.lastDraftIDs
            }
            guard owners[0].emitted == owners[1].emitted, owners[0].drafts == owners[1].drafts,
                  !owners[0].emitted.isEmpty else {
                throw ProbeError("Qwen TP acceptance bench: the ranks emitted or proposed differently")
            }
            rounds.append(.init(start: tokens.count, drafts: owners[0].drafts, emitted: owners[0].emitted))
            tokens += owners[0].emitted
        }
        let statistics = owners[0].decoder!.statistics
        try paired(owners, exact: exact) { owner in
            try owner.decoder!.retire(); owner.decoder = nil; owner.session = nil
        }
        return .init(tokens: tokens, rounds: rounds, statistics: statistics)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_TP_ACCEPT_BENCH_MODEL"] != nil
        && ProcessInfo.processInfo.environment["QWEN_TP_ACCEPT_BENCH_PROMPTS"] != nil))
    func exactAndMLXDraftsOnRealPromptsAreLosslessWithTheirAcceptance() throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: environment["QWEN_TP_ACCEPT_BENCH_MODEL"]!, isDirectory: true)
        let document = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath:
            environment["QWEN_TP_ACCEPT_BENCH_PROMPTS"]!))) as? [String: Any]
        let prompts = try #require(document?["prompts"] as? [[Int]])
        let outputs = Int(environment["QWEN_TP_ACCEPT_BENCH_OUTPUTS"] ?? "") ?? 128
        let depth = Int(environment["QWEN_TP_ACCEPT_BENCH_DEPTH"] ?? "") ?? 3
        let stops = Set((environment["QWEN_TP_ACCEPT_BENCH_STOPS"] ?? "248046").split(separator: ",").compactMap { Int($0) })
        let log: FileHandle? = environment["QWEN_TP_ACCEPT_BENCH_LOG"].flatMap { path in
            FileManager.default.createFile(atPath: path, contents: nil)
            return FileHandle(forWritingAtPath: path)
        }
        func report(_ line: String) {
            print(line)
            log?.write(Data((ISO8601DateFormatter().string(from: Date()) + " " + line + "\n").utf8))
        }
        let name = directory.lastPathComponent
        let configuration = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        let wire = Wire()
        let threads = (0..<2).map { RankThread(name: "qwen-tp-acceptance-rank\($0)") }
        defer { threads.forEach { $0.stop() } }
        // Each rank loads on its own thread, one rank at a time.
        let owners = try (0..<2).map { rank -> Owner in
            let loaded = Loaded()
            threads[rank].run {
                do {
                    let reduction = Rank(rank, wire)
                    let model = try QwenTensorParallelModel.load(modelDirectory: directory,
                        role: .shard(rank: rank, size: 2), reduction: reduction)
                    var assistantWeights: [String: MLXArray] = [:]
                    for file in try FileManager.default.contentsOfDirectory(atPath: directory.path)
                    where file.hasPrefix("mtp-") && file.hasSuffix(".safetensors") {
                        // The owner indexes the assistant without its checkpoint prefix.
                        for (key, value) in try loadArrays(url: directory.appendingPathComponent(file)) {
                            assistantWeights[key.hasPrefix("mtp.") ? String(key.dropFirst("mtp.".count)) : key] = value
                        }
                    }
                    eval(Array(assistantWeights.values))
                    let head = try QwenTensorParallelMTPHead(model: model, configuration: configuration,
                        indexedWeights: assistantWeights, reduction: reduction)
                    let host = try CBv2StageKVHost(model: model.model, kind: .paged, lanes: 1,
                        maximumTokensPerRequest: 1024, maximumChunkTokens: 128)
                    loaded.owner = Owner(model, host, head, reduction, threads[rank])
                } catch { loaded.failure = error }
            }
            threads[rank].wait()
            if let failure = loaded.failure { throw failure }
            return try #require(loaded.owner)
        }
        let plan = owners[0].model.plan
        let profile = try QwenLayerStageGenerationProfile(identifier: "qwen-tp-mtp-acceptance-real",
            vocabularySize: plan.vocabularySize, hiddenSize: plan.hiddenSize, activationDType: "bfloat16",
            maximumPromptTokens: 512, maximumChunkTokens: 128, maximumOutputTokens: 512, maximumContextTokens: 1024)
        var header = "darkbloom-mtp-acceptance-v1 model=\(name) depth=\(depth) outputs=\(outputs)"
        header += " prompts=\(prompts.count) stops=\(stops.sorted()) gpu=\(GPU.deviceInfo().architecture)"
        report(header)
        let modes: [(name: String, exact: Bool)] = [("mlx", false), ("exact", true)]
        var totals: [String: (rounds: Int, tokens: Int, accepted: [Int], examined: [Int])] = [:]
        var comparison = (aligned: 0, differing: 0, firstDifference: [Int](repeating: 0, count: depth),
                          exactKept: 0, mlxKept: 0, neither: 0, unexamined: 0)
        for (index, prompt) in prompts.enumerated() {
            let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
                promptTokenIDs: prompt, chunkSize: 128, outputCount: outputs, stopTokenIDs: stops)
            let reference = try plain(owners, configuration: configuration, request: request, stops: stops)
            var runs: [String: Run] = [:]
            // Both orders over the prompts; acceptance is deterministic, the order only spreads drift.
            for mode in index % 2 == 0 ? modes : Array(modes.reversed()) {
                let run = try speculative(owners, exact: mode.exact, configuration: configuration, request: request,
                    depth: depth, stops: stops)
                runs[mode.name] = run
                let lossless = run.tokens == reference
                #expect(lossless, "\(name) prompt \(index) drafts=\(mode.name): speculative output differs from the plain target")
                let speculativeRounds = run.rounds.filter { !$0.drafts.isEmpty }
                let tokens = speculativeRounds.reduce(0) { $0 + $1.emitted.count }
                let statistics = run.statistics
                var total = totals[mode.name] ?? (rounds: 0, tokens: 0, accepted: [Int](repeating: 0, count: depth),
                    examined: [Int](repeating: 0, count: depth))
                total.rounds += speculativeRounds.count; total.tokens += tokens
                for position in 0..<depth {
                    total.accepted[position] += statistics.acceptedByPosition[position]
                    total.examined[position] += statistics.examinedByPosition[position]
                }
                totals[mode.name] = total
                let perRound = String(format: "%.3f", Double(tokens) / Double(max(1, speculativeRounds.count)))
                let accepted = statistics.acceptedByPosition.map(String.init).joined(separator: ",")
                let examined = statistics.examinedByPosition.map(String.init).joined(separator: ",")
                var line = "darkbloom-mtp-acceptance-v1 model=\(name) prompt=\(index) drafts=\(mode.name)"
                line += " prompt_tokens=\(prompt.count) tokens=\(run.tokens.count) rounds=\(speculativeRounds.count)"
                line += " plain_steps=\(statistics.plainSteps) tokens_per_round=\(perRound)"
                line += " accepted=\(accepted) examined=\(examined) lossless=\(lossless ? 1 : 0)"
                report(line)
            }
            // Rounds both modes begin at the same output position: the same
            // committed tokens, so a differing proposal is the kernel's.
            let mlxRounds = Dictionary(uniqueKeysWithValues: runs["mlx"]!.rounds.filter { !$0.drafts.isEmpty }
                .map { ($0.start, $0) })
            var aligned = 0, differing = 0, exactKept = 0, mlxKept = 0, neither = 0, unexamined = 0
            for round in runs["exact"]!.rounds where !round.drafts.isEmpty {
                guard let other = mlxRounds[round.start], other.drafts.count == round.drafts.count else { continue }
                aligned += 1
                guard let position = round.drafts.indices.first(where: { round.drafts[$0] != other.drafts[$0] }) else { continue }
                differing += 1; comparison.firstDifference[position] += 1
                // Examined only if every earlier proposal (equal in both) was the target's token.
                let examined = (0..<position).allSatisfy { round.start + $0 < reference.count
                    && round.drafts[$0] == reference[round.start + $0] }
                guard examined, round.start + position < reference.count else { unexamined += 1; continue }
                let target = reference[round.start + position]
                if round.drafts[position] == target { exactKept += 1 }
                else if other.drafts[position] == target { mlxKept += 1 }
                else { neither += 1 }
            }
            comparison.aligned += aligned; comparison.differing += differing
            comparison.exactKept += exactKept; comparison.mlxKept += mlxKept
            comparison.neither += neither; comparison.unexamined += unexamined
            var line = "darkbloom-mtp-acceptance-v1 model=\(name) prompt=\(index) aligned_rounds=\(aligned)"
            line += " differing_rounds=\(differing) exact_kept=\(exactKept) mlx_kept=\(mlxKept)"
            line += " neither=\(neither) unexamined=\(unexamined)"
            report(line)
        }
        for mode in modes {
            guard let total = totals[mode.name] else { continue }
            let perRound = String(format: "%.3f", Double(total.tokens) / Double(max(1, total.rounds)))
            let accepted = total.accepted.map(String.init).joined(separator: ",")
            let examined = total.examined.map(String.init).joined(separator: ",")
            var line = "darkbloom-mtp-acceptance-v1 model=\(name) total drafts=\(mode.name) rounds=\(total.rounds)"
            line += " tokens=\(total.tokens) tokens_per_round=\(perRound) accepted=\(accepted) examined=\(examined)"
            report(line)
        }
        let firstDifference = comparison.firstDifference.map(String.init).joined(separator: ",")
        var summary = "darkbloom-mtp-acceptance-v1 model=\(name) total aligned_rounds=\(comparison.aligned)"
        summary += " differing_rounds=\(comparison.differing) first_difference_by_position=\(firstDifference)"
        summary += " exact_kept=\(comparison.exactKept) mlx_kept=\(comparison.mlxKept)"
        summary += " neither=\(comparison.neither) unexamined=\(comparison.unexamined)"
        report(summary)
        #expect(owners.allSatisfy { $0.host.isDrained })
    }
}
