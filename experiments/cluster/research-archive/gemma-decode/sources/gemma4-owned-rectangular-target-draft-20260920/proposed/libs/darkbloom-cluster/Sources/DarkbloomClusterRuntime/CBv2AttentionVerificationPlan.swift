import Foundation

/// Additional, explicitly admitted state work over an unchanged ordinary
/// layout. This value is not memory authority or a whole-model peak bound.
struct CBv2AttentionVerificationPlan {
    struct ArrayTerm { let name: String; let bytes: Int }
    let layout: LayerAttentionStateLayout
    let base: Int
    let steps: Int
    let captureLayerIndices: [Int]
    let stagedWindowBytes: Int
    let backendCapacityBytes: Int
    let additionalArrays: [ArrayTerm]
    let additionalLogicalBytes: Int
    let fingerprint: String

    init(layout: LayerAttentionStateLayout, base: Int, steps: Int, captureLayerIndices: [Int]) throws {
        guard base > 0, base <= layout.maximumTokens, (1...4).contains(steps),
              steps <= layout.maximumChunkTokens, steps <= layout.maximumTokens - base,
              captureLayerIndices.count <= 2, Set(captureLayerIndices).count == captureLayerIndices.count,
              captureLayerIndices.allSatisfy({ layout.layers.indices.contains($0) }) else {
            throw ProbeError("Attention verification exceeds the unchanged context/chunk/capture envelope")
        }
        self.layout = layout; self.base = base; self.steps = steps
        self.captureLayerIndices = captureLayerIndices
        var arrays: [ArrayTerm] = [], staged = 0
        func add(_ name: String, _ layer: LayerAttentionStateLayout.Layer, _ tokens: Int) throws {
            // K and V are separate allocations and must be rounded separately.
            let bytes = try LayerAttentionStateLayout.bytes(layer, tokens: tokens, elementBytes: layer.element.bytes) / 2
            for component in ["keys", "values"] { arrays.append(.init(name: name + ":" + component, bytes: bytes)) }
        }
        for (index, layer) in layout.layers.enumerated() {
            if let window = layer.window {
                staged = try LayerAttentionStateLayout.sum(staged,
                    LayerAttentionStateLayout.bytes(layer, tokens: steps, elementBytes: layer.element.bytes))
                try add("layer\(index):staged", layer, steps)
                // Existing ordinary windowTemporaryBytes stays charged. These
                // additional roots cover staged view assembly and commit copy;
                // no unproved graph-lifetime discount is taken.
                try add("layer\(index):stagedLogicalView", layer, window + steps)
                try add("layer\(index):commitBacking", layer, window)
            }
            if captureLayerIndices.contains(index) {
                try add("layer\(index):capturedBacking", layer, layer.window ?? layout.maximumTokens)
                if let window = layer.window { try add("layer\(index):capturedChronology", layer, window) }
            }
        }
        stagedWindowBytes = staged
        backendCapacityBytes = try LayerAttentionStateLayout.sum(layout.conservativeKVCapacityBytes, staged)
        additionalArrays = arrays
        additionalLogicalBytes = try arrays.reduce(0) { try LayerAttentionStateLayout.sum($0, $1.bytes) }
        fingerprint = sha256(Data((["cbv2-owned-attention-verification-v1", layout.fingerprint,
            "base=\(base)", "steps=\(steps)", "captures=\(captureLayerIndices)"]
            + arrays.map { "\($0.name)|\($0.bytes)" }).joined(separator: "\n").utf8))
    }
}
