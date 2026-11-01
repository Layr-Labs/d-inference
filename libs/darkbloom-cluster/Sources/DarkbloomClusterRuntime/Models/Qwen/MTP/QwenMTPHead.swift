import CryptoKit
import Darwin
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

/// What a speculative head adds to the decoding rank's named storage for one
/// request, at the allocator's bound. The head's weights are resident like
/// the stages' and are charged once at load; this is per request.
struct QwenMTPAllowance: Encodable, Equatable {
    let extraNativeBytes: Int
    let extraHostBytes: Int

    static func derive(geometry: QwenLongPrefillBudgetGeometry, depth: Int, maximumTokens: Int, promptTokens: Int,
                       chunkSize: Int, vocabularySize: Int, bound: (Int) throws -> Int) throws -> Self {
        guard (1...QwenMTPTerms.maximumDepth).contains(depth), maximumTokens > 0, promptTokens > 0,
              promptTokens <= maximumTokens, chunkSize > 0, vocabularySize > 0 else {
            throw ProbeError("Invalid speculative head allowance geometry")
        }
        let sum = QwenLongPrefillCheckedBytes.sum, product = QwenLongPrefillCheckedBytes.product
        func rounded(_ bytes: Int) throws -> Int {
            guard bytes > 0 else { return 0 }
            let value = try bound(bytes)
            guard value >= bytes else { throw ProbeError("Speculative head allocator bound is too small") }
            return value
        }
        let width = depth + 1
        // The head's own one-layer KV, in its 256-token allocation steps.
        let headTokens = ((maximumTokens + 4 + 255) / 256) * 256
        let headKV = try product([2, geometry.kvHeads, geometry.headDimension, 2, headTokens])
        // The prompt's normalized hidden rows queued for the first round, and
        // one chunk of tapped rows while it is observed.
        let queued = try product([promptTokens, geometry.hiddenSize, 2])
        // The compact copy of that history kept for the prefix cache's
        // entries of this prompt (`QwenMTPDecoder.begin`).
        let kept = try product([promptTokens, geometry.hiddenSize, 2])
        let tapped = try product([min(chunkSize, promptTokens), geometry.hiddenSize, 2])
        // One verify window: logits, both stages' residual and hidden rows, and
        // every recurrent layer's state captured at each of its positions.
        let budget = try QwenLongPrefillTensorBudget.estimate(geometry: geometry,
            maximumTokens: maximumTokens, chunkSize: min(chunkSize, maximumTokens))
        let logits = try product([width, vocabularySize, 4])
        let rows = try product([3, width, geometry.hiddenSize, 4])
        let captured = try product([width, geometry.recurrentLayers,
            try sum([budget.convolutionBytesPerLayer, budget.ssmBytesPerLayer])])
        let native = try sum([try rounded(headKV), try rounded(queued), try rounded(kept), try rounded(tapped), try rounded(logits),
            try rounded(rows), try rounded(captured)])
        // Host copies: the window's argmax, drafts and per-token residual rows.
        let host = try sum([try product([width, geometry.hiddenSize, 2]), 4096])
        return .init(extraNativeBytes: native, extraHostBytes: host)
    }
}

/// Per draft position, how often a round reached it and how often its draft
/// was the target's own token; and where a round's time went.
struct QwenMTPStatistics: Encodable, Equatable {
    var depth: Int
    var rounds = 0
    var plainSteps = 0
    var emittedTokens = 0
    var examinedByPosition: [Int]
    var acceptedByPosition: [Int]
    var buildNanoseconds: UInt64 = 0
    var evaluateNanoseconds: UInt64 = 0
    var settleNanoseconds: UInt64 = 0
    /// Prompt positions whose head history was restored from a prefix entry
    /// instead of observed in this request (0: the head saw only this
    /// request's computed rows).
    var restoredHistoryTokens = 0
    /// `pipeline_mtp_v1`, the last rank: time spent waiting for rank 0's
    /// window rows, verifying them, and keeping the round (both stages and
    /// the head). Nil under a phase split, whose line stays as it was.
    var pipelineNanoseconds: PipelineTimes?

    struct PipelineTimes: Encodable, Equatable {
        var wait: UInt64 = 0
        var verify: UInt64 = 0
        var settle: UInt64 = 0
    }

    init(depth: Int) {
        self.depth = depth
        examinedByPosition = Array(repeating: 0, count: depth)
        acceptedByPosition = Array(repeating: 0, count: depth)
    }

    var drafted: Int { examinedByPosition.reduce(0, +) }
    var accepted: Int { acceptedByPosition.reduce(0, +) }

