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
        /// The attention transient of one prefill frame on this layer (the
        /// owner's planner prices it beside the KV, oMLX U#3651): bytes per
        /// query token whatever the context (the attention output), and bytes
        /// per query token per key it attends over (an unfused kernel's
        /// float32 scores; zero for a fused one). Nil for a layer without
        /// attention and in a layout written before these were derived.
        public let transientBytesPerQuery: Int?
        public let transientBytesPerQueryKey: Int?
        /// The most keys one query attends over: a sliding window plus the
        /// frame, or nil for the whole context.
        public let transientKeyWindow: Int?

        public init(index: Int, kind: String, weights: Part, stateFixedBytes: Int, stateBytesPerToken: Int, cost: Double,
                    transient: ClusterPlacementLayerTransient = .none) {
            self.index = index; self.kind = kind; self.weights = weights
            self.stateFixedBytes = stateFixedBytes; self.stateBytesPerToken = stateBytesPerToken; self.cost = cost
            let present = transient != .none
            transientBytesPerQuery = present ? transient.bytesPerQuery : nil
            transientBytesPerQueryKey = present ? transient.bytesPerQueryKey : nil
            transientKeyWindow = present ? transient.keyWindow : nil
        }

        public var transient: ClusterPlacementLayerTransient {
            .init(bytesPerQuery: transientBytesPerQuery ?? 0, bytesPerQueryKey: transientBytesPerQueryKey ?? 0,
                  keyWindow: transientKeyWindow)
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
    /// Of `excluded`, the model's own speculative (MTP) head: what the
    /// decoding rank of `phase_split_mtp_v1` loads beside its stages. Nil when
    /// the artifact ships none, or in a layout written before it was derived.
    public fileprivate(set) var speculativeHead: Part? = nil
    /// The decode speed-up the model's resident row credits its speculative
    /// head with (the smallest speed-up the pair measured with the head over
    /// the same phase split without it), where a decoding Mac is credited at
    /// all (`ClusterSpeculativeCredit`). Nil: the head is never credited.
    public fileprivate(set) var speculativeDecodeFactor: Double? = nil
    /// The family's tensor-parallel plan over this artifact's bytes: what a
    /// rank of `tensor_parallel_v1` (or the hybrid's decode) holds. Nil when
    /// the family has no plan, or in a layout written before it was derived.
    public fileprivate(set) var tensorParallel: ClusterTensorParallelLayout? = nil
    /// The routed experts of a mixture-of-experts family that states its
    /// routing: what a decode step reads of them. Nil otherwise, or in a
    /// layout written before it was derived (every byte is then read).
    public fileprivate(set) var routedExperts: ClusterRoutedExperts? = nil

    /// What the last rank of a speculative mode holds beside its stages, each
    /// tensor in whole pages: the model's head, and under a pipeline (where the
    /// last rank never holds the first range) a copy of the token embedding
    /// the head looks its drafts up in (the ingress). Zero for other modes or
    /// a model without a head; `largestTensorBytes` is the largest of them.
    public func speculativeHolding(mode: ClusterGenerationMode, pageSizeBytes: Int) -> (bytes: Int, largestTensorBytes: Int) {
        guard mode.usesSpeculativeHead, let head = speculativeHead else { return (0, 0) }
        let parts = mode.isPhaseSplit ? [head] : [head, ingress]
        return (parts.reduce(0) { $0 + $1.loadedBytes + $1.tensorCount * pageSizeBytes },
                parts.map(\.largestTensorBytes).max() ?? 0)
    }
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
    /// How much of that charge each context token below the largest request
    /// saves (the keys and values it would have held). Nil in a layout written
    /// before it was derived: the charge is then taken at the largest request.
    public let requestChargeEveryRankBytesPerToken: Int?
    /// Bytes every rank's quotation holds beside its weights and its own
    /// state, added to them: unlike the charge, which stands in for state,
    /// this is the family's workspace and load allowances. Nil when it has none.
    public var allowanceEveryRankBytes: Int? = nil
    /// Some adapters reserve the entire advertised request scope during LOAD.
    /// Their memory fit cannot shrink with the workload used to predict speed.
    /// Nil preserves request-sized accounting for older/dynamic adapters.
    public var reservesFullRequestScope: Bool? = nil


    public init(schema: String = ClusterModelLayout.schemaName, runtimeModelID: String, artifactSHA256: String,
                configurationSHA256: String, layers: [Layer], ingress: Part, egress: Part, excluded: Part,
                admittedCuts: [Int], structuralCuts: [Int], generationModes: [ClusterGenerationMode],
                prefillSchedules: [ClusterPrefillSchedule], maximumPromptTokens: Int, maximumOutputTokens: Int,
                maximumChunkTokens: Int, boundaryBytesPerToken: Int, requestChargeEveryRankBytes: Int,
                requestChargeEveryRankBytesPerToken: Int? = nil) {
        self.schema = schema; self.runtimeModelID = runtimeModelID; self.artifactSHA256 = artifactSHA256
        self.configurationSHA256 = configurationSHA256; self.layers = layers; self.ingress = ingress
        self.egress = egress; self.excluded = excluded; self.admittedCuts = admittedCuts
        self.structuralCuts = structuralCuts; self.generationModes = generationModes
        self.prefillSchedules = prefillSchedules; self.maximumPromptTokens = maximumPromptTokens
        self.maximumOutputTokens = maximumOutputTokens; self.maximumChunkTokens = maximumChunkTokens
        self.boundaryBytesPerToken = boundaryBytesPerToken; self.requestChargeEveryRankBytes = requestChargeEveryRankBytes
        self.requestChargeEveryRankBytesPerToken = requestChargeEveryRankBytesPerToken
    }

    /// The every-rank charge for a request of `context` tokens.
    public func requestChargeEveryRankBytes(context: Int) -> Int {
        guard let perToken = requestChargeEveryRankBytesPerToken, context < maximumContextTokens else {
            return requestChargeEveryRankBytes
        }
        return max(0, requestChargeEveryRankBytes - perToken * (maximumContextTokens - max(0, context)))
    }

    public var layerCount: Int { layers.count }
    public var maximumContextTokens: Int { maximumPromptTokens + maximumOutputTokens }
    /// Bytes the ranges of a placement hold together. A tensor both ends load
    /// is counted at each end, as it is held at each.
    public var wholeModelLoadedBytes: Int {
        ingress.loadedBytes + egress.loadedBytes + layers.reduce(0) { $0 + $1.weights.loadedBytes }
    }

    public func validate() throws {
        guard schema == Self.schemaName, (2...1024).contains(layers.count),
              layers.enumerated().allSatisfy({ $0.offset == $0.element.index && $0.element.cost > 0
                  && $0.element.cost.isFinite && $0.element.stateFixedBytes >= 0
                  && $0.element.stateBytesPerToken >= 0 && !$0.element.kind.isEmpty
                  && ($0.element.transientBytesPerQuery ?? 0) >= 0 && ($0.element.transientBytesPerQueryKey ?? 0) >= 0
                  && ($0.element.transientKeyWindow ?? 1) > 0 }),
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
              boundaryBytesPerToken > 0, requestChargeEveryRankBytes >= 0,
              (requestChargeEveryRankBytesPerToken ?? 0) >= 0, (allowanceEveryRankBytes ?? 0) >= 0 else {
            throw ClusterPlacementError("Model layout is malformed")
        }
        // The head is part of what no range loads, and its credit is a speed-up.
        guard speculativeHead.map({ head in
                  head.tensorCount > 0 && head.storedBytes > 0 && head.loadedBytes > 0
                      && head.largestTensorBytes <= head.loadedBytes && head.requestWorkBytes >= 0
                      && head.storedBytes <= excluded.storedBytes && head.tensorCount <= excluded.tensorCount
              }) ?? true,
              speculativeDecodeFactor.map({ $0.isFinite && $0 >= 1 && $0 <= 8 }) ?? true,
              speculativeDecodeFactor == nil || generationModes.contains(.phaseSplitMTP) else {
            throw ClusterPlacementError("Model layout's speculative head is malformed")
        }
        try tensorParallel?.validate(layout: self)
        try routedExperts?.validate(layout: self)
    }

    /// The same layout with tensor-parallel facts (a constructed layout, or
    /// one read from a file written before they were derived); validated.
    /// A layout with routed experts keeps their divided bytes as derived:
    /// rebuild it instead of replacing its plan.
    public func with(tensorParallel facts: ClusterTensorParallelLayout?) throws -> ClusterModelLayout {
        var copy = self
        copy.tensorParallel = facts
        try copy.validate()
        return copy
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
        /// Each layer's attention transient. Layers run one after another, so
        /// a range's transient is its largest layer's.
        public let transients: [ClusterPlacementLayerTransient]
        public func stateBytes(tokens: Int) -> Int { stateFixedBytes + stateBytesPerToken * tokens }
        /// The largest attention transient of one prefill frame of `chunk`
        /// query tokens at `context` tokens on any layer of this range.
        public func transientBytes(chunk: Int, context: Int) -> Int {
            transients.map { $0.bytes(chunk: chunk, context: context) }.max() ?? 0
        }
    }

    /// The range `[lower, upper)`, with the ingress when it starts at layer 0
    /// and the egress when it ends at the last layer.
    public func range(_ bounds: Swift.Range<Int>) -> Range {
        var part = Part(), cost = 0.0, fixed = 0, perToken = 0
        var transients: [ClusterPlacementLayerTransient] = []
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
            if layer.transient != .none, !transients.contains(layer.transient) { transients.append(layer.transient) }
        }
        return .init(layers: bounds, loadedBytes: part.loadedBytes, largestTensorBytes: part.largestTensorBytes,
            tensorCount: part.tensorCount, requestWorkBytes: part.requestWorkBytes, cost: cost,
            stateFixedBytes: fixed, stateBytesPerToken: perToken, transients: transients)
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

/// The attention transient of one prefill frame on one layer, as the owner's
/// planner prices it beside the KV (oMLX `_sdpa_transient_for_stage`, U#3651:
/// without it, head-dimension-256 models were oversold by about a quarter).
/// For `q` query tokens attending over `k` keys: `q * bytesPerQuery` (the
/// output) plus `q * k * bytesPerQueryKey` (an unfused kernel's scores).
public struct ClusterPlacementLayerTransient: Equatable, Hashable, Sendable {
    public let bytesPerQuery: Int
    public let bytesPerQueryKey: Int
    /// The most keys one query attends over (a sliding window plus the frame);
    /// nil for the whole context.
    public let keyWindow: Int?
    public static let none = ClusterPlacementLayerTransient(bytesPerQuery: 0, bytesPerQueryKey: 0, keyWindow: nil)
    public init(bytesPerQuery: Int, bytesPerQueryKey: Int, keyWindow: Int?) {
        self.bytesPerQuery = bytesPerQuery; self.bytesPerQueryKey = bytesPerQueryKey; self.keyWindow = keyWindow
    }

    /// MLX's fused attention kernel takes these head dimensions; any other
    /// takes the unfused path, which materializes float32 scores for every key.
    public static let fusedHeadDimensions: Set<Int> = [64, 72, 80, 96, 128]

    /// The transient of an attention layer with this many query heads of this
    /// width, keeping `keyWindow` keys (nil for the whole context). The output
    /// and the scores are float32, as `QwenResidentPrefillTransient` prices them.
    public static func attention(queryHeads: Int, headDimension: Int, keyWindow: Int? = nil) -> Self {
        .init(bytesPerQuery: queryHeads * headDimension * 4,
              bytesPerQueryKey: fusedHeadDimensions.contains(headDimension) ? 0 : queryHeads * 4, keyWindow: keyWindow)
    }

    public func bytes(chunk: Int, context: Int) -> Int {
        let queries = max(0, min(chunk, context))
        let keys = keyWindow.map { min($0, context) } ?? context
        return queries * bytesPerQuery + queries * max(0, keys) * bytesPerQueryKey
    }
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
    /// See `ClusterModelLayout.requestChargeEveryRankBytesPerToken`.
    var requestChargeEveryRankBytesPerToken: Int? { get }
    /// See `ClusterModelLayout.allowanceEveryRankBytes`.
    var allowanceEveryRankBytes: Int? { get }
    var reservesFullRequestScope: Bool { get }

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
    /// True for a tensor both the first and the last range load (a tied
    /// embedding: read on the way in and again as the output projection).
    func loadsAtBothEnds(storedTensor name: String) -> Bool
    /// True for a tensor of the model's own speculative (MTP) head: no range
    /// loads it; the decoding rank of `phase_split_mtp_v1` loads it beside
    /// its stages.
    func isSpeculativeHead(storedTensor name: String) -> Bool
    /// See `ClusterModelLayout.speculativeDecodeFactor`.
    var speculativeDecodeFactor: Double? { get }
    /// The family's tensor-parallel plan for this model; nil when it has none.
    var tensorParallelPlan: ClusterTensorParallelFamilyPlan? { get }
    /// How a mixture-of-experts family routes a token; nil for a family
    /// without routed experts (or one that does not state its routing).
    var expertRouting: ClusterExpertRouting? { get }
    /// True for a layer's tensor of a routed expert: one decode step reads it
    /// only when the token is routed to that expert.
    func isRoutedExpert(storedTensor name: String) -> Bool
    /// How that plan treats a tensor some range loads; nil when the plan does
    /// not cover it (the layout is then refused: a plan covers every tensor).
    func tensorParallelCut(ofStoredTensor name: String) -> ClusterTensorParallelTensorCut?
    /// Relative compute cost of a layer. 1 for every layer unless the family
    /// has measured its kinds apart.
    func layerCost(_ layer: Int) -> Double
    /// The attention transient of one prefill frame on a layer; `.none` for a
    /// layer that does not attend.
    func prefillTransient(layer: Int) -> ClusterPlacementLayerTransient
}

extension ClusterPlacementFamily {
    public var structuralCuts: [Int] { admittedCuts }
    public var requestChargeEveryRankBytes: Int { 0 }
    public var requestChargeEveryRankBytesPerToken: Int? { nil }
    public var allowanceEveryRankBytes: Int? { nil }
    public var reservesFullRequestScope: Bool { false }
    public func loadedBytes(ofStoredTensor name: String, storedBytes: Int) -> Int { storedBytes }
    public func requestWorkBytes(ofStoredTensor name: String, storedBytes: Int) -> Int { 0 }
    public func loadsAtBothEnds(storedTensor name: String) -> Bool { false }
    public func isSpeculativeHead(storedTensor name: String) -> Bool { false }
    public var speculativeDecodeFactor: Double? { nil }
    public var tensorParallelPlan: ClusterTensorParallelFamilyPlan? { nil }
    public func tensorParallelCut(ofStoredTensor name: String) -> ClusterTensorParallelTensorCut? { nil }
    public var expertRouting: ClusterExpertRouting? { nil }
    public func isRoutedExpert(storedTensor name: String) -> Bool { false }
    public func layerCost(_ layer: Int) -> Double { 1 }
    public func prefillTransient(layer: Int) -> ClusterPlacementLayerTransient { .none }
}

/// Builds a layout from an artifact's tensor headers through a family's stage
/// plan, and refuses a family whose answers are not a contiguous layer
/// pipeline or do not conserve the artifact's bytes.
public enum ClusterModelLayoutBuilder {
    /// GLM's packed expert inventory has 114,160 entries. Keep schema input
    /// bounded independently of the much smaller encoded placement summary.
    public static let maximumTensorCount = 200_000

    public static func build(family: some ClusterPlacementFamily, tensors: [ClusterPlacementStoredTensor],
                             artifactSHA256: String, configurationSHA256: String) throws -> ClusterModelLayout {
        let count = family.layerCount, cuts = family.structuralCuts
        guard (2...1024).contains(count), !cuts.isEmpty, cuts == Array(Set(cuts)).sorted(),
              cuts.allSatisfy({ (1..<count).contains($0) }),
              Set(family.admittedCuts).isSubset(of: Set(cuts)),
              (1...maximumTensorCount).contains(tensors.count), Set(tensors.map(\.name)).count == tensors.count else {
            throw ClusterPlacementError("A layout needs at least two layers, one cut and a bounded list of distinct tensors")
        }
        var layers = [ClusterModelLayout.Part](repeating: .init(), count: count)
        var ingress = ClusterModelLayout.Part(), egress = ClusterModelLayout.Part(), excluded = ClusterModelLayout.Part()
        var head = ClusterModelLayout.Part()
        var stored = 0, loadedTotal = 0, workTotal = 0
        // Divided and replicated loaded bytes of each layer, then ingress and egress.
        let tensorPlan = family.tensorParallelPlan
        var tpLayers = [(divided: Int, replicated: Int)](repeating: (0, 0), count: count)
        var tpIngress = (divided: 0, replicated: 0), tpEgress = (divided: 0, replicated: 0)
        // Loaded bytes of the routed experts, and of them the plan's divided bytes.
        let routing = family.expertRouting
        var routed = (loaded: 0, divided: 0)
        func tensorParallelCut(_ name: String) throws -> ClusterTensorParallelTensorCut? {
            guard tensorPlan != nil else { return nil }
            guard let cut = family.tensorParallelCut(ofStoredTensor: name) else {
                throw ClusterPlacementError("The family's tensor-parallel plan does not cover tensor \(name)")
            }
            return cut
        }
        func add(_ cut: ClusterTensorParallelTensorCut?, _ loaded: Int, to part: inout (divided: Int, replicated: Int)) {
            switch cut {
            case .divided: part.divided += loaded
            case .replicated: part.replicated += loaded
            case nil: break
            }
        }
        for tensor in tensors {
            guard tensor.byteCount > 0 else { throw ClusterPlacementError("Tensor \(tensor.name) has no bytes") }
            stored = try addingBytes(stored, tensor.byteCount)
            let stages = try cuts.map { try family.stage(ofStoredTensor: tensor.name, cut: $0) }
            let loaded = family.loadedBytes(ofStoredTensor: tensor.name, storedBytes: tensor.byteCount)
            let work = family.requestWorkBytes(ofStoredTensor: tensor.name, storedBytes: tensor.byteCount)
            guard loaded > 0, work >= 0 else { throw ClusterPlacementError("Tensor \(tensor.name) has an invalid loaded size") }
            let replicated = family.loadsAtBothEnds(storedTensor: tensor.name)
            // Bound all positive partitions and replicas before their Part/TP
            // accumulators run, including sums spanning different layers.
            loadedTotal = try addingBytes(loadedTotal, loaded)
            workTotal = try addingBytes(workTotal, work)
            if replicated {
                loadedTotal = try addingBytes(loadedTotal, loaded)
                workTotal = try addingBytes(workTotal, work)
                // Stored once, held by both ends. A layer's tensor cannot be.
                guard family.layer(ofStoredTensor: tensor.name) == nil else {
                    throw ClusterPlacementError("Tensor \(tensor.name) names a layer and cannot load at both ends")
                }
                ingress.add(stored: tensor.byteCount, loaded: loaded, work: work)
                egress.add(stored: 0, loaded: loaded, work: work)
                let cut = try tensorParallelCut(tensor.name)
                add(cut, loaded, to: &tpIngress); add(cut, loaded, to: &tpEgress)
                continue
            }
            if stages.allSatisfy({ $0 == nil }) {
                guard family.layer(ofStoredTensor: tensor.name) == nil else {
                    throw ClusterPlacementError("Tensor \(tensor.name) names a layer but no stage loads it")
                }
                excluded.add(stored: tensor.byteCount, loaded: tensor.byteCount, work: 0)
                if family.isSpeculativeHead(storedTensor: tensor.name) {
                    head.add(stored: tensor.byteCount, loaded: loaded, work: 0)
                }
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
                let cut = try tensorParallelCut(tensor.name)
                add(cut, loaded, to: &tpLayers[layer])
                if routing != nil, family.isRoutedExpert(storedTensor: tensor.name) {
                    routed.loaded += loaded
                    if cut == .divided { routed.divided += loaded }
                }
            } else if stages.allSatisfy({ $0 == 0 }) {
                ingress.add(stored: tensor.byteCount, loaded: loaded, work: work)
                add(try tensorParallelCut(tensor.name), loaded, to: &tpIngress)
            } else if stages.allSatisfy({ $0 == 1 }) {
                egress.add(stored: tensor.byteCount, loaded: loaded, work: work)
                add(try tensorParallelCut(tensor.name), loaded, to: &tpEgress)
            } else {
                throw ClusterPlacementError("Tensor \(tensor.name) changes stage with the cut but names no layer")
            }
        }
        guard layers.allSatisfy({ $0.tensorCount > 0 }) else {
            throw ClusterPlacementError("A layer has no stored tensor: the headers and the configuration disagree")
        }
        guard stored == ingress.storedBytes + egress.storedBytes + excluded.storedBytes
                + layers.reduce(0, { $0 + $1.storedBytes }) else {
            throw ClusterPlacementError("Layout does not conserve the artifact's stored bytes")
        }
        var value = ClusterModelLayout(schema: ClusterModelLayout.schemaName, runtimeModelID: family.runtimeModelID,
            artifactSHA256: artifactSHA256, configurationSHA256: configurationSHA256,
            layers: try layers.enumerated().map { index, weights in
                let state = try family.requestState(layer: index)
                return ClusterModelLayout.Layer(index: index, kind: family.layerKind(index), weights: weights,
                    stateFixedBytes: state.fixedBytes, stateBytesPerToken: state.bytesPerToken, cost: family.layerCost(index),
                    transient: family.prefillTransient(layer: index))
            },
            ingress: ingress, egress: egress, excluded: excluded,
            admittedCuts: family.admittedCuts, structuralCuts: cuts,
            generationModes: family.generationModes, prefillSchedules: family.prefillSchedules,
            maximumPromptTokens: family.maximumPromptTokens, maximumOutputTokens: family.maximumOutputTokens,
            maximumChunkTokens: family.maximumChunkTokens, boundaryBytesPerToken: family.boundaryBytesPerToken,
            requestChargeEveryRankBytes: family.requestChargeEveryRankBytes,
            requestChargeEveryRankBytesPerToken: family.requestChargeEveryRankBytesPerToken)
        value.allowanceEveryRankBytes = family.allowanceEveryRankBytes
        value.reservesFullRequestScope = family.reservesFullRequestScope ? true : nil
        try value.validate()
        // The head no range loads, and the speed-up the family's row credits it with.
        var built = value
        built.speculativeHead = head.tensorCount > 0 ? head : nil
        built.speculativeDecodeFactor = family.speculativeDecodeFactor
        built.tensorParallel = tensorPlan.map { plan in
            ClusterTensorParallelLayout(family: plan, layerDividedBytes: tpLayers.map(\.divided),
                layerReplicatedBytes: tpLayers.map(\.replicated), ingressDividedBytes: tpIngress.divided,
                ingressReplicatedBytes: tpIngress.replicated, egressDividedBytes: tpEgress.divided,
                egressReplicatedBytes: tpEgress.replicated)
        }
        if let routing {
            guard routed.loaded > 0 else {
                throw ClusterPlacementError("The family routes to experts, but no layer stores a routed expert")
            }
            built.routedExperts = ClusterRoutedExperts(routing: routing, loadedBytes: routed.loaded,
                tensorParallelDividedBytes: tensorPlan == nil ? nil : routed.divided)
        }
        try built.validate()
        return built
    }

    private static func addingBytes(_ lhs: Int, _ rhs: Int) throws -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { throw ClusterPlacementError("Model layout byte total exceeds Int capacity") }
        return result.partialValue
    }
}
