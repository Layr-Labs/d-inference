import Foundation

/// Scalar page order for the SDK's GPT-OSS caches. Full attention appends;
/// sliding attention preserves RotatingKVCache(keep: 0)'s physical order on
/// decode and its chronological, window-minus-one prefix on a chunk.
struct GPTOSSPagedKVLayout: Equatable {
    static let pageTokens = 64
    static let agreementFields = ["gptoss-paged-kv-v1", "page=64", "sliding=rotating-keep0"]
    let window: Int?
    private(set) var offset = 0
    private(set) var count = 0
    private(set) var index = 0

    struct Update: Equatable {
        /// Nil keeps the existing pages. Otherwise these old physical rows
        /// become the new prefix before the incoming rows are appended.
        let retained: [Range<Int>]?
        let writeOffset: Int
        let count: Int
    }

    init(window: Int? = nil) {
        precondition(window == nil || window! > 0)
        self.window = window
    }

    mutating func append(_ n: Int) -> Update {
        precondition(n > 0 && offset <= Int.max - n)
        defer { offset += n }
        guard let window else {
            let start = count
            count += n; index = count
            return .init(retained: nil, writeOffset: start, count: count)
        }
        if n > 1 {
            var ranges: [Range<Int>]
            if index == count { ranges = count == 0 ? [] : [0..<count] }
            else if index < offset { ranges = [index..<count, 0..<index] }
            else { ranges = [0..<index] }
            var drop = max(0, ranges.reduce(0) { $0 + $1.count } - window + 1)
            ranges = ranges.compactMap { range in
                let discarded = min(drop, range.count)
                drop -= discarded
                let kept = (range.lowerBound + discarded)..<range.upperBound
                return kept.isEmpty ? nil : kept
            }
            let kept = ranges.reduce(0) { $0 + $1.count }
            count = kept + n; index = count
            return .init(retained: ranges, writeOffset: kept, count: count)
        }
        var retained: [Range<Int>]?
        if count > window {
            retained = [(count - window)..<count]
            count = window; index = window
        }
        if index == window { index = 0 }
        let start = index
        index += 1; count = max(count, index)
        return .init(retained: retained, writeOffset: start, count: count)
    }

    var isTrimmable: Bool { window.map { offset < $0 } ?? true }

    mutating func trim(_ n: Int) -> Int {
        guard isTrimmable else { return 0 }
        let removed = min(offset, max(0, n))
        offset -= removed; count = offset; index = offset
        return removed
    }

    mutating func restore(count: Int, offset: Int, index: Int) {
        precondition(count >= 0 && offset >= count && index >= 0 && index <= count)
        self.count = count; self.offset = offset; self.index = index
    }
}
