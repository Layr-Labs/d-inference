import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

/// The three trained next-N heads on a tensor-parallel rank, replicated whole
/// on both ranks (the product's `MiMoV26MTP` and `MiMoV26MTPAssistant`,
/// unchanged): every rank runs the same drafter on the same agreed rows, so
/// its arithmetic is the single-Mac drafter's. Their target is a one-layer
/// shell that holds the rank's own embedding (replicated) and vocabulary rows
/// (shared modules, no copy) and the rank's reduction, so each proposal is the
/// whole vocabulary's argmax from one small sum (`readoutArgMax`).
final class MiMoTensorParallelDraftHead {
    static let prefix = MiMoTensorParallelPlan.textNamespace + "model.mtp."

    let assistant: MiMoV26MTPAssistant
    let headTensors: Int
    let headBytes: Int
    private let shell: MiMoV26TextModel
    private let predictor: MiMoV26MTP

    /// The heads' indexed tensors of a verified checkpoint, by name; no payload.
    static func descriptors(checkpoint: VerifiedCheckpoint) throws -> [String: TensorDescriptor] {
        try tensorDescriptors(checkpoint: checkpoint, scope: .init(acceptsUInt8: true, indexedShardsOnly: true))
            .filter { $0.key.hasPrefix(prefix) }
    }

    /// The heads' tensors (`descriptors`, every one under `prefix`) read whole
    /// through a verified checkpoint (every file already matched its manifest);
    /// `beforeRead` gates each read.
    static func load(descriptors: [String: TensorDescriptor], checkpoint: VerifiedCheckpoint, configurationData: Data,
                     target: MiMoTensorParallelModel, beforeRead: (String, Int) throws -> Void = { _, _ in },
                     check: () throws -> Void = {}) throws -> MiMoTensorParallelDraftHead {
        guard !descriptors.isEmpty, descriptors.keys.allSatisfy({ $0.hasPrefix(prefix) }) else {
            throw ProbeError("MiMo speculative heads are not the artifact's next-N tensors")
        }
        var weights: [String: MLXArray] = [:]
        for name in descriptors.keys.sorted() {
            let descriptor = descriptors[name]!
            guard descriptor.dtype == .bfloat16 else {
                throw ProbeError("MiMo speculative head tensor \(name) is not bfloat16")
            }
            try autoreleasepool {
                try beforeRead(name, descriptor.byteCount)
                let read = try descriptor.read(.all)
                guard read.copiedBytes == descriptor.byteCount, read.array.shape == descriptor.shape else {
                    throw ProbeError("MiMo speculative head read of \(name) is incomplete")
                }
                eval(read.array)
                weights[String(name.dropFirst(prefix.count))] = read.array
                try check()
            }
        }
        try checkpoint.checkUnchanged()
        return try MiMoTensorParallelDraftHead(configurationData: configurationData, target: target, weights: weights)
    }

    /// Tools and oracles: a checkpoint directory with its own `manifest.json`, hashed first.
    static func load(modelDirectory: URL, target: MiMoTensorParallelModel) throws -> MiMoTensorParallelDraftHead {
        let configurationData = try Data(contentsOf: modelDirectory.appendingPathComponent("config.json"))
        let checkpoint = try VerifiedCheckpoint(directory: modelDirectory, configurationData: configurationData,
            hashingConcurrency: MiMoRegisteredSpecification.hashingConcurrency)
        return try load(descriptors: descriptors(checkpoint: checkpoint), checkpoint: checkpoint,
                        configurationData: configurationData, target: target)
    }

