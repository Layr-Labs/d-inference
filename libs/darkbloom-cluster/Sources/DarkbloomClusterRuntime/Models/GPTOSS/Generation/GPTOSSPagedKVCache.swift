import Foundation
import MLX
import MLXLMCommon

/// Request-owned pages, allocated only for rows already forwarded. Attention
/// still receives the SDK cache's exact values, dtype and physical row order;
/// its ordinary SDPA and learned sinks remain unchanged. Gathered arrays are
/// step temporaries, never the persistent history. Engine-thread confined.
final class GPTOSSPagedKVCache: KVCache {
    private struct Page { let keys: MLXArray; let values: MLXArray }
    private var pages: [Page] = []
    private var layout: GPTOSSPagedKVLayout
    private var shape: (heads: Int, keyWidth: Int, valueWidth: Int, dtype: DType)?
    var offset: Int { layout.offset }
    var maxSize: Int? { layout.window }
    var pageCount: Int { pages.count }
    var allocatedBytes: Int { pages.reduce(0) { $0 + $1.keys.nbytes + $1.values.nbytes } }

    init(window: Int? = nil) { layout = .init(window: window) }

    func innerState() -> [MLXArray] { pages.flatMap { [$0.keys, $0.values] } }

    func update(keys: MLXArray, values: MLXArray) -> (MLXArray, MLXArray) {
        precondition(keys.ndim == 4 && values.ndim == 4 && keys.dim(0) == 1 && values.dim(0) == 1
            && keys.dim(1) == values.dim(1) && keys.dim(2) == values.dim(2) && keys.dim(2) > 0
            && keys.dtype == values.dtype)
        if let shape {
            precondition(keys.dim(1) == shape.heads && keys.dim(3) == shape.keyWidth
                && values.dim(3) == shape.valueWidth && keys.dtype == shape.dtype)
        } else {
            shape = (keys.dim(1), keys.dim(3), values.dim(3), keys.dtype)
        }
        let update = layout.append(keys.dim(2))
        if let retained = update.retained {
            let old = pages
            pages = []
            var destination = 0
            for range in retained {
                for piece in Self.pieces(old, range: range) {
                    write(keys: piece.keys, values: piece.values, at: destination)
                    destination += piece.keys.dim(2)
                }
            }
            precondition(destination == update.writeOffset || keys.dim(2) == 1)
        }
        write(keys: keys, values: values, at: update.writeOffset)
        let result = gathered()
        return (result[0], result[1])
    }

    /// Each mutation gets a distinct array handle, so copying this cache can
    /// share old pages without a later slice assignment changing the copy.
    private func write(keys: MLXArray, values: MLXArray, at start: Int) {
        let size = GPTOSSPagedKVLayout.pageTokens
        var source = 0, destination = start
        while source < keys.dim(2) {
            let page = destination / size, row = destination % size
            if page == pages.count {
                let shape = shape!
                pages.append(.init(keys: .zeros([1, shape.heads, size, shape.keyWidth], dtype: shape.dtype),
                    values: .zeros([1, shape.heads, size, shape.valueWidth], dtype: shape.dtype)))
            }
            precondition(page < pages.count)
            let count = min(size - row, keys.dim(2) - source)
            let k = pages[page].keys[.ellipsis], v = pages[page].values[.ellipsis]
            k[.ellipsis, row..<(row + count), 0...] = keys[.ellipsis, source..<(source + count), 0...]
            v[.ellipsis, row..<(row + count), 0...] = values[.ellipsis, source..<(source + count), 0...]
            pages[page] = .init(keys: k, values: v)
            source += count; destination += count
        }
    }

    private static func pieces(_ pages: [Page], range: Range<Int>) -> [Page] {
        let size = GPTOSSPagedKVLayout.pageTokens
        var start = range.lowerBound, result: [Page] = []
        while start < range.upperBound {
            let page = start / size, row = start % size
            let count = min(size - row, range.upperBound - start)
            result.append(.init(keys: pages[page].keys[.ellipsis, row..<(row + count), 0...],
                values: pages[page].values[.ellipsis, row..<(row + count), 0...]))
            start += count
        }
        return result
    }

    private func gathered() -> [MLXArray] {
        guard layout.count > 0 else { return [] }
        let parts = Self.pieces(pages, range: 0..<layout.count)
        if parts.count == 1 { return [parts[0].keys, parts[0].values] }
        return [concatenated(parts.map(\.keys), axis: 2), concatenated(parts.map(\.values), axis: 2)]
    }

    var state: [MLXArray] {
        get { gathered() }
        set {
            precondition(newValue.count == 2 && newValue[0].dim(2) > 0)
            let previousOffset = offset
            let previousIndex = layout.index
            let window = maxSize
            pages = []; shape = nil; layout = .init(window: window)
            _ = update(keys: newValue[0], values: newValue[1])
            if window != nil {
                // Like RotatingKVCache, metadata restoration supplies position
                // separately. Preserve the old position until it is restored.
                layout.restore(count: newValue[0].dim(2), offset: max(previousOffset, newValue[0].dim(2)),
                    index: min(previousIndex, newValue[0].dim(2)))
            }
        }
    }

    var metaState: [String] {
        get {
            if let window = maxSize { return ["0", String(window), "256", String(offset), String(layout.index)] }
            return [""]
        }
        set {
            guard let window = maxSize else {
                precondition(newValue == [""]); return
            }
            precondition(newValue.count == 5 && newValue[0] == "0" && Int(newValue[1]) == window
                && Int(newValue[2]) == 256)
            layout.restore(count: layout.count, offset: Int(newValue[3])!, index: Int(newValue[4])!)
        }
    }

    var isTrimmable: Bool { layout.isTrimmable }
    @discardableResult func trim(_ n: Int) -> Int {
        let removed = layout.trim(n)
        if removed > 0 {
            let count = (layout.count + GPTOSSPagedKVLayout.pageTokens - 1) / GPTOSSPagedKVLayout.pageTokens
            pages = Array(pages.prefix(count))
        }
        return removed
    }

    func makeMask(n: Int, windowSize: Int?, returnArray: Bool) -> MLXFast.ScaledDotProductAttentionMaskMode {
        guard let window = maxSize else {
            if n == 1 { return .none }
            if returnArray || (windowSize != nil && n > windowSize!) {
                return .array(createCausalMask(n: n, offset: offset, windowSize: windowSize))
            }
            return .causal
        }
        if n > 1 {
            let actual = windowSize ?? window, capped = min(window - 1, offset)
            if capped + n > actual || returnArray {
                return .array(createCausalMask(n: n, offset: capped, windowSize: actual))
            }
            return .causal
        }
        if let windowSize, offset >= windowSize, window > windowSize {
            let index = layout.index >= window ? 0 : layout.index
            let count = offset < window ? offset + 1 : window
            let mask = MLXArray(0..<Int32(count)) .>= Int32(count - windowSize)
            return .array(roll(mask, shift: index + 1))
        }
        return .none
    }

    func copy() -> any KVCache {
        let result = GPTOSSPagedKVCache(window: maxSize)
        result.layout = layout; result.shape = shape; result.pages = pages
        return result
    }
}
