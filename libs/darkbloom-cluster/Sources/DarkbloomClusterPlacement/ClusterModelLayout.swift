import DarkbloomClusterProtocol
import Foundation

/// What an artifact is made of, as far as placing it needs to know: the bytes
/// each layer stores and loads, the parts only the first or the last range
/// holds, what a request keeps per layer, and where the family's stage plan
/// can cut. Derived from the artifact's tensor headers and configuration by
/// `ClusterModelLayoutBuilder`; nothing in it is typed per model.
public struct ClusterModelLayout: Codable, Equatable, Sendable {
    public static let schemaName = "darkbloom_cluster_model_layout_v1"
    public static let maximumEncodedBytes = 1_048_576

    /// A group of tensors that load together.
    public struct Part: Codable, Equatable, Sendable {
        public var storedBytes = 0
        /// Bytes held once loaded (equal to stored unless the loader converts).
        public var loadedBytes = 0
        public var largestTensorBytes = 0
        public var tensorCount = 0
        /// Bytes of this part that exist a second time while a request runs
        /// (weights the runtime replaces with a fused copy, for example).
        public var requestWorkBytes = 0

        public init() {}
        public init(storedBytes: Int, loadedBytes: Int, largestTensorBytes: Int, tensorCount: Int, requestWorkBytes: Int = 0) {
            self.storedBytes = storedBytes; self.loadedBytes = loadedBytes; self.largestTensorBytes = largestTensorBytes
            self.tensorCount = tensorCount; self.requestWorkBytes = requestWorkBytes
        }
        mutating func add(stored: Int, loaded: Int, work: Int) {
            storedBytes += stored; loadedBytes += loaded; requestWorkBytes += work
            largestTensorBytes = max(largestTensorBytes, loaded); tensorCount += 1
        }
    }

    public struct Layer: Codable, Equatable, Sendable {
        public let index: Int
        /// The family's label. Layers with one label are assumed to cost the same.
        public let kind: String
        public let weights: Part
        /// Request state this layer keeps whatever the context length.
        public let stateFixedBytes: Int
        /// Request state per context token.
        public let stateBytesPerToken: Int
        /// Relative compute cost. 1 for every layer until a probe measures kinds apart.
        public let cost: Double

        public init(index: Int, kind: String, weights: Part, stateFixedBytes: Int, stateBytesPerToken: Int, cost: Double) {
            self.index = index; self.kind = kind; self.weights = weights
            self.stateFixedBytes = stateFixedBytes; self.stateBytesPerToken = stateBytesPerToken; self.cost = cost
        }
    }

    public let schema: String
    public let runtimeModelID: String
    public let artifactSHA256: String
    public let configurationSHA256: String
    public let layers: [Layer]
    /// What only the first range holds (the embedding).
    public let ingress: Part
    /// What only the last range holds (final norm and head).
    public let egress: Part
    /// What no range loads (vision, MTP, audio).
    public let excluded: Part
    /// Stage-0 layer counts the installed runtime admits for this model.
    public let admittedCuts: [Int]
    /// Stage-0 layer counts the family's stage plan could cut at. A superset
    /// of the admitted cuts; equal to them once nothing else limits a model.
    public let structuralCuts: [Int]
    public let generationModes: [ClusterGenerationMode]
    public let prefillSchedules: [ClusterPrefillSchedule]
    public let maximumPromptTokens: Int
    public let maximumOutputTokens: Int
    public let maximumChunkTokens: Int
    /// Bytes per token of the residual that crosses a cut.
    public let boundaryBytesPerToken: Int
    /// What the family's request gate charges a rank for state whatever its
    /// range, at the largest request. Zero when a rank is charged its own
    /// layers only.
    public let requestChargeEveryRankBytes: Int