    init(configurationData: Data, target: MiMoTensorParallelModel, weights: [String: MLXArray]) throws {
        guard var root = try JSONSerialization.jsonObject(with: configurationData) as? [String: Any],
              BoundedProbeInput.integer(root["num_nextn_predict_layers"]) == MiMoMTPTerms.maximumDepth else {
            throw ProbeError("MiMo tensor-parallel speculation needs the artifact's three trained next-N heads")
        }
        // The heads' target: the whole configuration with one layer that is never evaluated.
        root["num_hidden_layers"] = 1
        root["hybrid_layer_pattern"] = [0]
        root["moe_layer_freq"] = [0]
        for key in ["vision_config", "audio_config", "processor_config", "omlx_mimo_mtp"] { root[key] = nil }
        let configuration = try JSONDecoder().decode(MiMoV26Configuration.self,
            from: try JSONSerialization.data(withJSONObject: root))
        let shell = try withRandomState(MLXRandom.RandomState(seed: 7)) { try MiMoV26TextModel(configuration) }
        if let reduction = target.reduction {
            try shell.installTensorParallel(reduce: { reduction.allSum($0) }, vocabularyRows: target.vocabularyRange)
        }
        let modules = Dictionary(uniqueKeysWithValues: target.model.namedModules())
        guard let embedding = modules["model.embed_tokens"], let head = modules["lm_head"] else {
            throw ProbeError("MiMo tensor-parallel rank has no embedding or head to lend its draft heads")
        }
        try shell.update(modules: ModuleChildren.unflattened([("model.embed_tokens", embedding), ("lm_head", head)]),
                         verify: [.noUnusedKeys])
        let shellModules = Dictionary(uniqueKeysWithValues: shell.namedModules())
        guard shellModules["model.embed_tokens"] === embedding, shellModules["lm_head"] === head,
              shell.headVocabularyRange == target.vocabularyRange else {
            throw ProbeError("MiMo draft heads' target does not hold this rank's embedding and vocabulary rows")
        }
        let predictor = try MiMoV26MTP(target: shell, floatingProjections: true)
        try predictor.loadConvertedWeights(weights, prefix: "")
        predictor.freeze()
        let parameters = predictor.parameters().flattened().map(\.1)
        eval(parameters)
        self.shell = shell; self.predictor = predictor
        headTensors = parameters.count
        headBytes = parameters.reduce(0) { $0 + $1.nbytes }
        assistant = try MiMoV26MTPAssistant(target: shell, predictor: predictor, retaining: nil,
            verificationMode: .rectangular, historyStorage: .contiguous)
    }

    /// One request's drafter state at the allocator's bound: the product's own
    /// bounded declaration for these heads (`maximumPrefillTokens` = the chunk).
    /// It needs the artifact's configuration only, so a rank gates it before
    /// reading anything.
    static func requestBytes(configuration: MiMoV26Configuration, chunkSize: Int, depth: Int,
                             bound: (Int) throws -> Int) throws -> Int {
        guard let spec = MiMoV26MTPAssistant.boundedRequestAllocation(configuration: configuration,
                  limits: .init(maximumPrefillTokens: chunkSize, maximumDraftTokens: depth)) else {
            throw ProbeError("MiMo speculative head declares no bounded request allocation")
        }
        var total = spec.hostBytes
        for buffer in spec.resident + spec.working {
            total = try QwenLongPrefillCheckedBytes.sum([total,
                try QwenLongPrefillCheckedBytes.product([try bound(buffer.logicalBytes), buffer.allocationCount])])
        }
        return total
    }
}

/// Where a round's proposals come from. Both ranks derive them from agreed
/// state only, so they issue the same collectives.
enum MiMoTensorParallelProposer {
    /// The trained heads (`MiMoTensorParallelDrafter`).
    case heads(MiMoTensorParallelDraftHead)
    /// Oracles only: proposal j of a round whose first new output index is i
    /// is `script[i + j]` (`MiMoTensorParallelSpeculation.scripted`), except
    /// every `missEvery`-th proposal, which is moved to the next token ID so the
    /// target rejects it. With the one-token path's own tokens as the script,
    /// the rounds accept several tokens, reject, and roll back.
    case scripted(script: [Int], missEvery: Int)
}

/// A request's speculative rounds: `depth` proposals a round at most.
struct MiMoTensorParallelSpeculation {
    let depth: Int
    let proposer: MiMoTensorParallelProposer

