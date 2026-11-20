// Copyright © 2026 Eigen Labs.

/// Exact token-level periodicity in one row's generated tokens: the answer has
/// started repeating one block verbatim and, left alone, repeats it until its
/// output cap. No semantics: only the token ids are compared.
///
/// It fires when, at a check, the last `span` tokens repeat a block of `p`
/// tokens back to back (each token equals the one `p` earlier), with
/// `minPeriod <= p <= maxPeriod`, `span >= minSpan` and `span >= minRepeats * p`.
/// A shorter true period (a single repeated token) is found through its
/// multiples in that range and reported as itself.
struct GenerationLoopDetector: Sendable {
    struct Thresholds: Sendable, Equatable {
        var minPeriod = 8
        var maxPeriod = 512
        var minRepeats = 8
        var minSpan = 2_048
        /// Checks run once per this many generated tokens.
        var checkEvery = 64
        /// Never fires before this many tokens were generated.
        var minTokens = 4_096

        /// Tokens a check may look back over: the largest span any period needs.
        var window: Int { max(minSpan, minRepeats * maxPeriod) }

        func requiredSpan(period: Int) -> Int { max(minSpan, minRepeats * period) }
    }

    struct Detection: Sendable, Equatable {
        /// The repeated block's length in tokens (its smallest period).
        let period: Int
        /// The repeating tokens the check covered.
        let span: Int
        /// Tokens generated when it fired.
        let generatedTokens: Int
    }

    let thresholds: Thresholds
    private(set) var generatedTokens = 0
    /// The last generated tokens; at least `window` once that many exist.
    private var tail: [Int] = []
    private var nextCheck: Int

    private let checkEvery: Int

    init(thresholds: Thresholds = Thresholds()) {
        self.thresholds = thresholds
        self.checkEvery = max(thresholds.checkEvery, 1)
        self.nextCheck = checkEvery
    }

    /// Feed one delta's tokens (several when drafts were accepted).
    mutating func append(_ tokens: [Int]) -> Detection? {
        guard !tokens.isEmpty else { return nil }
        tail.append(contentsOf: tokens)
        generatedTokens += tokens.count
        let window = thresholds.window
        if tail.count > 2 * window { tail.removeFirst(tail.count - window) }
        guard generatedTokens >= nextCheck else { return nil }
        nextCheck = (generatedTokens / checkEvery + 1) * checkEvery
        guard generatedTokens >= thresholds.minTokens else { return nil }
        return check()
    }

    private func check() -> Detection? {
        let count = tail.count
        var period = thresholds.minPeriod
        while period <= thresholds.maxPeriod {
            let span = thresholds.requiredSpan(period: period)
            // The required span only grows with the period.
            if span > count { return nil }
            let first = count - span + period
            var index = count - 1
            while index >= first, tail[index] == tail[index - period] { index -= 1 }
            if index < first {
                return Detection(
                    period: smallestPeriod(dividing: period, count: count),
                    span: span, generatedTokens: generatedTokens)
            }
            period += 1
        }
        return nil
    }

    /// The smallest period of the last `period` tokens that divides `period`.
    private func smallestPeriod(dividing period: Int, count: Int) -> Int {
        let start = count - period
        for divisor in 1..<period where period % divisor == 0 {
            var matches = true
            for index in (start + divisor)..<count where tail[index] != tail[index - divisor] {
                matches = false
                break
            }
            if matches { return divisor }
        }
        return period
    }
}
