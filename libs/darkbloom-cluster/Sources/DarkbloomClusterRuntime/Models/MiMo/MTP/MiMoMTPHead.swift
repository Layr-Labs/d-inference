import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

/// The tensors the decoding rank of `pipeline_mtp_v1` reads beside its stage,
/// by indexed name: the model's three trained next-N heads and the token
/// embedding the heads look their input tokens up in (stage 0 owns the
/// embedding; the decoding rank holds a second copy). Derived from the
/// configuration and the artifact's own headers; both ranks bind the digest
/// into their load agreement before either stage is read.
struct MiMoMTPHeadInventory {
    static let headPrefix = MiMoLayerStagePlan.sourceNamespace + "model.mtp."
    static let embeddingPrefix = MiMoLayerStagePlan.sourceNamespace + "model.embed_tokens."
    static let embeddingParts = ["weight", "scales", "biases"]

    struct Entry: Encodable, Equatable {
        let name: String
        let shape: [Int]
        let dtype: String
        let byteCount: Int
    }
    let head: [Entry]
    let embedding: [Entry]
    var entries: [Entry] { embedding + head }
    var bytes: Int { entries.reduce(0) { $0 + $1.byteCount } }
    let sha256: String

    /// `headers`: every indexed tensor's name, shape, stored dtype and bytes.
    init(configuration: Data, headers: [Entry]) throws {
        guard let root = try JSONSerialization.jsonObject(with: configuration) as? [String: Any],
              let layers = BoundedProbeInput.integer(root["num_nextn_predict_layers"]),
              layers == MiMoMTPTerms.maximumDepth else {
            throw ProbeError("MiMo speculative decoding needs the artifact's three trained next-N heads")
        }
        let byName = Dictionary(headers.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        guard byName.count == headers.count else { throw ProbeError("MiMo tensor headers repeat a name") }
        let head = headers.filter { $0.name.hasPrefix(Self.headPrefix) }.sorted { $0.name < $1.name }
        let embedding = try Self.embeddingParts.map { part in
            guard let entry = byName[Self.embeddingPrefix + part] else {
                throw ProbeError("MiMo artifact has no packed token embedding \(part)")
            }
            return entry
        }
        // One set of tensors per declared head, each under `model.mtp.layers.<i>.`.
        let perHead = (0..<layers).map { index in head.filter { $0.name.hasPrefix(Self.headPrefix + "layers.\(index).") }.count }
        guard !head.isEmpty, perHead.allSatisfy({ $0 > 0 && $0 == perHead[0] }), perHead.reduce(0, +) == head.count,
              head.allSatisfy({ $0.dtype == "BF16" && $0.byteCount > 0 }),
              embedding[0].dtype == "U32", embedding[1].dtype == "BF16", embedding[2].dtype == "BF16" else {
            throw ProbeError("MiMo speculative head tensors are not three unpacked bfloat16 heads beside a packed embedding")
        }
        self.head = head; self.embedding = embedding
        sha256 = DarkbloomClusterRuntime.sha256(try canonicalJSONData(["mimo-speculative-head-tensors-v1"]
            + (embedding + head).map { "\($0.name)|\($0.dtype)|\($0.shape)|\($0.byteCount)" }))
    }
}

/// The product's MiMo next-N heads and drafter (`MiMoV26MTP`,
/// `MiMoV26MTPAssistant`, unchanged) on the decoding rank of a pipeline: the
/// rank whose stage holds the final norm and the output head.
///
/// The heads borrow their target's token embedding and output head. Their
/// target here is a shell `MiMoV26TextModel` that holds no layer of its own
/// that is ever evaluated: its output head is the consumer stage's own module
/// (shared, no copy) and its embedding is the artifact's packed embedding,
/// read a second time. Every tensor is read through this rank's verified
/// checkpoint (pinned descriptors of files hashed against the manifest at
/// load), one aligned uncached read each, behind the host memory gate.
final class MiMoMTPHead {
    struct Receipt: Encodable, Equatable {
        let headTensors: Int
        let headBytes: Int
        let embeddingBytes: Int
        let activeBytesAdded: Int
        let loadNanoseconds: UInt64
        let inventorySHA256: String
    }

    let assistant: MiMoV26MTPAssistant
    let receipt: Receipt
    let inventory: MiMoMTPHeadInventory
    let vocabularySize: Int
    private let shell: MiMoV26TextModel
    private let predictor: MiMoV26MTP

    /// The head's tensors from this rank's verified source, by name; no payload.
    static func inventory(source: MiMoResidentSource) throws -> (MiMoMTPHeadInventory, [String: TensorDescriptor]) {
        let indexed = try tensorDescriptors(checkpoint: source.checkpoint,
            scope: .init(acceptsUInt8: true, indexedShardsOnly: true))
        let headers = try indexed.map { name, tensor in
            MiMoMTPHeadInventory.Entry(name: name, shape: tensor.shape, dtype: try tensor.storedDTypeName,
                byteCount: tensor.byteCount)
        }
        return (try MiMoMTPHeadInventory(configuration: source.plan.originalConfiguration, headers: headers), indexed)
    }