    init(depth: Int, proposer: MiMoTensorParallelProposer) throws {
        guard (1 ... MiMoMTPTerms.maximumDepth).contains(depth) else {
            throw ProbeError("MiMo tensor-parallel speculation drafts 1...\(MiMoMTPTerms.maximumDepth) tokens a round")
        }
        if case .scripted(let script, let missEvery) = proposer, script.isEmpty || missEvery < 0 {
            throw ProbeError("MiMo tensor-parallel scripted proposals need a script")
        }
        self.depth = depth; self.proposer = proposer
    }
}

/// One request's proposals on a rank: `MiMoMTPDecoder`'s rules (the product
/// drafter's history, priming and finalization) on the replicated heads, or a
/// scripted oracle. Proposals are evaluated before they return; with the heads
/// each is one small sum issued in the same order on every rank.
final class MiMoTensorParallelDrafter {
    private let speculation: MiMoTensorParallelSpeculation
    private let vocabularySize: Int
    private var state: (any CBv2MTPRequestState)?
    private var promptFrontier: MLXArray?
    private var carry: (token: Int, hidden: MLXArray)?
    private var fencePending = false
    private var released = false
    private(set) var statistics: MiMoMTPStatistics

    var depth: Int { speculation.depth }

    init(_ speculation: MiMoTensorParallelSpeculation, vocabularySize: Int, maximumTokens: Int) throws {
        self.speculation = speculation; self.vocabularySize = vocabularySize
        statistics = .init(depth: speculation.depth)
        if case .heads(let head) = speculation.proposer {
            guard head.assistant.maximumDraftTokens.map({ speculation.depth <= $0 }) ?? false,
                  head.assistant.maximumSpeculativeBatch == 1 else {
                throw ProbeError("MiMo speculative head cannot draft the agreed depth")
            }
            let state = head.assistant.makeRequestState()
            try head.assistant.configureRequestState(state, maximumSequenceLength: maximumTokens)
            self.state = state
        }
    }

    private func fence() throws {
        guard fencePending, case .heads(let head) = speculation.proposer, let state else { return }
        try MLX.withError { error in
            eval(head.assistant.evaluationTargets(for: state))
            try error.check()
        }
        fencePending = false
    }

    /// One prompt chunk's tokens and post-final-norm rows `[1, n, H]`.
    func observePrompt(tokens: [Int], hidden: MLXArray) throws {
        guard !released, carry == nil, !tokens.isEmpty, hidden.dim(1) == tokens.count else {
            throw ProbeError("MiMo tensor-parallel drafter observed a row outside its prompt")
        }
        guard case .heads(let head) = speculation.proposer, let state else { return }
        try fence()
        head.assistant.observeCommittedTarget(.init(tokens: MLXArray(tokens.map(Int32.init)).reshaped([1, tokens.count]),
            hidden: hidden), requestState: state)
        let last = tokens.count - 1
        promptFrontier = hidden[0..., last ..< (last + 1), 0...]
        asyncEval(head.assistant.evaluationTargets(for: state) + [promptFrontier!])
        fencePending = true
    }

    /// After the prompt and the first agreed token.
    func begin(firstToken: Int) throws {
        guard !released, carry == nil else { throw ProbeError("MiMo tensor-parallel drafter began twice") }
        if case .heads = speculation.proposer {
            guard let promptFrontier else { throw ProbeError("MiMo tensor-parallel drafter starts without a prompt") }
            try fence()
            carry = (firstToken, promptFrontier)
            self.promptFrontier = nil
        }
    }

