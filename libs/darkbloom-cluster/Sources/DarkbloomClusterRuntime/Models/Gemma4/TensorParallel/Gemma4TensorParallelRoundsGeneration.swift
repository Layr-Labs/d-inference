import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLLM

/// A loaded Gemma 4 assistant checkpoint, for callers that do not link the
/// model library (tools). One per rank: a drafter binds to one target.
public final class Gemma4AssistantCheckpoint: @unchecked Sendable {
    let model: Gemma4AssistantDraftModel
    init(_ model: Gemma4AssistantDraftModel) { self.model = model }

    /// Reads an assistant checkpoint directory (`config.json` and its
    /// safetensors) on the calling thread. Tools and oracles; the product's
    /// loader verifies the catalog's pinned artifact first.
    public static func load(directory: URL) throws -> Gemma4AssistantCheckpoint {
        Gemma4AssistantCheckpoint(try loadModel(directory: directory))
    }

    static func loadModel(directory: URL) throws -> Gemma4AssistantDraftModel {
        final class Box: @unchecked Sendable { var result: Result<Gemma4AssistantDraftModel, Error>? }
        let box = Box(), done = DispatchSemaphore(value: 0)
        // The default device is task-scoped: the detached load runs on the caller's.
        let device = Device.defaultDevice()
        Task.detached {
            do {
                box.result = .success(try await Device.withDefaultDevice(device) {
                    try await Gemma4AssistantDraftModel.load(from: directory)
                })
            }
            catch { box.result = .failure(error) }
            done.signal()
        }
        done.wait()
        return try box.result!.get()
    }
}

extension Gemma4TensorParallelModel {
    /// Speculation counts of one generation (`generateRounds`).
    public struct RoundsReport: Codable, Equatable, Sendable {
        public var depth: Int
        public var rounds: Int
        public var plainRounds: Int
        public var proposed: Int
        public var accepted: Int
        public var proposedByPosition: [Int]
        public var acceptedByPosition: [Int]
    }

    /// Greedy generation of `outputCount` tokens through the resident
    /// runtime's request loop in speculative rounds of `depth` proposals from
    /// `assistant` (`Gemma4TensorParallelRequestLoop.runRounds`), on a paged
    /// host of its own; every rank of a pair calls it together. The tokens
    /// are the plain path's (`generatePaged`). Tools and oracles.
    public func generateRounds(prompt: [Int], outputCount: Int, chunk: Int, assistant: Gemma4AssistantCheckpoint,
                               depth: Int) throws -> (generation: Generation, rounds: RoundsReport) {
        guard !prompt.isEmpty, outputCount >= 1, chunk >= 1, prompt.allSatisfy({ (0 ..< plan.vocabularySize).contains($0) }) else {
            throw ProbeError("Gemma tensor parallel generation: empty or out-of-vocabulary request")
        }
        let rank: Int
        if case .shard(let r) = role { rank = r } else { rank = 0 }
        let host = try pagedHost(lanes: 1, maximumTokens: prompt.count + outputCount, chunkTokens: chunk)
        let session = try Gemma4TensorParallelPagedSession(model: self, host: host, promptCount: prompt.count,
            outputCount: outputCount)
        let profile = try QwenLayerStageGenerationProfile(identifier: "gemma4-tp-rounds", vocabularySize: plan.vocabularySize,
            hiddenSize: plan.hiddenSize, activationDType: String(describing: activationDType),
            maximumPromptTokens: prompt.count, maximumChunkTokens: chunk, maximumOutputTokens: outputCount,
            maximumContextTokens: prompt.count + outputCount, logitsDType: "float32")
        let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
            promptTokenIDs: prompt, chunkSize: chunk, outputCount: outputCount, stopTokenIDs: [])
        let choice = Gemma4TensorParallelChoice(selection: selection, sampler: nil, rank: rank)
        var result = Generation()
        var report: RoundsReport?
        do {
            try MLX.withError { error in
                let started = Self.now()
                var firstTokenAt: Double?
                let channel = ClusterCommittedTokenChannel(publish: { ordinal, _, _ in
                    if ordinal == 0 { firstTokenAt = Self.now() }
                }, answer: { true })
                let loop = Gemma4TensorParallelRequestLoop(session: session, request: request, choice: choice,
                    exchange: { [reduction] values in
                        guard let reduction else { return values }
                        let summed = reduction.allSum(MLXArray(values.map(Float.init)))
                        eval(summed)
                        return summed.asArray(Float.self).map { Int32($0) }
                    }, localStop: { false })
                let rounds = try Gemma4TensorParallelRounds(session: session,
                    assistant: try Gemma4TensorParallelAssistant(assistant: assistant.model, model: self, depth: depth),
                    choice: choice)
                let outcome = try loop.runRounds(rounds, channel: channel, check: { try error.check() })
                let ended = Self.now()
                result.tokenIDs = outcome.tokens
                result.firstTokenSeconds = (firstTokenAt ?? ended) - started
                result.decodeSeconds = ended - (firstTokenAt ?? ended)
                let counts = rounds.statistics
                report = RoundsReport(depth: depth, rounds: counts.rounds, plainRounds: counts.plainRounds,
                    proposed: counts.proposed, accepted: counts.accepted,
                    proposedByPosition: Array(counts.proposedByPosition.prefix(depth)),
                    acceptedByPosition: Array(counts.acceptedByPosition.prefix(depth)))
            }
            try session.retire()
        } catch {
            try? session.retire(failed: true)
            throw error
        }
        guard host.isDrained else { throw ProbeError("Gemma tensor-parallel request kept its pages") }
        result.peakActiveBytes = Memory.peakMemory
        return (result, report!)
    }
}
