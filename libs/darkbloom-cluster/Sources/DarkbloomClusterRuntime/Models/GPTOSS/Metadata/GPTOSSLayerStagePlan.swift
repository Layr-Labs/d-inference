import Foundation

/// CPU metadata only: how the registered GPT-OSS text model divides into two
/// contiguous layer stages. Nothing here constructs or evaluates a model,
/// reads a tensor or promises that a pair computes what one host computes.
///
/// The product class builds each layer's attention from the configuration's
/// explicit `layer_types` entry at that layer's own index, so a stage is the
/// same class constructed from a configuration that keeps that stage's slice
/// of `layer_types`. Any cut is structurally legal; the registered row decides
/// which cuts are admitted. Stage 0 owns the token embedding and exports the
/// residual before the final norm; stage 1 owns the final norm and the head.
struct GPTOSSLayerStagePlan {
    typealias Layer = QwenLayerStagePlan.Layer
    typealias InertModule = QwenLayerStagePlan.InertModule

    struct Stage {
        let index: Int
        let sourceRange: Range<Int>
        let layers: [Layer]
        let constructionConfiguration: Data
        let fingerprint: String
        let activeModuleRoots: [String]
        let inertModules: [InertModule]
    }
    struct Parameter: Equatable {
        let sourceName: String
        let stage: Int
        let localName: String
    }
    /// One stored tensor the registered geometry requires, as its header must state it.
    struct Tensor: Equatable {
        let name: String
        let sourceDType: String
        let shape: [Int]
        var byteCount: Int { shape.reduce(GPTOSSStageMetadata.elementBytes(sourceDType) ?? 0, *) }
        var identity: String {
            name + "|" + sourceDType + "|" + shape.map(String.init).joined(separator: ",") + "|" + String(byteCount)
        }
    }

    static let embedding = "model.embed_tokens", norm = "model.norm", head = "lm_head"
    static let layerPrefix = "model.layers."

    let specification: GPTOSSRegisteredSpecification
    let originalConfiguration: Data
    let fingerprint: String
    let layers: Int
    let layerTypes: [String]
    let stages: [Stage]
    /// Every stored tensor, by name: the closed inventory of the registered artifact.
    let tensors: [Tensor]
    /// Quantized module paths of the whole model and their declared policy.
    let quantization: [String: GPTOSSStageMetadata.Policy]