    /// One line a launcher can read from the worker's diagnostics.
    var diagnosticFields: [String] {
        ["mtp_depth=\(depth)", "mtp_rounds=\(rounds)", "mtp_plain_steps=\(plainSteps)",
         "mtp_emitted=\(emittedTokens)", "mtp_drafted=\(drafted)", "mtp_accepted=\(accepted)",
         "mtp_examined_by_position=" + examinedByPosition.map(String.init).joined(separator: "-"),
         "mtp_accepted_by_position=" + acceptedByPosition.map(String.init).joined(separator: "-"),
         "mtp_build_ns=\(buildNanoseconds)", "mtp_evaluate_ns=\(evaluateNanoseconds)", "mtp_settle_ns=\(settleNanoseconds)",
         "mtp_history_restored=\(restoredHistoryTokens)"]
            + (pipelineNanoseconds.map { ["mtp_wait_ns=\($0.wait)", "mtp_verify_ns=\($0.verify)",
                                          "mtp_round_settle_ns=\($0.settle)"] } ?? [])
    }

}

/// How the consumer stage of a decoding rank yields its pre-norm hidden rows.
/// The stage's own modules are used as they are: the residual enters where the
/// token lookup would, and the prompt's last row is projected by the stage's
/// own final norm and head.
struct QwenLayerStageHiddenTap {
    let embedding: QwenStageResidualEmbedding
    let norm: RMSNorm
    let head: Linear
    /// Called once per committed prompt chunk, in order.
    let observe: (_ tokens: MLXArray, _ hidden: MLXArray) throws -> Void

    func hidden(of model: any LanguageModel, tokens: MLXArray, residual: MLXArray,
                caches: [any CBv2AttendingLayerCache], evaluation: CBv2RecurrentStateEvaluation,
                captured: Bool) throws -> (logits: MLXArray, hidden: MLXArray) {
        let attention = caches.map { $0 as! any KVCache }
        if captured {
            guard let native = model as? any CBv2RecurrentCaptureMTPForwardable else {
                throw ProbeError("Consumer stage has no captured-window forward")
            }
            let result = embedding.withResidual(residual) {
                native.cbv2ForwardWithHiddenCaptured(tokens, caches: attention,
                    recurrentState: [evaluation], positionIds: nil)
            }
            return (result.logits, result.lastHidden)
        }
        guard let native = model as? any CBv2RecurrentMTPForwardable else {
            throw ProbeError("Consumer stage has no hidden-returning forward")
        }
        let result = embedding.withResidual(residual) {
            native.cbv2ForwardWithHidden(tokens, caches: attention, recurrentState: [evaluation], positionIds: nil)
        }
        // The full-window logits of this call are never evaluated.
        return (result.logits, result.lastHidden)
    }

    /// The expression the stage's own prompt entry uses for its last row.
    func lastRowLogits(_ hidden: MLXArray) -> MLXArray {
        head(norm(hidden[0..., -1, 0...]))
    }
}

/// The product's speculative head for a registered Qwen model, bound to the two
/// resident stages of one process. The head's own tensors are the only new
/// storage: its target is a layerless model whose embedding is the producer
/// stage's embedding module and whose final norm and output head are the
/// consumer stage's.
///
/// The head is read by the SDK's own loader, by path, after the artifact was
/// verified; it does not pass through this runtime's verified reader. The files
/// that loader read are hashed again afterwards and must still be the
/// manifest's. That closes a replacement that persists, not one that is undone
/// between the two readings.
final class QwenMTPHead {
    struct Receipt: Encodable, Equatable {
        let tensorFiles: [String]
        let tensorFileBytes: Int
        let filesRehashedAfterLoad: [String]
        let activeBytesAdded: Int
        let loadNanoseconds: UInt64
        let blockSize: Int
        /// `pipeline_mtp_v1`: bytes of the token embedding copy this rank read
        /// beside its stage (0 under a phase split, which borrows the producer's).
        var embeddingCopyBytes = 0
    }

    let assistant: Qwen35InlineMTPAssistant
    let receipt: Receipt
    /// `QwenMTPHeadFiles.sha256` of the files this head was read from.
    let headSHA256: String
    private let shell: Qwen35TextModel
    private let consumerEmbedding: QwenStageResidualEmbedding
    private let consumerNorm: RMSNorm
    private let consumerHead: Linear

