import Foundation

/// Attention-only, prefix-off, ordinary request geometry. No model selection or
/// resource admission is granted by this value; the caller owns those gates.
struct LayerAttentionStateLayout: Sendable, Equatable {
    enum Element: String, Sendable, Equatable {
        case float16, bfloat16, float32
        var bytes: Int { self == .float32 ? 4 : 2 }
    }
    struct Layer: Sendable, Equatable {
        let globalIndex: Int
        let kvHeads: Int
        let headDimension: Int
        /// nil is full attention. A window is physical ring capacity too.
        let window: Int?
        let element: Element
    }
    let layers: [Layer]
    let maximumTokens: Int
    let maximumChunkTokens: Int
    /// Existing contiguous backend estimates with one dtype. Explicitly charge
    /// the widest observed dtype for EVERY row, including full window rings.
    let conservativeKVCapacityBytes: Int
    let exactKVCapacityBytes: Int
    /// Conservative activation-ledger term: retained chunk views plus an old
    /// ring backing. This is additional to the backend's KV capacity.
    let windowTemporaryBytes: Int
    let fingerprint: String

    init(layers: [Layer], maximumTokens: Int, maximumChunkTokens: Int) throws {
        guard (1...128).contains(layers.count), (1...32_768).contains(maximumTokens),
              (1...min(maximumTokens, 8192)).contains(maximumChunkTokens),
              Set(layers.map(\.globalIndex)).count == layers.count,
              layers.map(\.globalIndex) == layers.map(\.globalIndex).sorted() else {
            throw ProbeError("Attention state needs bounded ordered unique layer coverage")
        }
        let widest = layers.map { $0.element.bytes }.max()!
        var exact = 0, conservative = 0, temporary = 0
        for layer in layers {
            guard (0..<4096).contains(layer.globalIndex), (1...1024).contains(layer.kvHeads),
                  (1...1024).contains(layer.headDimension),
                  layer.window.map({ (1...32_768).contains($0) }) ?? true else {
                throw ProbeError("Attention layer geometry exceeds bounded metadata")
            }
            let slots = layer.window ?? maximumTokens
            exact = try Self.sum(exact, Self.bytes(layer, tokens: slots, elementBytes: layer.element.bytes))
            conservative = try Self.sum(conservative, Self.bytes(layer, tokens: slots, elementBytes: widest))
            if let window = layer.window {
                let temporarySlots = try Self.sum(window, Self.sum(window - 1, maximumChunkTokens))
                temporary = try Self.sum(temporary, Self.bytes(layer, tokens: temporarySlots, elementBytes: layer.element.bytes))
            }
        }
        self.layers = layers; self.maximumTokens = maximumTokens; self.maximumChunkTokens = maximumChunkTokens
        exactKVCapacityBytes = exact; conservativeKVCapacityBytes = conservative; windowTemporaryBytes = temporary
        let rows = layers.enumerated().map { index, layer in
            "\(index)|\(layer.globalIndex)|\(layer.kvHeads)|\(layer.headDimension)|\(layer.window.map { String($0) } ?? "full")|\(layer.element.rawValue)"
        }
        fingerprint = sha256(Data((["attention-state-layout-v1", "maximumTokens=\(maximumTokens)",
            "maximumChunkTokens=\(maximumChunkTokens)", "prefix=false", "speculation=false"] + rows).joined(separator: "\n").utf8))
    }

    func range(layer index: Int, frontier: Int) throws -> Range<Int> {
        guard layers.indices.contains(index), (0...maximumTokens).contains(frontier) else {
            throw ProbeError("Attention logical frontier is outside its admitted layout")
        }
        return max(0, frontier - (layers[index].window ?? frontier))..<frontier
    }

    static func bytes(_ layer: Layer, tokens: Int, elementBytes: Int) throws -> Int {
        guard tokens >= 0, elementBytes > 0 else { throw ProbeError("Negative attention byte geometry") }
        return try [tokens, layer.kvHeads, layer.headDimension, elementBytes, 2].reduce(1) { a, b in
            let value = a.multipliedReportingOverflow(by: b)
            guard !value.overflow else { throw ProbeError("Attention state byte count overflow") }
            return value.partialValue
        }
    }
    static func sum(_ a: Int, _ b: Int) throws -> Int {
        let value = a.addingReportingOverflow(b)
        guard a >= 0, b >= 0, !value.overflow else { throw ProbeError("Attention state byte sum overflow") }
        return value.partialValue
    }
}