    public init(schema: String = ClusterModelLayout.schemaName, runtimeModelID: String, artifactSHA256: String,
                configurationSHA256: String, layers: [Layer], ingress: Part, egress: Part, excluded: Part,
                admittedCuts: [Int], structuralCuts: [Int], generationModes: [ClusterGenerationMode],
                prefillSchedules: [ClusterPrefillSchedule], maximumPromptTokens: Int, maximumOutputTokens: Int,
                maximumChunkTokens: Int, boundaryBytesPerToken: Int, requestChargeEveryRankBytes: Int) {
        self.schema = schema; self.runtimeModelID = runtimeModelID; self.artifactSHA256 = artifactSHA256
        self.configurationSHA256 = configurationSHA256; self.layers = layers; self.ingress = ingress
        self.egress = egress; self.excluded = excluded; self.admittedCuts = admittedCuts
        self.structuralCuts = structuralCuts; self.generationModes = generationModes
        self.prefillSchedules = prefillSchedules; self.maximumPromptTokens = maximumPromptTokens
        self.maximumOutputTokens = maximumOutputTokens; self.maximumChunkTokens = maximumChunkTokens
        self.boundaryBytesPerToken = boundaryBytesPerToken; self.requestChargeEveryRankBytes = requestChargeEveryRankBytes
    }

    public var layerCount: Int { layers.count }
    public var maximumContextTokens: Int { maximumPromptTokens + maximumOutputTokens }
    /// Bytes a single Mac holds when it loads every layer.
    public var wholeModelLoadedBytes: Int {
        ingress.loadedBytes + egress.loadedBytes + layers.reduce(0) { $0 + $1.weights.loadedBytes }
    }

