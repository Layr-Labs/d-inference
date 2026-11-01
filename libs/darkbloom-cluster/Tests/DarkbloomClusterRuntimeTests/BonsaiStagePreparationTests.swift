import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

// Everything the verified loader does for a Bonsai stage before it reads a
// tensor, on the registered configuration, manifest and tensor inventory: the
// registered source checks over the SDK's product class, both stages' models
// with their placeholders and packed shells, the registered stage validation
// and the storage commitment. Then one token through each prepared stage as a
// graph. No weight is read and nothing is evaluated. The transforms are all
// +1 signs: the real ones are checked against the artifact's sign tensors by
// the file-backed loader, which needs the artifact and runs in the stage check.

@Suite("Bonsai source and stage preparation (registered metadata, lazy shells, nothing evaluated)")
struct BonsaiStagePreparationTests {
    private typealias F = BonsaiFixture

    private struct Stored: QwenStoredTensorDescribing {
        let shape: [Int], dtype: DType, byteCount: Int
        let storedFile: String, storedOffset: Int
    }

    /// The inventory as stored descriptors, at invented offsets in name order.
    private static func descriptors() -> [String: Stored] {
        var offset = 400_000, result: [String: Stored] = [:]
        for tensor in F.inventory() {
            let dtype: DType = tensor.sourceDType == "U32" ? .uint32 : tensor.sourceDType == "F16" ? .float16 : .float32
            result[tensor.name] = Stored(shape: tensor.shape, dtype: dtype, byteCount: tensor.byteCount,
                                         storedFile: "model.safetensors", storedOffset: offset)
            offset += tensor.byteCount
        }
        return result
    }

    private static func prism() throws -> QwenPrismHadamardSource {
        var packed: [String: QwenPrismHadamardSource.Packed] = [:]
        for tensor in F.inventory() where tensor.name.hasSuffix(".scales") {
            let module = String(tensor.name.dropLast(".scales".count))
            packed[module] = .init(rows: tensor.shape[0], width: tensor.shape[1] * 128,
                                   embedding: module.hasSuffix("model.embed_tokens"))
        }
        return .init(transforms: try BonsaiLazyForward.transforms(), packed: packed,
                     signTensorCount: packed.count, signTensorBytes: packed.values.reduce(0) { $0 + $1.width * 4 })
    }

    /// The registered source checks, with descriptors that have no file.
    private static func source(_ admission: QwenResidentAdmission,
                               descriptors: [String: Stored]? = nil, prism: QwenPrismHadamardSource?? = nil) throws -> QwenResidentSource {
        let spec = admission.specification
        let stored = descriptors ?? Self.descriptors()
        let transforms = try prism ?? Self.prism()
        return try prepareQwenResidentMetadata(admission,
            artifact: .init(aggregateSHA256: spec.artifactSHA256, configurationSHA256: sha256(admission.configBytes),
                            verifiedManifestSHA256: sha256(admission.manifestBytes)),
            check: {}, confirmUnchanged: {}) { model, policy in
                try PreparedQwenCheckpoint(model: model, descriptors: stored, policy: policy, prism: transforms)
            }.source
    }