    init(source: MiMoResidentSource, consumer: LoadedMiMoLayerStage, check: () throws -> Void) throws {
        guard consumer.stageIndex == 1, consumer.plan.fingerprint == source.plan.fingerprint,
              consumer.receipt.verifiedAggregateSHA256 == source.checkpoint.aggregate else {
            throw ProbeError("The speculative head loads beside the consumer stage of the same verified source")
        }
        let started = DispatchTime.now().uptimeNanoseconds
        Stream.gpu.synchronize()
        let before = Memory.snapshot().activeMemory
        let (inventory, descriptors) = try Self.inventory(source: source)
        self.inventory = inventory
        vocabularySize = source.specification.vocabulary
        guard let policy = source.profile.quantization[MiMoLayerStagePlan.sourceNamespace + "model.embed_tokens"],
              policy.mode == "affine", policy.bits == 8, policy.groupSize == 64 else {
            throw ProbeError("MiMo token embedding is not the 8-bit affine table the heads read")
        }
        let head: Linear = try Self.module(consumer.model, "lm_head")
        try check()

        // The heads' target: the source configuration with one (never
        // evaluated) layer, the trained heads declared and the quantization
        // metadata kept, so the product's predictor checks its policy itself.
        guard var root = try JSONSerialization.jsonObject(with: source.plan.originalConfiguration) as? [String: Any] else {
            throw ProbeError("MiMo speculative head needs the artifact's configuration object")
        }
        root["num_hidden_layers"] = 1
        root["hybrid_layer_pattern"] = [0]
        root["moe_layer_freq"] = [0]
        for key in ["vision_config", "audio_config", "processor_config", "omlx_mimo_mtp"] { root[key] = nil }
        let configuration = try JSONDecoder().decode(MiMoV26Configuration.self,
            from: try JSONSerialization.data(withJSONObject: root))
        let shell = try withRandomState(MLXRandom.RandomState(seed: 7)) { try MiMoV26TextModel(configuration) }
        let lazy: Embedding = try Self.module(shell, "model.embed_tokens")
        guard let packed = quantizeSingle(layer: lazy, groupSize: 64, bits: 8, mode: .affine) as? QuantizedEmbedding else {
            throw ProbeError("MiMo token embedding cannot take its packed layout")
        }
        try check()

        let gate = try MiMoMTPHeadLoadGate(entries: inventory.entries)
        func read(_ entry: MiMoMTPHeadInventory.Entry) throws -> MLXArray {
            guard let descriptor = descriptors[entry.name] else { throw ProbeError("Verified MiMo head descriptor disappeared") }
            try gate.beforeRead(entry)
            let value = try descriptor.read(.all)
            guard let accounting = value.readAccounting, accounting.selectedBytes == value.copiedBytes else {
                throw ProbeError("MiMo head aligned read accounting is incomplete")
            }
            let array = value.array
            eval(array)
            Stream.gpu.synchronize()
            try check()
            guard array.shape == entry.shape, array.nbytes == entry.byteCount, value.copiedBytes == entry.byteCount,
                  let buffer = try array.evaluatedBufferInfo(), buffer.isUnique, buffer.dataOffset == 0,
                  buffer.isRowContiguous, buffer.dataElements == array.size else {
                throw ProbeError("MiMo head tensor is not an exact, independently owned compact allocation: \(entry.name)")
            }
            return array
        }
        var table: [String: MLXArray] = [:]
        for entry in inventory.embedding {
            try autoreleasepool { table[String(entry.name.dropFirst(MiMoMTPHeadInventory.embeddingPrefix.count))] = try read(entry) }
        }
        try packed.update(parameters: ModuleParameters.unflattened(table), verify: [.noUnusedKeys, .shapeMismatch])
        try shell.update(modules: ModuleChildren.unflattened([
            ("model.embed_tokens", packed as Module), ("lm_head", head as Module),
        ]), verify: [.noUnusedKeys])
        let shellModules = Dictionary(uniqueKeysWithValues: shell.namedModules())
        guard shellModules["model.embed_tokens"] === packed, shellModules["lm_head"] === head else {
            throw ProbeError("MiMo speculative head target does not hold the read embedding and the stage's head")
        }
        // Unquantized trained heads beside an affine 4-bit trunk default.
        let predictor = try MiMoV26MTP(target: shell, floatingProjections: true)
        var weights: [String: MLXArray] = [:]
        for entry in inventory.head {
            try autoreleasepool { weights[String(entry.name.dropFirst(MiMoMTPHeadInventory.headPrefix.count))] = try read(entry) }
        }
        try predictor.loadConvertedWeights(weights, prefix: "")
        try gate.finish()
        predictor.freeze()
        try source.checkpoint.checkUnchanged()
        try check()
        self.shell = shell; self.predictor = predictor
        assistant = try MiMoV26MTPAssistant(target: shell, predictor: predictor, retaining: nil,
            verificationMode: .rectangular)
        Stream.gpu.synchronize()
        let after = Memory.snapshot().activeMemory
        receipt = .init(headTensors: inventory.head.count, headBytes: inventory.head.reduce(0) { $0 + $1.byteCount },
            embeddingBytes: inventory.embedding.reduce(0) { $0 + $1.byteCount },
            activeBytesAdded: after > before ? after - before : 0,
            loadNanoseconds: DispatchTime.now().uptimeNanoseconds - started, inventorySHA256: inventory.sha256)
    }