    /// Phase split: the decoding rank holds both stages; the head borrows the
    /// producer stage's own embedding module.
    convenience init(modelDirectory: URL, sourceConfiguration: Data, manifest: Data,
         producer: LoadedQwenLayerStage, consumer: LoadedQwenLayerStage, check: () throws -> Void) throws {
        guard producer.stageIndex == 0, consumer.stageIndex == 1,
              producer.plan.fingerprint == consumer.plan.fingerprint,
              sha256(sourceConfiguration) == producer.receipt.sourceConfigurationSHA256,
              producer.receipt.verifiedAggregateSHA256 == consumer.receipt.verifiedAggregateSHA256 else {
            throw ProbeError("Speculative head needs both stages of one verified source")
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let before = Memory.snapshot().activeMemory
        let embedding: Embedding = try Self.module(producer.model, "model.embed_tokens")
        guard !(embedding is QwenStageResidualEmbedding) else {
            throw ProbeError("Producer stage has no token embedding")
        }
        try self.init(modelDirectory: modelDirectory, sourceConfiguration: sourceConfiguration, manifest: manifest,
            embedding: embedding, embeddingCopyBytes: 0, consumer: consumer, started: started, before: before, check: check)
    }

    /// `pipeline_mtp_v1`: the last rank holds only the consumer stage. The
    /// head's target embedding is a copy of the producer stage's token
    /// embedding, read through this rank's verified checkpoint with the stage
    /// (`QwenEmbeddingCopy`); final norm and output head are the consumer's.
    convenience init(modelDirectory: URL, sourceConfiguration: Data, manifest: Data,
         embeddingCopy: QwenEmbeddingCopy, consumer: LoadedQwenLayerStage, check: () throws -> Void) throws {
        guard consumer.stageIndex == 1, sha256(sourceConfiguration) == consumer.receipt.sourceConfigurationSHA256,
              embeddingCopy.verifiedAggregateSHA256 == consumer.receipt.verifiedAggregateSHA256,
              embeddingCopy.planFingerprint == consumer.plan.fingerprint else {
            throw ProbeError("Speculative head needs the consumer stage and an embedding copy of one verified source")
        }
        try self.init(modelDirectory: modelDirectory, sourceConfiguration: sourceConfiguration, manifest: manifest,
            embedding: embeddingCopy.module, embeddingCopyBytes: embeddingCopy.bytes, consumer: consumer,
            started: embeddingCopy.startedUptimeNanoseconds, before: embeddingCopy.activeBytesBefore, check: check)
    }

    private init(modelDirectory: URL, sourceConfiguration: Data, manifest: Data, embedding: Embedding,
                 embeddingCopyBytes: Int, consumer: LoadedQwenLayerStage, started: UInt64, before: Int,
                 check: () throws -> Void) throws {
        consumerEmbedding = try Self.module(consumer.model, "model.embed_tokens")
        consumerNorm = try Self.module(consumer.model, "model.norm")
        consumerHead = try Self.module(consumer.model, "lm_head")

        guard let root = try JSONSerialization.jsonObject(with: sourceConfiguration) as? [String: Any] else {
            throw ProbeError("Speculative head needs the artifact's configuration object")
        }
        var text = root["text_config"] as? [String: Any] ?? root
        // No layer of its own: only what the head borrows from its target.
        text["num_hidden_layers"] = 0
        text["layer_types"] = [String]()
        text["mtp_num_hidden_layers"] = 0
        let shell = Qwen35TextModel(try JSONDecoder().decode(Qwen35TextConfiguration.self,
            from: try JSONSerialization.data(withJSONObject: text)))
        try shell.update(modules: ModuleChildren.unflattened([
            ("model.embed_tokens", embedding as Module), ("lm_head", consumerHead as Module),
        ]), verify: [.noUnusedKeys])
        let shellNorm: RMSNorm = try Self.module(shell, "model.norm")
        try shellNorm.update(parameters: ModuleParameters.unflattened(["weight": consumerNorm.weight]),
            verify: [.noUnusedKeys, .shapeMismatch])
        let modules = Dictionary(uniqueKeysWithValues: shell.namedModules())
        guard modules["model.embed_tokens"] === embedding, modules["lm_head"] === consumerHead,
              shellNorm.weight.shape == consumerNorm.weight.shape else {
            throw ProbeError("Speculative head target does not share the stages' modules")
        }
        self.shell = shell
        try check()

        // What the SDK loader is about to read, by the manifest that was verified.
        let files = try QwenMTPHeadFiles(modelDirectory: modelDirectory, manifest: manifest)
        let shards = files.shards, shardBytes = files.shardBytes, indexName = QwenMTPHeadFiles.indexName
        let pinned = files.pinned
        assistant = try MLX.withError { error in
            let value = try Qwen35InlineMTPAssistant.load(from: modelDirectory, target: shell)
            try error.check()
            return value
        }
        try check()
        let reread = ["config.json", indexName] + shards
        for name in reread {
            let entry = pinned[name]!
            guard try Self.fileSHA256(modelDirectory.appendingPathComponent(name), expectedSize: entry.size_bytes) == entry.sha256 else {
                throw ProbeError("Speculative head file differs from the verified manifest: \(name)")
            }
            try check()
        }
        Stream.gpu.synchronize()
        let after = Memory.snapshot().activeMemory
        headSHA256 = files.sha256
        receipt = .init(tensorFiles: shards, tensorFileBytes: shardBytes, filesRehashedAfterLoad: reread,
            activeBytesAdded: after > before ? after - before : 0,
            loadNanoseconds: DispatchTime.now().uptimeNanoseconds - started, blockSize: assistant.blockSize,
            embeddingCopyBytes: embeddingCopyBytes)
    }

    func tap(observe: @escaping (_ tokens: MLXArray, _ hidden: MLXArray) throws -> Void) -> QwenLayerStageHiddenTap {
        .init(embedding: consumerEmbedding, norm: consumerNorm, head: consumerHead, observe: observe)
    }

    private static func module<T>(_ model: Module, _ suffix: String) throws -> T {
        let matches = model.namedModules().filter { $0.0 == suffix || $0.0.hasSuffix("." + suffix) }
        guard matches.count == 1, let value = matches[0].1 as? T else {
            throw ProbeError("Stage has no single \(suffix) of the expected kind")
        }
        return value
    }

    private static func module<T>(_ model: any LanguageModel, _ suffix: String) throws -> T {
        try module(model as Module, suffix)
    }

    /// Read with caching off, as the artifact's own verification asks.
    private static func fileSHA256(_ url: URL, expectedSize: Int) throws -> String {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ProbeError("Cannot reopen \(url.lastPathComponent)") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Int(info.st_size) == expectedSize else {
            throw ProbeError("Speculative head file size or type changed: \(url.lastPathComponent)")
        }
        _ = fcntl(descriptor, F_NOCACHE, 1)
        var hasher = SHA256()
        let capacity = 4 * 1_048_576
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16_384)
        defer { buffer.deallocate() }
        var total = 0
        while true {
            let count = read(descriptor, buffer, capacity)
            guard count >= 0 else { throw ProbeError("Cannot read \(url.lastPathComponent)") }
            if count == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
            total += count
        }
        guard total == expectedSize else { throw ProbeError("Short read of \(url.lastPathComponent)") }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// The head's tensor files as the verified manifest names them, found through
/// the artifact's own weight index. Reading this allocates nothing on the GPU;
/// both ranks derive the digest before either stage is read.
struct QwenMTPHeadFiles {
    static let indexName = "model.safetensors.index.json"
    static let maximumShardBytes = 8_589_934_592
    let shards: [String]
    let shardBytes: Int
    let tensorCount: Int
    let pinned: [String: CheckpointManifest.Entry]
    /// Binds the shard names, their manifest digests and sizes, and the
    /// indexed tensor names of the head.
    let sha256: String

    init(modelDirectory: URL, manifest: Data) throws {
        let entries = try JSONDecoder().decode(CheckpointManifest.self, from: manifest).files
        var pinned: [String: CheckpointManifest.Entry] = [:]
        for entry in entries { pinned[entry.path] = entry }
        struct Index: Decodable { let weight_map: [String: String] }
        let index = try JSONDecoder().decode(Index.self,
            from: try BoundedProbeInput.data(modelDirectory.appendingPathComponent(Self.indexName), maximumBytes: 8_388_608))
        let tensors = index.weight_map.filter { $0.key.hasPrefix("mtp.") }
        let shards = Set(tensors.values).sorted()
        guard !shards.isEmpty, shards.count <= 4, (1...512).contains(tensors.count),
              shards.allSatisfy({ $0 == URL(fileURLWithPath: $0).lastPathComponent && $0.hasSuffix(".safetensors")
                  && pinned[$0] != nil }),
              pinned[Self.indexName] != nil, pinned["config.json"] != nil else {
            throw ProbeError("Artifact declares no speculative head inside its verified manifest")
        }
        let shardBytes = shards.reduce(0) { $0 + (pinned[$1]?.size_bytes ?? 0) }
        // The bound is on what the re-hash after load reads again: a head in a
        // shard of its own (9B, 27B, 3.5 35B A3B), or in the last shard it
        // shares with the trunk (Qwen3.6 35B A3B: 5,256,335,788 bytes).
        guard shardBytes > 0, shardBytes <= Self.maximumShardBytes else {
            throw ProbeError("Speculative head files exceed the bound for a head")
        }
        self.shards = shards; self.shardBytes = shardBytes; self.tensorCount = tensors.count; self.pinned = pinned
        let material: [String] = ["qwen-speculative-head-files-v1"]
            + shards.map { "\($0)|\(pinned[$0]!.sha256)|\(pinned[$0]!.size_bytes)" }
            + tensors.keys.sorted().map { "\($0)|\(tensors[$0]!)" }
        sha256 = DarkbloomClusterRuntime.sha256(try canonicalJSONData(material))
    }
}