    public func validate() throws {
        guard schema == Self.schemaName, (2...1024).contains(layers.count),
              layers.enumerated().allSatisfy({ $0.offset == $0.element.index && $0.element.cost > 0
                  && $0.element.cost.isFinite && $0.element.stateFixedBytes >= 0
                  && $0.element.stateBytesPerToken >= 0 && !$0.element.kind.isEmpty }),
              ([ingress, egress, excluded] + layers.map(\.weights)).allSatisfy({
                  $0.storedBytes >= 0 && $0.loadedBytes >= 0 && $0.largestTensorBytes >= 0
                      && $0.largestTensorBytes <= $0.loadedBytes && $0.tensorCount >= 0 && $0.requestWorkBytes >= 0
              }),
              structuralCuts == Array(Set(structuralCuts)).sorted(),
              admittedCuts == Array(Set(admittedCuts)).sorted(),
              structuralCuts.allSatisfy({ (1..<layers.count).contains($0) }),
              Set(admittedCuts).isSubset(of: Set(structuralCuts)),
              !generationModes.isEmpty, !prefillSchedules.isEmpty,
              maximumPromptTokens > 0, maximumOutputTokens > 0,
              (1...maximumPromptTokens).contains(maximumChunkTokens),
              boundaryBytesPerToken > 0, requestChargeEveryRankBytes >= 0 else {
            throw ClusterPlacementError("Model layout is malformed")
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> ClusterModelLayout {
        guard (2...maximumEncodedBytes).contains(data.count) else {
            throw ClusterPlacementError("Model layout is empty or larger than \(maximumEncodedBytes) bytes")
        }
        let value = try JSONDecoder().decode(ClusterModelLayout.self, from: data)
        try value.validate()
        return value
    }

    /// What one contiguous range of layers holds and needs.
    public struct Range: Equatable, Sendable {
        public let layers: Swift.Range<Int>
        public let loadedBytes: Int
        public let largestTensorBytes: Int
        public let tensorCount: Int
        public let requestWorkBytes: Int
        public let cost: Double
        public let stateFixedBytes: Int
        public let stateBytesPerToken: Int
        public func stateBytes(tokens: Int) -> Int { stateFixedBytes + stateBytesPerToken * tokens }
    }

    /// The range `[lower, upper)`, with the ingress when it starts at layer 0
    /// and the egress when it ends at the last layer.
    public func range(_ bounds: Swift.Range<Int>) -> Range {
        var part = Part(), cost = 0.0, fixed = 0, perToken = 0
        func merge(_ other: Part) {
            part.storedBytes += other.storedBytes; part.loadedBytes += other.loadedBytes
            part.requestWorkBytes += other.requestWorkBytes; part.tensorCount += other.tensorCount
            part.largestTensorBytes = max(part.largestTensorBytes, other.largestTensorBytes)
        }
        if bounds.lowerBound == 0 { merge(ingress) }
        if bounds.upperBound == layers.count { merge(egress) }
        for layer in layers[bounds] {
            merge(layer.weights); cost += layer.cost
            fixed += layer.stateFixedBytes; perToken += layer.stateBytesPerToken
        }
        return .init(layers: bounds, loadedBytes: part.loadedBytes, largestTensorBytes: part.largestTensorBytes,
            tensorCount: part.tensorCount, requestWorkBytes: part.requestWorkBytes, cost: cost,
            stateFixedBytes: fixed, stateBytesPerToken: perToken)
    }
}

/// One stored tensor as an artifact's header names it.
public struct ClusterPlacementStoredTensor: Equatable, Sendable {
    public let name: String
    public let byteCount: Int
    /// The header's dtype name and shape, for a family that pins its inventory.
    public let dtype: String
    public let shape: [Int]
    public init(name: String, byteCount: Int, dtype: String = "", shape: [Int] = []) {
        self.name = name; self.byteCount = byteCount; self.dtype = dtype; self.shape = shape
    }
}

public struct ClusterPlacementLayerState: Equatable, Sendable {
    public let fixedBytes: Int
    public let bytesPerToken: Int
    public init(fixedBytes: Int, bytesPerToken: Int) { self.fixedBytes = fixedBytes; self.bytesPerToken = bytesPerToken }
}

/// Everything the planner needs to know about a model family, as questions a
/// family answers from its own stage plan and configuration. A family that
/// can already load two layer stages can answer each in a line or two.
public protocol ClusterPlacementFamily {
    var runtimeModelID: String { get }
    /// Decoder layers, from the artifact's configuration.
    var layerCount: Int { get }
    /// Stage-0 layer counts the installed runtime admits for this model.
    var admittedCuts: [Int] { get }
    /// Stage-0 layer counts at which this family's stage plan can cut.
    var structuralCuts: [Int] { get }
    var generationModes: [ClusterGenerationMode] { get }
    var prefillSchedules: [ClusterPrefillSchedule] { get }
    var maximumPromptTokens: Int { get }
    var maximumOutputTokens: Int { get }
    var maximumChunkTokens: Int { get }
    /// Residual width times its element size.
    var boundaryBytesPerToken: Int { get }
    /// See `ClusterModelLayout.requestChargeEveryRankBytes`.
    var requestChargeEveryRankBytes: Int { get }

    /// Which of the two stages the family's own plan gives a stored tensor
    /// when stage 0 holds `cut` layers: 0, 1, or nil when no stage loads it.
    func stage(ofStoredTensor name: String, cut: Int) throws -> Int?
    /// The layer a stored tensor belongs to; nil for ingress, egress and
    /// tensors no stage loads.
    func layer(ofStoredTensor name: String) -> Int?
    func layerKind(_ layer: Int) -> String
    func requestState(layer: Int) throws -> ClusterPlacementLayerState
    /// Bytes held once loaded. The stored size unless the loader converts.
    func loadedBytes(ofStoredTensor name: String, storedBytes: Int) -> Int
    /// Bytes of this tensor that exist a second time while a request runs.
    func requestWorkBytes(ofStoredTensor name: String, storedBytes: Int) -> Int
}

extension ClusterPlacementFamily {
    public var structuralCuts: [Int] { admittedCuts }
    public var requestChargeEveryRankBytes: Int { 0 }
    public func loadedBytes(ofStoredTensor name: String, storedBytes: Int) -> Int { storedBytes }
    public func requestWorkBytes(ofStoredTensor name: String, storedBytes: Int) -> Int { 0 }
}

/// Builds a layout from an artifact's tensor headers through a family's stage
/// plan, and refuses a family whose answers are not a contiguous layer
/// pipeline or do not conserve the artifact's bytes.
public enum ClusterModelLayoutBuilder {
    public static func build(family: some ClusterPlacementFamily, tensors: [ClusterPlacementStoredTensor],
                             artifactSHA256: String, configurationSHA256: String) throws -> ClusterModelLayout {
        let count = family.layerCount, cuts = family.structuralCuts
        guard (2...1024).contains(count), !cuts.isEmpty, cuts == Array(Set(cuts)).sorted(),
              cuts.allSatisfy({ (1..<count).contains($0) }),
              Set(family.admittedCuts).isSubset(of: Set(cuts)),
              (1...65_536).contains(tensors.count), Set(tensors.map(\.name)).count == tensors.count else {
            throw ClusterPlacementError("A layout needs at least two layers, one cut and a bounded list of distinct tensors")
        }
        var layers = [ClusterModelLayout.Part](repeating: .init(), count: count)
        var ingress = ClusterModelLayout.Part(), egress = ClusterModelLayout.Part(), excluded = ClusterModelLayout.Part()
        for tensor in tensors {
            guard tensor.byteCount > 0 else { throw ClusterPlacementError("Tensor \(tensor.name) has no bytes") }
            let stages = try cuts.map { try family.stage(ofStoredTensor: tensor.name, cut: $0) }
            let loaded = family.loadedBytes(ofStoredTensor: tensor.name, storedBytes: tensor.byteCount)
            let work = family.requestWorkBytes(ofStoredTensor: tensor.name, storedBytes: tensor.byteCount)
            guard loaded > 0, work >= 0 else { throw ClusterPlacementError("Tensor \(tensor.name) has an invalid loaded size") }
            if stages.allSatisfy({ $0 == nil }) {
                guard family.layer(ofStoredTensor: tensor.name) == nil else {
                    throw ClusterPlacementError("Tensor \(tensor.name) names a layer but no stage loads it")
                }
                excluded.add(stored: tensor.byteCount, loaded: tensor.byteCount, work: 0)
                continue
            }
            guard stages.allSatisfy({ $0 == 0 || $0 == 1 }) else {
                throw ClusterPlacementError("Tensor \(tensor.name) is loaded at some cuts and not at others")
            }
            if let layer = family.layer(ofStoredTensor: tensor.name) {
                // A layer's tensors are in stage 1 while the cut is at or below
                // the layer, and in stage 0 above it: one step, at that layer.
                guard (0..<count).contains(layer),
                      zip(cuts, stages).allSatisfy({ $0.1 == ($0.0 <= layer ? 1 : 0) }) else {
                    throw ClusterPlacementError("Tensor \(tensor.name) does not follow its layer across the cuts: "
                        + "the stage plan is not a contiguous layer pipeline")
                }
                layers[layer].add(stored: tensor.byteCount, loaded: loaded, work: work)
            } else if stages.allSatisfy({ $0 == 0 }) {
                ingress.add(stored: tensor.byteCount, loaded: loaded, work: work)
            } else if stages.allSatisfy({ $0 == 1 }) {
                egress.add(stored: tensor.byteCount, loaded: loaded, work: work)
            } else {
                throw ClusterPlacementError("Tensor \(tensor.name) changes stage with the cut but names no layer")
            }
        }
        guard layers.allSatisfy({ $0.tensorCount > 0 }) else {
            throw ClusterPlacementError("A layer has no stored tensor: the headers and the configuration disagree")
        }
        let stored = tensors.reduce(0) { $0 + $1.byteCount }
        guard stored == ingress.storedBytes + egress.storedBytes + excluded.storedBytes
                + layers.reduce(0, { $0 + $1.storedBytes }) else {
            throw ClusterPlacementError("Layout does not conserve the artifact's stored bytes")
        }
        let value = ClusterModelLayout(schema: ClusterModelLayout.schemaName, runtimeModelID: family.runtimeModelID,
            artifactSHA256: artifactSHA256, configurationSHA256: configurationSHA256,
            layers: try layers.enumerated().map { index, weights in
                let state = try family.requestState(layer: index)
                return ClusterModelLayout.Layer(index: index, kind: family.layerKind(index), weights: weights,
                    stateFixedBytes: state.fixedBytes, stateBytesPerToken: state.bytesPerToken, cost: 1)
            },
            ingress: ingress, egress: egress, excluded: excluded,
            admittedCuts: family.admittedCuts, structuralCuts: cuts,
            generationModes: family.generationModes, prefillSchedules: family.prefillSchedules,
            maximumPromptTokens: family.maximumPromptTokens, maximumOutputTokens: family.maximumOutputTokens,
            maximumChunkTokens: family.maximumChunkTokens, boundaryBytesPerToken: family.boundaryBytesPerToken,
            requestChargeEveryRankBytes: family.requestChargeEveryRankBytes)
        try value.validate()
        return value
    }
}
