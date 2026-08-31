// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon

final class GemmaNoToolTokenConstraint: CBv2TokenConstraint, @unchecked Sendable {
    let mode: CBv2TokenConstraintMode = .none
    let maxTokens: Int
    let fallbackTokenID: Int
    let initialState = 0

    private let vocabulary: GemmaTokenVocabulary
    private static let forbidden = [
        Array("<|tool_call>".utf8),
        Array("<start_function_call>".utf8),
    ]
    /// Proper prefixes of the forbidden markers (plus the empty prefix),
    /// sorted by (length, lexicographic). Automaton states index into this
    /// table; state 0 is the empty prefix. Built once — the transition path
    /// consults it per byte of every candidate token.
    private static let prefixTable: [[UInt8]] = {
        var prefixes: [[UInt8]] = [[]]
        for pattern in forbidden {
            for count in 1 ..< pattern.count {
                prefixes.append(Array(pattern.prefix(count)))
            }
        }
        prefixes.sort { lhs, rhs in
            lhs.count == rhs.count
                ? lhs.lexicographicallyPrecedes(rhs)
                : lhs.count < rhs.count
        }
        return prefixes
    }()
    /// Bytes -> first table index. Shared prefixes of the two markers (e.g.
    /// `<`) appear twice in the table; lookups resolve to the FIRST
    /// occurrence, so later duplicates are dead entries — exactly the
    /// `firstIndex(of:)` behavior this table replaces.
    private static let prefixIndexByBytes: [[UInt8]: Int] =
        Dictionary(
            prefixTable.enumerated().map { ($1, $0) },
            uniquingKeysWith: { first, _ in first })
    private let lock = NSLock()
    private var transitionCache: [UInt64: Int] = [:]
    private var invalidTransitions = Set<UInt64>()
    private var allowedCache: [Int: [Int]] = [:]

    init(maxTokens: Int, vocabulary: GemmaTokenVocabulary) {
        self.maxTokens = maxTokens
        self.vocabulary = vocabulary
        self.fallbackTokenID = vocabulary.fallbackTokenID
    }

    func allowedTokenIDs(state: Int, remainingTokens: Int) -> [Int] {
        guard remainingTokens > 0 else { return [] }
        lock.lock()
        defer { lock.unlock() }
        if let cached = allowedCache[state] { return cached }
        var extra = Array(vocabulary.stopTokenIDs)
        let candidates = state == 0
            ? vocabulary.tokensWithLessThan
            : Array(vocabulary.pieces.indices)
        for token in candidates
        where nextStateUnlocked(state: state, tokenID: token) != nil {
            extra.append(token)
        }
        let allowed = gemmaMergeSortedUnique(
            state == 0 ? vocabulary.tokensWithoutLessThan : [],
            Array(Set(extra)).sorted())
        allowedCache[state] = allowed
        return allowed
    }

    func nextState(state: Int, tokenID: Int) -> Int? {
        if vocabulary.stopTokenIDs.contains(tokenID) { return -1 }
        lock.lock()
        defer { lock.unlock() }
        return nextStateUnlocked(state: state, tokenID: tokenID)
    }

    private func nextStateUnlocked(state: Int, tokenID: Int) -> Int? {
        guard state >= 0, tokenID >= 0, tokenID < vocabulary.pieces.count,
            let piece = vocabulary.pieces[tokenID], !piece.isEmpty
        else { return nil }
        let key = (UInt64(UInt32(state)) << 32) | UInt64(UInt32(tokenID))
        if let cached = transitionCache[key] { return cached }
        if invalidTransitions.contains(key) { return nil }

        var prefix = state
        for byte in piece {
            let historyPrefix = Self.longestPrefixBytes(index: prefix)
            var candidate = historyPrefix + [byte]
            if Self.forbidden.contains(where: { candidate.suffix($0.count) == $0[...] }) {
                invalidTransitions.insert(key)
                return nil
            }
            while !candidate.isEmpty,
                !Self.forbidden.contains(where: { $0.starts(with: candidate) })
            {
                candidate.removeFirst()
            }
            prefix = Self.prefixIndexByBytes[candidate] ?? 0
        }
        transitionCache[key] = prefix
        return prefix
    }

    private static func longestPrefixBytes(index: Int) -> [UInt8] {
        guard index >= 0, index < prefixTable.count else { return [] }
        return prefixTable[index]
    }
}

func gemmaMergeSortedUnique(_ lhs: [Int], _ rhs: [Int]) -> [Int] {
    var output: [Int] = []
    output.reserveCapacity(lhs.count + rhs.count)
    var left = 0
    var right = 0
    while left < lhs.count || right < rhs.count {
        let value: Int
        if right >= rhs.count || (left < lhs.count && lhs[left] <= rhs[right]) {
            value = lhs[left]
            left += 1
        } else {
            value = rhs[right]
            right += 1
        }
        if output.last != value { output.append(value) }
    }
    return output
}