    init(configuration: Data, cut: Int) throws {
        let spec = try GPTOSSRegisteredSpecification.specification(configuration: configuration)
        guard let root = try JSONSerialization.jsonObject(with: configuration) as? [String: Any] else {
            throw ProbeError("GPT-OSS layer stages require a configuration object")
        }
        let types = try GPTOSSStageMetadata.validate(root, specification: spec)
        guard (1..<spec.layers).contains(cut) else {
            throw ProbeError("Two nonempty contiguous GPT-OSS stages must cover all layers")
        }
        let policy = try GPTOSSStageMetadata.policy(root, specification: spec)
        let ranges = [0..<cut, cut..<spec.layers]
        var stages: [Stage] = []
        for (index, range) in ranges.enumerated() {
            let layerMap = range.map { Layer(globalIndex: $0, localIndex: $0 - range.lowerBound, kind: types[$0]) }
            let inert = index == 0 ? [
                InertModule(path: Self.norm, responsibility: "Replaced by an identity before any evaluation; stage 0 exports the residual before the final norm"),
                InertModule(path: Self.head, responsibility: "Replaced before any evaluation; stage 0 produces no logits"),
            ] : [InertModule(path: Self.embedding,
                responsibility: "Replaced before any evaluation; the incoming residual bypasses the token embedding")]
            let active = (index == 0 ? [Self.embedding] : [Self.norm, Self.head])
                + range.map { Self.layerPrefix + "\($0 - range.lowerBound)" }
            var mapped: [String: Any] = policy.defaults
            for path in policy.overrides.keys.sorted() {
                guard let local = Self.localModule(path, range: range, index: index) else { continue }
                guard mapped[local] == nil else { throw ProbeError("GPT-OSS stage quantization mapping collision") }
                mapped[local] = policy.overrides[path]!
            }
            // An inactive placeholder must not inherit the checkpoint's default policy.
            for entry in inert where entry.path != Self.norm { mapped[entry.path] = false }
            var stageRoot = root
            stageRoot["num_hidden_layers"] = range.count
            stageRoot["layer_types"] = layerMap.map(\.kind)
            for key in policy.containerKeys { stageRoot[key] = mapped }
            let data = try QwenStageMetadata.json(stageRoot)
            let identity: [String: Any] = ["adapter": "gpt-oss-layer-stage-v1",
                "sourceConfigurationSHA256": sha256(configuration), "stage": index,
                "sourceLayerStart": range.lowerBound, "sourceLayerEnd": range.upperBound,
                "constructionConfigurationSHA256": sha256(data), "activeModuleRoots": active.sorted(),
                "inertModules": try JSONSerialization.jsonObject(with: JSONEncoder().encode(inert)),
                "expertLayout": "split_gate_up_as_stored", "requestState": "ordinary_attention_caches"]
            stages.append(Stage(index: index, sourceRange: range, layers: layerMap,
                constructionConfiguration: data, fingerprint: sha256(try QwenStageMetadata.json(identity)),
                activeModuleRoots: active.sorted(), inertModules: inert))
        }
        let tensors = GPTOSSStageMetadata.tensors(specification: spec)
        guard tensors.count == spec.tensorCount, Set(tensors.map(\.name)).count == tensors.count,
              tensors.reduce(0, { $0 + $1.byteCount }) == spec.sourceBytes,
              tensors.map(\.byteCount).max() == spec.largestTensorBytes,
              sha256(Data(tensors.map(\.identity).joined(separator: "\n").utf8)) == spec.inventorySHA256,
              Set(policy.modules.keys) == Set(tensors.filter { $0.name.hasSuffix(".scales") }.map { String($0.name.dropLast(7)) }) else {
            throw ProbeError("Registered GPT-OSS geometry does not reproduce the pinned tensor inventory")
        }
        specification = spec; originalConfiguration = configuration
        layers = spec.layers; layerTypes = types; self.stages = stages
        self.tensors = tensors; quantization = policy.modules
        fingerprint = sha256(try QwenStageMetadata.json([
            "adapter": "gpt-oss-two-layer-stages-v1", "sourceConfigurationSHA256": sha256(configuration),
            "stages": stages.map(\.fingerprint)] as [String: Any]))
    }

    /// The stage-local module path of a source module, or nil when the stage does not own it.
    static func localModule(_ path: String, range: Range<Int>, index: Int) -> String? {
        if path.hasPrefix(layerPrefix) {
            let pieces = path.dropFirst(layerPrefix.count).split(separator: ".", omittingEmptySubsequences: false)
            guard let first = pieces.first, let layer = Int(first), String(layer) == String(first),
                  range.contains(layer), pieces.count > 1 else { return nil }
            return layerPrefix + "\(layer - range.lowerBound)." + pieces.dropFirst().joined(separator: ".")
        }
        if (index == 0 && path == embedding) || (index == 1 && [norm, head].contains(path)) { return path }
        return nil
    }

    /// The stage that owns a stored tensor and its name there. A name outside
    /// the closed inventory is an error; nothing is guessed, renamed or fused.
    func parameter(sourceName name: String) throws -> Parameter {
        guard tensors.contains(where: { $0.name == name }) else {
            throw ProbeError("Unknown GPT-OSS source tensor: \(name)")
        }
        // `sinks` is a direct parameter of its attention block; every other
        // tensor is a parameter of the module its name ends in.
        let pieces = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let module = pieces.dropLast().joined(separator: "."), suffix = pieces[pieces.count - 1]
        for stage in stages {
            if let local = Self.localModule(module, range: stage.sourceRange, index: stage.index) {
                return Parameter(sourceName: name, stage: stage.index, localName: local + "." + suffix)
            }
        }
        throw ProbeError("GPT-OSS source tensor has no owning stage: \(name)")
    }

    func parameters() throws -> [Parameter] {
        let result = try tensors.map { try parameter(sourceName: $0.name) }
        guard Set(result.map { "\($0.stage):\($0.localName)" }).count == result.count else {
            throw ProbeError("GPT-OSS stage parameter mapping is not injective")
        }
        return result
    }

    /// The declared tensor bytes one stage holds: its share of the artifact.
    func tensorBytes(stage index: Int) throws -> Int {
        let byName = Dictionary(uniqueKeysWithValues: tensors.map { ($0.name, $0.byteCount) })
        return try parameters().filter { $0.stage == index }.reduce(0) { $0 + byName[$1.sourceName]! }
    }
}