    /// One request's state of the drafter, at the allocator's bound: the
    /// product's own bounded declaration for this head (`maximumPrefillTokens`
    /// is the request's chunk), resident plus working buffers plus host bytes.
    func requestBytes(chunkSize: Int, depth: Int, bound: (Int) throws -> Int) throws -> Int {
        guard let spec = assistant.boundedRequestAllocation(limits: .init(maximumPrefillTokens: chunkSize,
                  maximumDraftTokens: depth)) else {
            throw ProbeError("MiMo speculative head declares no bounded request allocation")
        }
        var total = spec.hostBytes
        for buffer in spec.resident + spec.working {
            total = try QwenLongPrefillCheckedBytes.sum([total,
                try QwenLongPrefillCheckedBytes.product([try bound(buffer.logicalBytes), buffer.allocationCount])])
        }
        return total
    }

    private static func module<T>(_ model: Module, _ path: String) throws -> T {
        guard let value = Dictionary(uniqueKeysWithValues: model.namedModules())[path] as? T else {
            throw ProbeError("MiMo model has no \(path) of the expected kind")
        }
        return value
    }
}

/// The head's ordered resource gate, as a stage load's: before each tensor is
/// read, the host memory policy is asked for everything still to come plus
/// two host copies of the largest, the read scratch and the loading headroom,
/// and the allocator limit is checked.
private final class MiMoMTPHeadLoadGate {
    private let entries: [MiMoMTPHeadInventory.Entry], bounds: [Int], host: Int
    private var next = 0
    private var failed = false
    private let watch = QwenDenseStageLoadWatch("Speculative head load")

    init(entries: [MiMoMTPHeadInventory.Entry]) throws {
        self.entries = entries
        host = entries.map(\.byteCount).max() ?? 0
        bounds = try entries.map { try Memory.allocationFootprintUpperBound(byteCount: $0.byteCount) }
        let maximum = GPU.deviceInfo().maxBufferSize
        guard !entries.isEmpty, host > 0, maximum > 0, bounds.allSatisfy({ $0 > 0 && $0 <= maximum }) else {
            throw ProbeError("MiMo head buffers exceed actual device bounds")
        }
        try observe()
    }

    private func observe() throws {
        do {
            guard !failed else { throw ProbeError("MiMo head load gate was poisoned") }
            let remaining = try QwenLongPrefillCheckedBytes.sum(Array(bounds.dropFirst(next)))
            let h = next < entries.count ? host : 0
            let scratch = h == 0 ? 0 : CheckpointAlignedReadPlan.maximumScratchAllocationBytes
            let required = max(QwenDenseStageLoadPolicy.minimumAdmissibleBytes,
                try QwenLongPrefillCheckedBytes.sum([remaining, h, h, scratch, QwenDenseStageLoadPolicy.loadingHeadroomBytes]))
            let allocator = try QwenLongPrefillCheckedBytes.sum([Memory.activeMemory, Memory.cacheMemory,
                remaining, h, QwenDenseStageLoadPolicy.allocatorHeadroomBytes])
            let os = try QwenDenseStageLoadResources.observeOS()
            guard try watch.admits(os, bytes: required) else { throw ProbeError("MiMo speculative head load was refused") }
            guard Memory.memoryLimit >= allocator else {
                throw ProbeError("MiMo speculative head load exceeds the allocator limit: needs \(allocator) of \(Memory.memoryLimit) bytes")
            }
        } catch { failed = true; throw error }
    }

    func beforeRead(_ entry: MiMoMTPHeadInventory.Entry) throws {
        guard entries.indices.contains(next), entries[next] == entry else {
            failed = true; throw ProbeError("MiMo head load changed its admitted ordered tensor inventory")
        }
        try observe()
        next += 1
    }

    func finish() throws {
        guard next == entries.count else { failed = true; throw ProbeError("MiMo head load incomplete") }
        try observe()
    }
}