    /// Up to `count` proposals after `lastToken`, whose output index is
    /// `nextIndex - 1`; none when the drafter has no carry (it stopped drafting).
    func draft(lastToken: Int, nextIndex: Int, count: Int) throws -> [Int] {
        guard !released, count >= 1 else { throw ProbeError("MiMo tensor-parallel drafter stepped past its request") }
        switch speculation.proposer {
        case .scripted(let script, let missEvery):
            let ids = (0 ..< count).compactMap { j -> Int? in
                guard nextIndex + j < script.count else { return nil }
                let ordinal = nextIndex + j
                let token = script[ordinal]
                return missEvery > 0 && (ordinal + 1) % missEvery == 0 ? (token + 1) % vocabularySize : token
            }
            return ids
        case .heads(let head):
            guard let state, let carry, carry.token == lastToken else { self.carry = nil; return [] }
            try fence()
            var feed = (tokens: MLXArray([Int32(lastToken)]).reshaped([1, 1]), hidden: carry.hidden)
            var drafted: [MLXArray] = []
            for _ in 0 ..< count {
                let next = head.assistant.draftStep(tokens: feed.tokens, hidden: feed.hidden, shortlist: nil,
                    requestState: state)
                let token = next.tokens.reshaped([1, 1])
                drafted.append(token)
                feed = (token, next.hidden)
            }
            let drafts = concatenated(drafted, axis: 1)
            try MLX.withError { error in
                eval([drafts] + head.assistant.evaluationTargets(for: state))
                try error.check()
            }
            let ids = drafts.asArray(Int32.self).map(Int.init)
            guard ids.count == count, ids.allSatisfy({ (0 ..< vocabularySize).contains($0) }) else {
                throw ProbeError("MiMo speculative head drafted a token outside the vocabulary")
            }
            return ids
        }
    }

    /// After both ranks kept `tokens` of a window `[last] + drafts` whose
    /// post-final-norm rows are `hidden`.
    func finalize(drafts: [Int], tokens: [Int], acceptedDrafts: Int, hidden: MLXArray) throws {
        guard !released, !tokens.isEmpty, hidden.dim(1) >= tokens.count else {
            throw ProbeError("MiMo tensor-parallel drafter finalized rows the window did not keep")
        }
        statistics.record(drafts: drafts.count, acceptedDrafts: acceptedDrafts, emitted: tokens.count)
        guard case .heads(let head) = speculation.proposer, let state else { return }
        let carryHidden = hidden[0..., (tokens.count - 1) ..< tokens.count, 0...]
        guard !drafts.isEmpty else { carry = nil; return }
        let draftArray = MLXArray(drafts.map(Int32.init)).reshaped([1, drafts.count])
        head.assistant.finalizeRound(requestState: state, confirmedInputTokens: 1 + acceptedDrafts,
            committedDraftTokens: draftArray[0..., 0 ..< acceptedDrafts],
            committedTargetHidden: hidden[0..., 0 ..< acceptedDrafts, 0...])
        try MLX.withError { error in
            eval(head.assistant.evaluationTargets(for: state) + [carryHidden])
            try error.check()
        }
        carry = (tokens[tokens.count - 1], carryHidden)
    }

    func release() {
        guard !released else { return }
        released = true
        carry = nil; promptFrontier = nil
        if case .heads(let head) = speculation.proposer, let state { head.assistant.releaseRequestState(state) }
    }

    deinit { release() }
}

extension MiMoTensorParallelRequestBudget {
    /// What speculative rounds of `depth` add to one request on a rank beside
    /// the drafter's own bounded state: each sliding layer's ring gathered
    /// once more per extra window row, one page per layer copied while a
    /// window's checkpoint holds the old one, and a window's whole rows (FP32)
    /// for its logprobs or its sampled targets, twice.
    static func speculativeWindowBytes(plan: MiMoTensorParallelPlan, slidingWindow: Int, depth: Int,
                                       allocationBound: (Int) throws -> Int) throws -> Int {
        let sum = QwenLongPrefillCheckedBytes.sum, product = QwenLongPrefillCheckedBytes.product
        guard slidingWindow > 0, (1 ... MiMoMTPTerms.maximumDepth).contains(depth) else {
            throw ProbeError("MiMo tensor-parallel speculative budget needs a window and a depth")
        }
        var total = 0
        for layer in 0 ..< plan.layerCount {
            let rowBytes = try product([plan.kvHeads(layer: layer) / plan.size,
                                        plan.headDim(layer: layer) + plan.valueHeadDim(layer: layer), 2])
            if plan.slidingLayers[layer] {
                total = try sum([total, product([allocationBound(product([slidingWindow, rowBytes])), depth])])
            }
            total = try sum([total, allocationBound(product([pageTokens, rowBytes]))])
        }
        return try sum([total, product([allocationBound(product([depth + 1, plan.vocabularySize, 4])), 2])])
    }
}
