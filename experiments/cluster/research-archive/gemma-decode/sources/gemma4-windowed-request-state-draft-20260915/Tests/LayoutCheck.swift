import Foundation

@main struct LayoutCheck {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw ProbeError("Expected pinned Gemma config fixture") }
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        guard data.count <= 1_048_576,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = root["text_config"] as? [String: Any],
              let kinds = text["layer_types"] as? [String], kinds.count == 30,
              let window = text["sliding_window"] as? Int,
              let slidingHeads = text["num_key_value_heads"] as? Int,
              let fullHeads = text["num_global_key_value_heads"] as? Int,
              let slidingDimension = text["head_dim"] as? Int,
              let fullDimension = text["global_head_dim"] as? Int,
              text["num_kv_shared_layers"] as? Int == 0 else { throw ProbeError("Gemma metadata fixture differs") }
        var checks = 0, refusals = 0
        func require(_ value: Bool) throws { guard value else { throw ProbeError("Layout assertion failed") }; checks += 1 }
        func refuse(_ body: () throws -> Void) throws {
            do { try body() } catch { refusals += 1; return }
            throw ProbeError("Malformed layout was accepted")
        }
        let layers: [LayerAttentionStateLayout.Layer] = kinds.enumerated().map { global, kind in
            let full = kind == "full_attention"
            return .init(globalIndex: global, kvHeads: full ? fullHeads : slidingHeads,
                headDimension: full ? fullDimension : slidingDimension, window: full ? nil : window,
                element: global.isMultiple(of: 2) ? .bfloat16 : .float32)
        }
        for cut in 1..<30 {
            var seen: [Int] = [], exact = 0, conservative = 0
            for range in [0..<cut, cut..<30] {
                let local = Array(layers[range])
                let layout = try LayerAttentionStateLayout(layers: local, maximumTokens: 8320, maximumChunkTokens: 512)
                seen += layout.layers.map(\.globalIndex)
                let widest = local.map { $0.element.bytes }.max()!
                let independentExact = local.reduce(0) { $0 + ($1.window ?? 8320) * $1.kvHeads * $1.headDimension * $1.element.bytes * 2 }
                let independentConservative = local.reduce(0) { $0 + ($1.window ?? 8320) * $1.kvHeads * $1.headDimension * widest * 2 }
                try require(layout.exactKVCapacityBytes == independentExact)
                try require(layout.conservativeKVCapacityBytes == independentConservative)
                try require(layout.conservativeKVCapacityBytes >= layout.exactKVCapacityBytes)
                exact += layout.exactKVCapacityBytes; conservative += layout.conservativeKVCapacityBytes
                for frontier in [0, 1, 1023, 1024, 1025, 8192, 8319, 8320] {
                    for index in local.indices {
                        let observed = try layout.range(layer: index, frontier: frontier)
                        let count = min(frontier, local[index].window ?? frontier)
                        try require(observed.upperBound == frontier && observed.count == count)
                        try require(observed.lowerBound == frontier - count)
                    }
                }
                try require(layout.fingerprint == LayerAttentionStateLayout(layers: local,
                    maximumTokens: 8320, maximumChunkTokens: 512).fingerprint)
                try refuse { _ = try layout.range(layer: local.count, frontier: 1) }
                try refuse { _ = try layout.range(layer: 0, frontier: 8321) }
            }
            try require(seen == Array(0..<30) && conservative >= exact)
        }
        let base = layers[0]
        for malformed in [
            LayerAttentionStateLayout.Layer(globalIndex: -1, kvHeads: 8, headDimension: 256, window: 1024, element: .bfloat16),
            .init(globalIndex: 0, kvHeads: 0, headDimension: 256, window: 1024, element: .bfloat16),
            .init(globalIndex: 0, kvHeads: 8, headDimension: Int.max, window: 1024, element: .bfloat16),
            .init(globalIndex: 0, kvHeads: 8, headDimension: 256, window: 0, element: .bfloat16),
            .init(globalIndex: 0, kvHeads: 8, headDimension: 256, window: Int.max, element: .bfloat16)
        ] { try refuse { _ = try LayerAttentionStateLayout(layers: [malformed], maximumTokens: 160, maximumChunkTokens: 16) } }
        try refuse { _ = try LayerAttentionStateLayout(layers: [base, base], maximumTokens: 160, maximumChunkTokens: 16) }
        try refuse { _ = try LayerAttentionStateLayout(layers: [layers[1], base], maximumTokens: 160, maximumChunkTokens: 16) }
        try refuse { _ = try LayerAttentionStateLayout(layers: [], maximumTokens: 160, maximumChunkTokens: 16) }
        for (tokens, chunk) in [(0,1), (Int.max,1), (160,0), (160,161)] {
            try refuse { _ = try LayerAttentionStateLayout(layers: [base], maximumTokens: tokens, maximumChunkTokens: chunk) }
        }
        let bf16 = try LayerAttentionStateLayout(layers: [base], maximumTokens: 160, maximumChunkTokens: 16)
        let fp16 = try LayerAttentionStateLayout(layers: [.init(globalIndex: base.globalIndex, kvHeads: base.kvHeads,
            headDimension: base.headDimension, window: base.window, element: .float16)], maximumTokens: 160, maximumChunkTokens: 16)
        try require(bf16.exactKVCapacityBytes == fp16.exactKVCapacityBytes && bf16.fingerprint != fp16.fingerprint)
        try require(bf16.exactKVCapacityBytes == 1024 * 8 * 256 * 2 * 2)
        print("PASS \(checks) checks / \(refusals) refusals; metadata only; no native execution")
    }
}