    @Test func theRegisteredSourceIsAdmittedInItsOwnDTypes() throws {
        let admission = try F.admit(cut: 24)
        let prepared = try Self.source(admission)
        let source = prepared.source
        #expect(prepared.profile.model == .ternaryBonsai2TwentySevenB)
        // Observed from the SDK's description of the stored layout: not the scales' F16.
        #expect(source.activationDType == .float32 && source.prism != nil)
        #expect(!source.bf16ConversionEnabled && source.hiddenSize == 5120 && source.vocabularySize == 248_320)
        #expect(source.tensors.count == 1655 && source.sourceTensorCount == 1655)
        #expect(source.sourceBytes == 7_662_073_856 && source.largestSourceBytes == 317_849_600)
        // Nothing is converted on load: every tensor keeps its stored dtype.
        #expect(source.tensors.allSatisfy { $0.sourceDType == $0.loadedDType })
        #expect(Set(source.tensors.map(\.loadedDType)) == ["uint32", "float16", "float32"])
        #expect(source.quantization.count == 402
            && source.quantization.values.allSatisfy { $0.bits == 2 && $0.groupSize == 128 && $0.mode == .affine })
        #expect(source.mappings.count == 1655)
        #expect(prepared.pairRequirement.fusionReplacementBytes == 0)
    }

    @Test func aSourceThatIsNotTheRegisteredPackIsRefused() throws {
        let admission = try F.admit(cut: 24)
        // A Prism pack without its verified transforms, and the reverse.
        #expect(throws: (any Error).self, "no transform metadata") {
            _ = try Self.source(admission, prism: .some(nil))
        }
        // A sign tensor left among the descriptors is not a model parameter.
        var withSigns = Self.descriptors()
        withSigns[F.signNames()[0]] = Stored(shape: [5120], dtype: .float32, byteCount: 20480,
                                             storedFile: "model.safetensors", storedOffset: 8)
        #expect(throws: (any Error).self, "a sign tensor as a descriptor") { _ = try Self.source(admission, descriptors: withSigns) }
        // Scales stored BF16, or a norm stored F16, is a different pack: the
        // inventory no longer hashes to the pinned one.
        var converted = Self.descriptors()
        let scales = "language_model.model.layers.0.mlp.up_proj.scales"
        converted[scales] = Stored(shape: converted[scales]!.shape, dtype: .bfloat16, byteCount: converted[scales]!.byteCount,
                                   storedFile: "model.safetensors", storedOffset: converted[scales]!.storedOffset)
        #expect(throws: (any Error).self, "BF16 scales") { _ = try Self.source(admission, descriptors: converted) }
        var narrowed = Self.descriptors()
        let norm = "language_model.model.layers.0.input_layernorm.weight"
        narrowed[norm] = Stored(shape: [5120], dtype: .float16, byteCount: 10240,
                                storedFile: "model.safetensors", storedOffset: narrowed[norm]!.storedOffset)
        #expect(throws: (any Error).self, "an F16 norm") { _ = try Self.source(admission, descriptors: narrowed) }
        // A packed module the transforms do not cover.
        var missing = try Self.prism()
        var packed = missing.packed
        packed["language_model.lm_head"] = nil
        missing = .init(transforms: missing.transforms, packed: packed, signTensorCount: 401, signTensorBytes: 0)
        #expect(throws: (any Error).self, "an undeclared packed module") { _ = try Self.source(admission, prism: .some(missing)) }
    }

    @Test(arguments: [24, 28])
    func bothStagesPrepareWithTheirOwnPackedModulesAndOneCommitment(cut: Int) throws {
        var commitments: [String] = []
        // Each rank inspects the other stage, then prepares its own.
        for rank in 0...1 {
            let admission = try F.admit(rank: rank, cut: cut)
            let prepared = try Self.source(admission)
            let plan = admission.plan
            let other = try inspectOtherQwenLayerStage(source: prepared.source, stage: plan.stages[1 - rank], check: {})
            try QwenDenseObservedStageValidation.validateRegistered(source: prepared.validation, profile: prepared.profile,
                requirement: prepared.pairRequirement, plan: plan, stageIndex: 1 - rank,
                active: other.active, inert: other.inert, summary: other.summary)
            let own = try prepareQwenLayerStageModel(source: prepared.source, stage: plan.stages[rank], check: {})
            try QwenDenseObservedStageValidation.validateRegistered(source: prepared.validation, profile: prepared.profile,
                requirement: prepared.pairRequirement, plan: plan, stageIndex: rank,
                active: own.inventory.active, inert: own.inventory.inert, summary: own.inventory.summary)
            let commitment = try qwenLayerStageStorageCommitment(source: prepared.source,
                originalConfiguration: admission.configBytes, plan: plan,
                inventories: [other, own.inventory].sorted { $0.summary.stageIndex < $1.summary.stageIndex })
            commitments.append(sha256(try canonicalJSONData(commitment)))
            #expect(!commitment.bf16ConversionEnabled && commitment.canonicalTensorCount == 1655)
            #expect(commitment.sourceModelTensorBytes == 7_662_073_856)

            // The stage's own inventory: stored dtypes kept, F32 placeholders.
            let layers = plan.stages[rank].sourceRange.count
            let stageBytes = cut == 24 ? [2_962_665_216, 4_699_408_640] : [3_396_845_952, 4_265_227_904]
            #expect(own.inventory.summary.loadedTensorBytes == stageBytes[rank])
            #expect(own.inventory.active.allSatisfy { $0.sourceDType == $0.loadedDType })
            #expect(own.inventory.inert.flatMap(\.parameters).allSatisfy { $0.dtype == "float32" })
            #expect(own.inventory.summary.inertTensorBytes == (rank == 0 ? 2 : 1) * 5120 * 4)

            // The model: the SDK's dense class with the SDK's packed modules.
            #expect(own.model is Qwen35Model && !(own.model is any PrismHadamardLoading))
            let leaves = Dictionary(uniqueKeysWithValues: own.model.leafModules().flattened())
            let projections = leaves.values.filter { $0 is HadamardQuantizedLinear }.count
            #expect(projections == (layers - layers / 4) * 3 + (layers / 4) * 4 + layers * 3 + rank)
            #expect((leaves["language_model.model.embed_tokens"] is HadamardQuantizedEmbedding) == (rank == 0))
            #expect((leaves["language_model.lm_head"] is HadamardQuantizedLinear) == (rank == 1))
            // The two small gated-delta projections stay plain, so the decoder fuses nothing.
            #expect(type(of: try #require(leaves["language_model.model.layers.0.linear_attn.in_proj_a"])) == Linear.self)
            let parameters = Dictionary(uniqueKeysWithValues: own.model.parameters().flattened())
            #expect(parameters.count == own.inventory.active.count + own.inventory.inert.flatMap(\.parameters).count)
            #expect(!parameters.keys.contains { $0.hasSuffix(".signs") })
            for entry in own.inventory.active {
                #expect(parameters[entry.localName].map { String(describing: $0.dtype) } == entry.loadedDType, "\(entry.localName)")
            }
            // What the loader will require of the loaded stage, already true of the shells.
            let kv = try #require((own.model as? any CBv2CompleteCheckpointKVTypeProviding)?.cbv2CompleteCheckpointKVDTypes)
            #expect(kv.count == layers / 4 && kv.allSatisfy { $0 == .float32 })

            // One token through the prepared stage, as a graph.
            let observed = try BonsaiLazyForward.observe(model: own.model, configuration: plan.stages[rank].constructionConfiguration,
                layers: layers, residual: rank == 0 ? nil : .float32)
            try BonsaiLazyForward.report("prepared-stage cut=\(cut) rank=\(rank)", observed)
            if rank == 0 { #expect(observed.residualOut == "float32") } else { #expect(observed.logits == "float32") }
            #expect(observed.declaredKV == "float32" && observed.stagedKV == ["float32"])
            #expect(observed.declaredConvolution == ["float32"] && observed.stagedConvolution == ["float32"])
            #expect(observed.stagedSSM == ["float32"])
            #expect(observed.peakBytesDuringGraph < 32 << 20)
        }
        // Both ranks commit to the same storage before either reads a tensor.
        #expect(commitments.count == 2 && commitments[0] == commitments[1])
    }

    /// A stage configuration whose packed records are not the stage's own.
    @Test func aStageWhoseRecordsDifferIsRefused() throws {
        let admission = try F.admit(cut: 24)
        let prepared = try Self.source(admission)
        let stage = admission.plan.stages[0]
        var root = try #require(try JSONSerialization.jsonObject(with: stage.constructionConfiguration) as? [String: Any])
        var modules = try #require(root["modules"] as? [[String: Any]])
        modules.removeLast()
        root["modules"] = modules
        let altered = QwenLayerStagePlan.Stage(index: stage.index, sourceRange: stage.sourceRange, layers: stage.layers,
            constructionConfiguration: try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
            fingerprint: stage.fingerprint, activeModuleRoots: stage.activeModuleRoots, inertModules: stage.inertModules,
            quantizationMappings: stage.quantizationMappings, excludedQuantizationPaths: stage.excludedQuantizationPaths)
        #expect(throws: (any Error).self) {
            _ = try prepareQwenLayerStageModel(source: prepared.source, stage: altered, check: {})
        }
    }
}
