import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

/// CPU-only lazy shells from the real public header and transforms. No weight
/// payload is read or evaluated; actual file-backed loading remains a hardware gate.
@Suite("Bonsai 9B source and stage preparation", .serialized)
struct Bonsai9StagePreparationTests {
    private typealias F = Bonsai9Fixture
    private struct Stored: QwenStoredTensorDescribing {
        let shape: [Int], dtype: DType, byteCount: Int
        let storedFile: String, storedOffset: Int
    }
    private static func source(_ admission: QwenResidentAdmission) throws -> QwenResidentSource {
        let header = try F.header(), inventory = try F.inventory(), spec = admission.specification
        let stored = Dictionary(uniqueKeysWithValues: inventory.map { tensor in
            let item = header[tensor.name]!
            let dtype: DType = item.dtype == "U32" ? .uint32 : item.dtype == "F16" ? .float16 : .float32
            return (tensor.name, Stored(shape: item.shape, dtype: dtype, byteCount: item.bytes,
                storedFile: "model.safetensors", storedOffset: item.data_offsets[0]))
        })
        var packed: [String: QwenPrismHadamardSource.Packed] = [:]
        for tensor in inventory where tensor.name.hasSuffix(".scales") {
            let module = String(tensor.name.dropLast(".scales".count))
            packed[module] = .init(rows: tensor.shape[0], width: tensor.shape[1] * 128,
                                  embedding: module.hasSuffix("model.embed_tokens"))
        }
        let transforms = try JSONDecoder().decode(PrismHadamardConfiguration.self, from: F.data("hadamard"))
        #expect(transforms.blockSize == 4096 && transforms.gdnVGrouped)
        let prism = QwenPrismHadamardSource(transforms: transforms, packed: packed,
            signTensorCount: 202, signTensorBytes: 4_358_144)
        return try prepareQwenResidentMetadata(admission,
            artifact: .init(aggregateSHA256: spec.artifactSHA256, configurationSHA256: sha256(admission.configBytes),
                            verifiedManifestSHA256: sha256(admission.manifestBytes)),
            check: {}, confirmUnchanged: {}) { model, policy in
                try PreparedQwenCheckpoint(model: model, descriptors: stored, policy: policy, prism: prism)
            }.source
    }

