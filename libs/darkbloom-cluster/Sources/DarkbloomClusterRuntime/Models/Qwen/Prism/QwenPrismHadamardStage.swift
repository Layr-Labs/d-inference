import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

/// The verified transform metadata of a Prism Hadamard pack, and the one
/// place its packed modules are installed. The SDK's own loader builds a
/// `HadamardQuantizedLinear` or `HadamardQuantizedEmbedding` per declared
/// module from the whole checkpoint in memory; a stage owns a layer range and
/// receives its tensors one at a time, so the same public module types are
/// installed here as shells of the stored shapes and dtypes and the verified
/// loader then fills them. The checks are the SDK loader's
/// (`PrismHadamardCheckpoint`), made against descriptors instead of arrays.
///
/// The sign tensors stored beside the packed modules are not parameters of
/// any module: a module's signs live in its transform, which is decoded from
/// the artifact's transform file. Each stored sign tensor is read once and
/// must equal the transform of its width, and is then left out of the tensor
/// inventory.
struct QwenPrismHadamardSource {
    struct Packed: Equatable {
        let rows: Int, width: Int
        let embedding: Bool
    }

    static let namespace = QwenPrismStageConfiguration.namespace

    let transforms: PrismHadamardConfiguration
    /// Every packed module of the artifact, by its canonical module path.
    let packed: [String: Packed]
    let signTensorCount: Int
    let signTensorBytes: Int

