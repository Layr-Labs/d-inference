import Foundation
import MLXLLM

/// Source ownership only. This is deliberately not a ClusterPlacementFamily:
/// request state, workspace, schedules and admitted cuts still need the runtime
/// adapter and qualification. Stored bytes are not a loaded-memory allowance.
struct GLM5NextStageLayout {
    struct Part: Equatable, Sendable {
        let bytes: Int
        let tensorCount: Int
        let largestTensorBytes: Int
        static let empty = Self(bytes: 0, tensorCount: 0, largestTensorBytes: 0)

        func adding(_ other: Self) throws -> Self {
            let bytes = bytes.addingReportingOverflow(other.bytes)
            let count = tensorCount.addingReportingOverflow(other.tensorCount)
            guard !bytes.overflow, !count.overflow else { throw ProbeError("GLM source size overflow") }
            return .init(bytes: bytes.partialValue, tensorCount: count.partialValue,
                largestTensorBytes: max(largestTensorBytes, other.largestTensorBytes))
        }
    }

    enum SourceOwner: Equatable, Sendable {
        case embedding, layer(Int), finalNorm, head, mtp, vision
    }

    struct Layer: Equatable, Sendable {
        let globalIndex: Int
        let attention: String
        let feedForward: String
        let source: Part
    }

    struct Stage: Equatable, Sendable {
        let rank: Int
        let globalLayers: Range<Int>
        let source: Part
    }

    struct Split: Equatable, Sendable {
        let cut: Int
        let stages: [Stage]
        /// Vision always; MTP as well when the final stage does not own NextN.
        let excluded: Part
        /// Stored once, additionally held by the final MTP owner.
        let additionalMTPEmbedding: Part
    }

    let layers: [Layer]
    let embedding: Part
    let finalNorm: Part
    let head: Part
    let mtp: Part
    let vision: Part
    let totalSource: Part
    let streamCount: Int
    let hiddenSize: Int
    let boundaryDType: String
    /// Per batch element and token: the entire [hc_mult, hidden_size] stream
    /// matrix, before the final mean/norm. This does not price transfer buffers.
    let boundaryBytesPerToken: Int
    let declaredMaximumPositions: Int
    var structuralCuts: [Int] { Array(1..<layers.count) }
    /// No public/runtime admission is established by metadata.
    var admittedCuts: [Int] { [] }

    private let owners: [String: SourceOwner]
    private let prefixes: [Part]
    private let suffixes: [Part]

    /// The SDK already validates the complete schema, dtypes, packing, sizes
    /// and text/MTP/vision partition. Do not reconstruct that schema here.
    init(inventory: GLM5NextWeightInventory) throws {
        let c = inventory.configuration.textConfig
        guard (2...512).contains(c.hiddenLayers), c.numNextNPredictLayers == 1,
              c.hcMult == 4, inventory.entries.count <= 200_000 else {
            throw ProbeError("GLM stage layout requires bounded layers and one trained NextN layer")
        }
        let elementBytes: Int
        switch c.dtype {
        case "bfloat16": elementBytes = 2
        case "float32": elementBytes = 4 // Explicit synthetic/reference inventories.
        default: throw ProbeError("Unsupported GLM stage stream dtype")
        }
        let width = c.hiddenSize.multipliedReportingOverflow(by: c.hcMult)
        let boundary = width.partialValue.multipliedReportingOverflow(by: elementBytes)
        guard !width.overflow, !boundary.overflow else { throw ProbeError("GLM boundary size overflow") }

        var layerParts = [Part](repeating: .empty, count: c.hiddenLayers)
        var embedding = Part.empty, norm = Part.empty, head = Part.empty
        var mtp = Part.empty, vision = Part.empty, total = Part.empty
        var owners: [String: SourceOwner] = [:]
        owners.reserveCapacity(inventory.entries.count)
        for entry in inventory.entries.values {
            let part = Part(bytes: entry.bytes, tensorCount: 1, largestTensorBytes: entry.bytes)
            let name = entry.tensor.name
            let owner: SourceOwner
            switch entry.part {
            case .vision:
                owner = .vision
                vision = try vision.adding(part)
            case .mtp:
                guard name.hasPrefix("model.language_model.layers.\(c.hiddenLayers).") else {
                    throw ProbeError("GLM MTP must retain its global source layer index")
                }
                owner = .mtp
                mtp = try mtp.adding(part)
            case .text:
                if name.hasPrefix("model.language_model.embed_tokens.") {
                    owner = .embedding
                    embedding = try embedding.adding(part)
                } else if name.hasPrefix("model.language_model.norm.") {
                    owner = .finalNorm
                    norm = try norm.adding(part)
                } else if name.hasPrefix("lm_head.") {
                    owner = .head
                    head = try head.adding(part)
                } else {
                    let prefix = "model.language_model.layers."
                    guard name.hasPrefix(prefix),
                          let first = name.dropFirst(prefix.count).split(separator: ".").first,
                          let index = Int(first), String(index) == String(first),
                          layerParts.indices.contains(index) else {
                        throw ProbeError("Unowned GLM text source tensor: \(name)")
                    }
                    owner = .layer(index)
                    layerParts[index] = try layerParts[index].adding(part)
                }
            }
            owners[name] = owner
            total = try total.adding(part)
        }
        guard layerParts.allSatisfy({ $0.tensorCount > 0 }), embedding.tensorCount > 0,
              norm.tensorCount > 0, head.tensorCount > 0, mtp.tensorCount > 0 else {
            throw ProbeError("Incomplete GLM text/MTP source ownership")
        }
        var prefixes = [Part.empty]
        for part in layerParts { prefixes.append(try prefixes.last!.adding(part)) }
        var suffixes = [Part](repeating: .empty, count: c.hiddenLayers + 1)
        for index in layerParts.indices.reversed() {
            suffixes[index] = try layerParts[index].adding(suffixes[index + 1])
        }
        self.layers = layerParts.enumerated().map {
            .init(globalIndex: $0.offset, attention: c.layerTypes[$0.offset].rawValue,
                feedForward: c.mlpLayerTypes[$0.offset].rawValue, source: $0.element)
        }
        self.embedding = embedding; finalNorm = norm; self.head = head
        self.mtp = mtp; self.vision = vision; totalSource = total
        self.owners = owners; self.prefixes = prefixes; self.suffixes = suffixes
        streamCount = c.hcMult; hiddenSize = c.hiddenSize; boundaryDType = c.dtype
        boundaryBytesPerToken = boundary.partialValue
        declaredMaximumPositions = c.maxPositionEmbeddings
    }

