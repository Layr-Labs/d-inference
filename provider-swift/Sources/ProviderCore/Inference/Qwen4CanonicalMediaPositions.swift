// Copyright © 2026 Eigen Labs.

/// Proves an appended text tail is exactly reconstructable from its token offset.
/// The prefix through the last media span is still hashed in full. Given that
/// prefix and the decode delta, every later position on every axis is fixed;
/// the existing token-chain and native checkpoint checks remain mandatory.
enum Qwen4CanonicalMediaPositions {
    static func prefixLength<T: FixedWidthInteger>(
        positions: [T], axes: Int, promptLength: Int,
        mediaRanges: [Range<Int>], decodeDelta: Int32
    ) -> Int? {
        guard axes == 3, promptLength > 0, !mediaRanges.isEmpty else { return nil }
        let (count, overflow) = axes.multipliedReportingOverflow(by: promptLength)
        guard !overflow, positions.count == count else { return nil }
        var end = 0
        for span in mediaRanges {
            guard !span.isEmpty, span.lowerBound >= end,
                span.upperBound <= promptLength else { return nil }
            end = span.upperBound
        }
        // The engine's native decode positions use Int32. Do not normalize a
        // tail that relies on clamping/wrapping or an unrepresentable offset.
        let (last, lastOverflow) = Int64(promptLength - 1)
            .addingReportingOverflow(Int64(decodeDelta))
        guard !lastOverflow, last >= 0, last <= Int64(Int32.max) else { return nil }
        for axis in 0 ..< axes {
            for offset in end ..< promptLength {
                let (expected, expectedOverflow) = Int64(offset)
                    .addingReportingOverflow(Int64(decodeDelta))
                guard !expectedOverflow, expected >= 0,
                    let value = T(exactly: expected),
                    positions[axis * promptLength + offset] == value else { return nil }
            }
        }
        return end
    }
}