    @Test(arguments: [4, 16, 28])
    func bothStagesOwnExactlyTheirTextTensors(cut: Int) throws {
        try Device.withDefaultDevice(.cpu) {
            var commitments: [String] = [], loadedBytes = 0
            for rank in 0...1 {
                let admission = try F.admit(rank: rank, cut: cut), prepared = try Self.source(admission)
                let source = prepared.source, plan = admission.plan
                #expect(prepared.profile.model == F.model && source.activationDType == .float32)
                #expect(!source.bf16ConversionEnabled && source.hiddenSize == 4096 && source.vocabularySize == 248_320)
                #expect(source.tensors.count == 831 && source.sourceBytes == 2_545_600_512)
                #expect(source.largestSourceBytes == 254_279_680 && source.quantization.count == 202)
                #expect(source.tensors.allSatisfy { $0.sourceDType == $0.loadedDType })
                #expect(prepared.pairRequirement.fusionReplacementBytes == 0)
                let other = try inspectOtherQwenLayerStage(source: source, stage: plan.stages[1 - rank], check: {})
                let own = try prepareQwenLayerStageModel(source: source, stage: plan.stages[rank], check: {})
                for item in [other, own.inventory] {
                    try QwenDenseObservedStageValidation.validateRegistered(source: prepared.validation, profile: prepared.profile,
                        requirement: prepared.pairRequirement, plan: plan, stageIndex: item.summary.stageIndex,
                        active: item.active, inert: item.inert, summary: item.summary)
                }
                let commitment = try qwenLayerStageStorageCommitment(source: source,
                    originalConfiguration: admission.configBytes, plan: plan,
                    inventories: [other, own.inventory].sorted { $0.summary.stageIndex < $1.summary.stageIndex })
                commitments.append(sha256(try canonicalJSONData(commitment)))
                #expect(!commitment.bf16ConversionEnabled && commitment.canonicalTensorCount == 831)
                #expect(commitment.sourceModelTensorBytes == 2_545_600_512)
                loadedBytes += own.inventory.summary.loadedTensorBytes
                #expect(own.inventory.active.allSatisfy { $0.sourceDType == $0.loadedDType })
                #expect(own.inventory.inert.flatMap(\.parameters).allSatisfy { $0.dtype == "float32" })
                #expect(own.model is Qwen35Model && !(own.model is any PrismHadamardLoading))
                let leaves = Dictionary(uniqueKeysWithValues: own.model.leafModules().flattened())
                let layers = plan.stages[rank].sourceRange.count
                #expect(leaves.values.filter { $0 is HadamardQuantizedLinear }.count ==
                    (layers - layers / 4) * 3 + layers / 4 * 4 + layers * 3 + rank)
                #expect((leaves["language_model.model.embed_tokens"] is HadamardQuantizedEmbedding) == (rank == 0))
                #expect((leaves["language_model.lm_head"] is HadamardQuantizedLinear) == (rank == 1))
                let parameters = Dictionary(uniqueKeysWithValues: own.model.parameters().flattened())
                #expect(!parameters.keys.contains { $0.hasSuffix(".signs") || $0.hasPrefix("vision_tower.") })
                #expect(parameters.count == own.inventory.active.count + own.inventory.inert.flatMap(\.parameters).count)
                for entry in own.inventory.active {
                    #expect(parameters[entry.localName].map { String(describing: $0.dtype) } == entry.loadedDType)
                }
                let kv = try #require((own.model as? any CBv2CompleteCheckpointKVTypeProviding)?.cbv2CompleteCheckpointKVDTypes)
                #expect(kv.count == layers / 4 && kv.allSatisfy { $0 == .float32 })
            }
            #expect(commitments.count == 2 && commitments[0] == commitments[1])
            #expect(loadedBytes == 2_545_600_512)
        }
    }

    @Test func verifiedTransformFilesAndStoredSignsMustMatchTheDeclaration() throws {
        try Device.withDefaultDevice(.cpu) {
            let configuration = try F.data("configuration"), model = try constructQwenModel(configuration)
            let original = try #require(JSONSerialization.jsonObject(with: F.data("hadamard")) as? [String: Any])
            let widths = try #require(original["prism.hadamard.sign_widths"] as? [Int])
            let values = try #require(original["prism.hadamard.sign_values"] as? [Float])
            var positions: [Int: Int] = [:], offset = 0
            for width in widths { positions[width] = offset * 4; offset += width }
            #expect(offset == values.count)
            var signs = Data()
            for value in values { var bits = value.bitPattern.littleEndian; withUnsafeBytes(of: &bits) { signs.append(contentsOf: $0) } }

            // Small synthetic files exercise the real verified-file/sign-reader path.
            // Non-sign payloads are deliberately absent: this method only inspects
            // their header descriptors. These are not artifact-loading evidence.
            func verify(block: Int, corruptSigns: Bool) throws -> QwenPrismHadamardSource? {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                var transform = original; transform["prism.hadamard.block_size"] = block
                var payload = signs
                if corruptSigns { payload[0] ^= 1 }
                let files = ["config.json": configuration, "hadamard.json": try JSONSerialization.data(withJSONObject: transform),
                             "signs.bin": payload]
                var aggregate = SHA256(), entries: [CheckpointManifest.Entry] = []
                for name in files.keys.sorted() {
                    let bytes = files[name]!, digest = SHA256.hash(data: bytes)
                    try bytes.write(to: directory.appendingPathComponent(name))
                    digest.withUnsafeBytes { aggregate.update(bufferPointer: $0) }
                    entries.append(.init(path: name, sha256: sha256(bytes), size_bytes: bytes.count))
                }
                let manifest = CheckpointManifest(aggregate_sha256: aggregate.finalize().map { String(format: "%02x", $0) }.joined(),
                    file_count: entries.count, total_size_bytes: entries.reduce(0) { $0 + $1.size_bytes }, files: entries)
                try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
                let checkpoint = try VerifiedCheckpoint(directory: directory, configurationData: configuration)
                let file = try #require(checkpoint.files["signs.bin"])
                var descriptors: [String: TensorDescriptor] = [:]
                for (name, item) in try F.header() where name.hasPrefix("language_model.") {
                    let dtype: DType = item.dtype == "U32" ? .uint32 : item.dtype == "F16" ? .float16 : .float32
                    let position = name.hasSuffix(".signs") ? try #require(positions[item.shape[0]]) : 0
                    descriptors[name] = .init(file: file, shape: item.shape, dtype: dtype, offset: position, byteCount: item.bytes)
                }
                let source = try QwenPrismHadamardSource.verify(model: model, checkpoint: checkpoint, descriptors: &descriptors)
                #expect(descriptors.count == 831 && !descriptors.keys.contains { $0.hasSuffix(".signs") })
                return source
            }
            let source = try #require(try verify(block: 4096, corruptSigns: false))
            #expect(source.packed.count == 202 && source.signTensorCount == 202 && source.signTensorBytes == 4_358_144)
            #expect(throws: (any Error).self) { _ = try verify(block: 1024, corruptSigns: false) }
            #expect(throws: (any Error).self) { _ = try verify(block: 512, corruptSigns: false) }
            #expect(throws: (any Error).self) { _ = try verify(block: 4096, corruptSigns: true) }
        }
    }
}