    /// O(1) per cut after one bounded inventory scan and two layer scans.
    /// NextN is additional source layer `hiddenLayers`, never decoder layer 46.
    func split(at cut: Int, includeMTP: Bool) throws -> Split {
        try requireCut(cut)
        let first = try embedding.adding(prefixes[cut])
        var last = try suffixes[cut].adding(finalNorm).adding(head)
        if includeMTP { last = try last.adding(mtp).adding(embedding) }
        let excluded: Part
        if includeMTP { excluded = vision } else { excluded = try vision.adding(mtp) }
        return .init(cut: cut, stages: [
            .init(rank: 0, globalLayers: 0..<cut, source: first),
            .init(rank: 1, globalLayers: cut..<layers.count, source: last),
        ], excluded: excluded,
            additionalMTPEmbedding: includeMTP ? embedding : .empty)
    }

    func allSplits(includeMTP: Bool) throws -> [Split] {
        try structuralCuts.map { try split(at: $0, includeMTP: includeMTP) }
    }

    func sourceOwner(of name: String) throws -> SourceOwner {
        guard let owner = owners[name] else { throw ProbeError("Unknown GLM source tensor: \(name)") }
        return owner
    }

    /// Whole source tensors, with the final-stage MTP embedding explicitly
    /// duplicated. No vision tensor is implicitly routed to a text stage.
    func ranks(of name: String, cut: Int, includeMTP: Bool) throws -> [Int] {
        try requireCut(cut)
        switch try sourceOwner(of: name) {
        case .embedding: return includeMTP ? [0, 1] : [0]
        case .layer(let index): return [index < cut ? 0 : 1]
        case .finalNorm, .head: return [1]
        case .mtp: return includeMTP ? [1] : []
        case .vision: return []
        }
    }

    /// Select only after choosing a cut. Do not materialize 44 name inventories
    /// to compare cuts; `allSplits` supplies their exact byte/count summaries.
    func sourceNames(rank: Int, cut: Int, includeMTP: Bool) throws -> Set<String> {
        guard (0...1).contains(rank) else { throw ProbeError("GLM text stage rank must be 0 or 1") }
        try requireCut(cut)
        return try Set(owners.keys.filter { try ranks(of: $0, cut: cut, includeMTP: includeMTP).contains(rank) })
    }

    private func requireCut(_ cut: Int) throws {
        guard (1..<layers.count).contains(cut) else { throw ProbeError("Invalid GLM structural cut: \(cut)") }
    }
}