    /// Nil for a model that is not a Prism pack; `descriptors` is then left
    /// alone. Otherwise the transform file and every sign tensor have been
    /// checked and the sign tensors are removed from `descriptors`.
    static func verify(model: any LanguageModel, checkpoint: VerifiedCheckpoint,
                       descriptors: inout [String: TensorDescriptor]) throws -> Self? {
        guard let declaration = (model as? any PrismHadamardLoading)?.prismCheckpoint else { return nil }
        // The transform file is one of the manifest's files: its bytes were
        // hashed with the artifact and its descriptor is pinned like a shard's.
        guard let file = checkpoint.files[QwenPrismStageConfiguration.transformFile],
              (1...8 * 1024 * 1024).contains(file.size) else {
            throw ProbeError("Prism pack has no bounded verified transform file")
        }
        let transforms = try JSONDecoder().decode(PrismHadamardConfiguration.self,
                                                  from: file.data(offset: 0, count: file.size))
        let suffix = "." + QwenPrismStageConfiguration.signsSuffix
        let names = declaration.modules.map { namespace + $0.path }
        let forward = Set(declaration.modules.filter { !$0.embedding }.map { namespace + $0.path + ".weight" })
        let inverse = Set(declaration.modules.filter(\.embedding).map { namespace + $0.path + ".weight" })
        guard transforms.gdnVGrouped, transforms.blockSize == QwenPrismStageConfiguration.blockSize,
              Set(transforms.weightNames) == forward, Set(transforms.inverseWeightNames) == inverse,
              Set(descriptors.keys.filter { $0.hasSuffix(suffix) }) == Set(names.map { $0 + suffix }),
              !descriptors.keys.contains(where: { $0.contains(".mtp.") || $0.hasPrefix("mtp.") }) else {
            throw ProbeError("Prism transform file disagrees with the pack's declaration or its tensors")
        }
        // Native F32 state requires the published F32 normalizers.
        let normalizers = descriptors.filter {
            $0.key.hasPrefix(namespace + "model.layers.")
                && ($0.key.hasSuffix(".input_layernorm.weight") || $0.key.hasSuffix(".post_attention_layernorm.weight"))
        }
        guard !normalizers.isEmpty, normalizers.values.allSatisfy({ $0.dtype == .float32 }) else {
            throw ProbeError("Prism pack does not store its layer normalizers as F32")
        }
        var packed: [String: Packed] = [:], signBytes = 0
        for (record, name) in zip(declaration.modules, names) {
            guard record.block == transforms.blockSize, record.dtype == "float16",
                  let weight = descriptors[name + ".weight"], let scales = descriptors[name + ".scales"],
                  let biases = descriptors[name + ".biases"], let signs = descriptors[name + suffix],
                  weight.shape.count == 2, weight.dtype == .uint32,
                  scales.shape.count == 2, scales.dtype == .float16, biases.dtype == .float16,
                  scales.shape == biases.shape, scales.shape[0] == weight.shape[0],
                  scales.shape[1] * 8 == weight.shape[1],
                  signs.shape == [weight.shape[1] * 16], signs.dtype == .float32 else {
                throw ProbeError("Prism packed tensor shape or dtype differs: \(name)")
            }
            let width = weight.shape[1] * 16
            let transform = try transforms.transform(forWidth: width)
            let stored = try signs.file.data(offset: signs.offset, count: signs.byteCount).withUnsafeBytes { bytes in
                (0..<width).map { Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
            }
            guard transform.blockSize == QwenPrismStageConfiguration.blockSize, transform.width == width,
                  transform.matches(signs: stored) else {
                throw ProbeError("Prism stored signs differ from the transform file: \(name)")
            }
            packed[name] = Packed(rows: weight.shape[0], width: width, embedding: record.embedding)
            signBytes += signs.byteCount
        }
        for name in names { descriptors[name + suffix] = nil }
        return .init(transforms: transforms, packed: packed, signTensorCount: names.count, signTensorBytes: signBytes)
    }

    /// Replaces each module `policies` names by a shell of its stored layout
    /// behind its transform. `sourcePath` maps a module of this model to the
    /// artifact's module it is loaded from; the model's own parameters are
    /// lazy placeholders until the verified loader assigns the stored tensors.
    func install(model: any LanguageModel, policies: [String: BaseConfiguration.Quantization],
                 sourcePath: (String) -> String?) throws {
        let leaves = Dictionary(uniqueKeysWithValues: model.leafModules().flattened())
        var replacements: [(String, Module)] = []
        for path in policies.keys.sorted() {
            guard let policy = policies[path], policy.mode == .affine,
                  policy.bits == QwenPrismStageConfiguration.bits,
                  policy.groupSize == QwenPrismStageConfiguration.groupSize,
                  let source = sourcePath(path), let module = packed[source], let leaf = leaves[path] else {
                throw ProbeError("Prism packed module has no declaration or a different policy: \(path)")
            }
            let weight = MLXArray.zeros([module.rows, module.width / 32 * policy.bits], dtype: .uint32)
            let scales = MLXArray.zeros([module.rows, module.width / policy.groupSize], dtype: .float16)
            let biases = MLXArray.zeros([module.rows, module.width / policy.groupSize], dtype: .float16)
            let transform = try transforms.transform(forWidth: module.width)
            if module.embedding {
                guard type(of: leaf) == Embedding.self, let embedding = leaf as? Embedding,
                      embedding.shape == (module.rows, module.width) else {
                    throw ProbeError("Prism packed embedding differs from the constructed model: \(path)")
                }
                replacements.append((path, try HadamardQuantizedEmbedding(weight: weight, scales: scales,
                    biases: biases, groupSize: policy.groupSize, bits: policy.bits, transform: transform)))
            } else {
                guard type(of: leaf) == Linear.self, let linear = leaf as? Linear, linear.bias == nil,
                      linear.shape == (module.rows, module.width) else {
                    throw ProbeError("Prism packed projection differs from the constructed model: \(path)")
                }
                replacements.append((path, try HadamardQuantizedLinear(weight: weight, scales: scales,
                    biases: biases, groupSize: policy.groupSize, bits: policy.bits, transform: transform)))
            }
        }
        try model.update(modules: ModuleChildren.unflattened(replacements), verify: [.noUnusedKeys])
    }

    /// The full model: every packed module of the artifact, and nothing else.
    func install(model: any LanguageModel, policies: [String: BaseConfiguration.Quantization]) throws {
        guard Set(policies.keys) == Set(packed.keys) else {
            throw ProbeError("Prism pack's stored scales do not cover exactly its declared packed modules")
        }
        try install(model: model, policies: policies) { $0 }
    }

    /// One stage: exactly the records its construction configuration carries.
    func install(stageModel model: any LanguageModel, constructionConfiguration: Data,
                 policies: [String: BaseConfiguration.Quantization], sourcePath: (String) -> String?) throws {
        let records = try QwenPrismStageConfiguration.stageModules(constructionConfiguration: constructionConfiguration)
        guard Set(records.map { Self.namespace + $0.path }) == Set(policies.keys),
              records.allSatisfy({ record in
                  sourcePath(Self.namespace + record.path).flatMap { packed[$0] }?.embedding == record.embedding
              }) else {
            throw ProbeError("Prism stage configuration declares different packed modules than the stage owns")
        }
        try install(model: model, policies: policies, sourcePath: sourcePath)
    }

    /// The pack's activation dtype, as the SDK's own model describes it for
    /// exactly the stored layout: every parameter of `model` must already
    /// have its stored dtype (the shells by construction, the plain tensors
    /// because the constructor's F32 defaults are what the pack stores). The
    /// dtype of the embedding's scales is not that dtype.
    func activationDType<Stored>(model: any LanguageModel,
                                 canonical: [String: QwenCheckpointTensor<Stored>]) throws -> DType {
        let parameters = Dictionary(uniqueKeysWithValues: model.parameters().flattened())
        guard parameters.count == canonical.count,
              canonical.allSatisfy({ parameters[$0.key]?.dtype == $0.value.dtype }) else {
            throw ProbeError("Prism metadata model does not have the pack's stored dtypes")
        }
        guard let types = (model as? any CBv2CompleteCheckpointKVTypeProviding)?.cbv2CompleteCheckpointKVDTypes,
              let dtype = types.first, types.allSatisfy({ $0 == dtype }) else {
            throw ProbeError("Prism pack has no single native activation dtype")
        }
        return dtype
    }
}
