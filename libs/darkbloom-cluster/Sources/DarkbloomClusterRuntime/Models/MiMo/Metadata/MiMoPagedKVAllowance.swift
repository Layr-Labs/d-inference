import Foundation

/// Supplements the WHOLE existing contiguous request allowance. Per-page
/// allocator rounding, copy-on-write and gather/repack state are not shared
/// away; unequal key/value widths and full/sliding geometries remain distinct.
enum MiMoPagedKVAllowance {
    static func pages(spec: MiMoRegisteredSpecification, layers: Range<Int>, maximumTokens: Int,
                      chunkSize: Int, bound: (Int) throws -> Int) throws -> Int {
        let limits = try spec.contextLimits()
        guard !layers.isEmpty, layers.lowerBound >= 0, layers.upperBound <= spec.layers,
              (1...limits.maximumContextTokens).contains(maximumTokens),
              (1...limits.maximumChunkTokens).contains(chunkSize) else {
            throw ProbeError("MiMo batch page allowance is outside registered bounds")
        }
        let sum = QwenLongPrefillCheckedBytes.sum, product = QwenLongPrefillCheckedBytes.product
        func charge(_ elements: [Int], copies: Int) throws -> Int {
            let raw = try product(elements), rounded = try bound(raw)
            guard raw > 0, rounded >= raw else { throw ProbeError("MiMo page allocator bound is invalid") }
            return try product([rounded, copies])
        }
        return try sum(layers.map { layer in
            let full = spec.fullAttentionLayers.contains(layer)
            let count = full ? maximumTokens : min(maximumTokens, spec.slidingWindow + chunkSize)
            let heads = full ? spec.fullKeyValueHeads : spec.slidingKeyValueHeads
            let pages = (count + 63) / 64
            return try sum([spec.keyWidth, spec.valueWidth].map { width in
                try sum([charge([heads, 64, width, 2], copies: try product([pages, 2])),
                         charge([heads, count, width, 2], copies: 2)])
            })
        })
    }

}
