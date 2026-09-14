// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon

/// Product automaton that composes client stop strings with a finite Gemma
/// tool-call grammar without allowing a sampled prefix to become unfinishable.
final class ForbiddenSubstringTokenConstraint:
    CBv2TokenConstraint, @unchecked Sendable
{
    private struct State: Hashable {
        let base: Int
        let prefixes: [Int]
    }

    private struct CompletionKey: Hashable {
        let state: Int
        let remaining: Int
    }

    private struct CompletionPlan {
        let firstToken: Int
        let length: Int
    }

    private struct CompletionSearchFrame {
        let key: CompletionKey
        let preferred: Int?
        var triedPreferred = false
        var alternatives: [Int]?
        var nextAlternative = 0
        var selectedToken: Int?
    }

    private struct ViabilityEnvelope {
        let tokens: [Int]
        let requiredRemaining: Int
    }

    let mode: CBv2TokenConstraintMode
    let maxTokens: Int
    let fallbackTokenID: Int
    let initialState = 0

    private let base: GemmaToolCallTokenConstraint
    private let vocabulary: GemmaTokenVocabulary
    private let patterns: [[UInt8]]
    private let failureTables: [[Int]]
    private let lock = NSLock()
    private var states: [State]
    private var stateIndex: [State: Int]
    private var transitionCache: [UInt64: Int] = [:]
    private var invalidTransitions = Set<UInt64>()
    private var locallyAllowedCache: [Int: [Int]] = [:]
    private var viabilityEnvelopeCache: [Int: ViabilityEnvelope] = [:]
    private var completionCache: [CompletionKey: CompletionPlan] = [:]
    private var impossibleCompletions = Set<CompletionKey>()

    init(
        base: GemmaToolCallTokenConstraint,
        vocabulary: GemmaTokenVocabulary,
        patterns: [[UInt8]]
    ) throws {
        self.base = base
        self.vocabulary = vocabulary
        self.patterns = patterns
        self.mode = base.mode
        self.maxTokens = base.maxTokens
        self.fallbackTokenID = base.fallbackTokenID
        self.failureTables = patterns.map(Self.failureTable)
        let initial = State(
            base: base.initialState,
            prefixes: [Int](repeating: 0, count: patterns.count))
        self.states = [initial]
        self.stateIndex = [initial: 0]
        guard safeCompletionPlanUnlocked(
            from: 0, remainingTokens: maxTokens) != nil
        else {
            throw ToolConstraintSchemaError.unsupported(
                "stop sequence makes the constrained tool envelope impossible")
        }
    }

    func allowedTokenIDs(state: Int, remainingTokens: Int) -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        guard state >= 0, state < states.count, remainingTokens > 0,
            let completion = safeCompletionPlanUnlocked(
                from: state, remainingTokens: remainingTokens)
        else { return [] }
        if remainingTokens <= completion.length + 1 {
            return [completion.firstToken]
        }
        let envelope = viabilityEnvelopeUnlocked(from: state)
        if remainingTokens >= envelope.requiredRemaining {
            return envelope.tokens
        }
        var viabilityByState: [Int: Bool] = [:]
        let viable = envelope.tokens.filter { token in
            guard let next = nextStateUnlocked(state: state, tokenID: token) else {
                return false
            }
            if next == -1 { return true }
            if let cached = viabilityByState[next] { return cached }
            let canFinish = safeCompletionPlanUnlocked(
                from: next,
                remainingTokens: remainingTokens - 1) != nil
            viabilityByState[next] = canFinish
            return canFinish
        }
        return viable.isEmpty ? [completion.firstToken] : viable
    }

    func nextState(state: Int, tokenID: Int) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return nextStateUnlocked(state: state, tokenID: tokenID)
    }

    private func nextStateUnlocked(state: Int, tokenID: Int) -> Int? {
        guard state >= 0, state < states.count else { return nil }
        let key = (UInt64(UInt32(state)) << 32) | UInt64(UInt32(tokenID))
        if let cached = transitionCache[key] { return cached }
        if invalidTransitions.contains(key) { return nil }

        let current = states[state]
        guard let nextBase = base.nextState(
            state: current.base, tokenID: tokenID)
        else {
            invalidTransitions.insert(key)
            return nil
        }
        if nextBase == -1 {
            transitionCache[key] = -1
            return -1
        }
        guard tokenID >= 0, tokenID < vocabulary.pieces.count,
            let piece = vocabulary.pieces[tokenID]
        else {
            invalidTransitions.insert(key)
            return nil
        }
        var prefixes = current.prefixes
        for byte in piece {
            for index in patterns.indices {
                prefixes[index] = Self.advance(
                    pattern: patterns[index],
                    failure: failureTables[index],
                    prefix: prefixes[index],
                    byte: byte)
                if prefixes[index] == patterns[index].count {
                    invalidTransitions.insert(key)
                    return nil
                }
            }
        }
        let next = State(base: nextBase, prefixes: prefixes)
        let nextState: Int
        if let existing = stateIndex[next] {
            nextState = existing
        } else {
            nextState = states.count
            states.append(next)
            stateIndex[next] = nextState
        }
        transitionCache[key] = nextState
        return nextState
    }

    private func locallyAllowedTokensUnlocked(from state: Int) -> [Int] {
        if let cached = locallyAllowedCache[state] { return cached }
        guard state >= 0, state < states.count else { return [] }
        let current = states[state]
        let allowed = base.unbudgetedAllowedTokenIDs(
            state: current.base
        ).filter {
            nextStateUnlocked(state: state, tokenID: $0) != nil
        }
        locallyAllowedCache[state] = allowed
        return allowed
    }

    private func viabilityEnvelopeUnlocked(
        from state: Int
    ) -> ViabilityEnvelope {
        if let cached = viabilityEnvelopeCache[state] { return cached }
        var planByState: [Int: CompletionPlan] = [:]
        var impossibleStates = Set<Int>()
        var viable: [Int] = []
        var requiredRemaining = 1
        for token in locallyAllowedTokensUnlocked(from: state) {
            guard let next = nextStateUnlocked(
                state: state, tokenID: token)
            else { continue }
            if next == -1 {
                viable.append(token)
                continue
            }
            let plan: CompletionPlan?
            if let cached = planByState[next] {
                plan = cached
            } else if impossibleStates.contains(next) {
                plan = nil
            } else {
                let computed = safeCompletionPlanUnlocked(
                    from: next,
                    remainingTokens: max(1, maxTokens - 1))
                if let computed {
                    planByState[next] = computed
                } else {
                    impossibleStates.insert(next)
                }
                plan = computed
            }
            guard let plan else { continue }
            viable.append(token)
            requiredRemaining = max(
                requiredRemaining, plan.length + 1)
        }
        let envelope = ViabilityEnvelope(
            tokens: viable,
            requiredRemaining: requiredRemaining)
        viabilityEnvelopeCache[state] = envelope
        return envelope
    }

    private func safeCompletionPlanUnlocked(
        from state: Int,
        remainingTokens: Int
    ) -> CompletionPlan? {
        if state == -1 {
            return CompletionPlan(firstToken: fallbackTokenID, length: 0)
        }
        guard remainingTokens > 0, state >= 0, state < states.count else {
            return nil
        }
        let key = CompletionKey(state: state, remaining: remainingTokens)
        if let cached = completionCache[key] { return cached }
        if impossibleCompletions.contains(key) { return nil }

        func frame(for key: CompletionKey) -> CompletionSearchFrame {
            let current = states[key.state]
            let preferred = base.shortestCompletionFirstToken(
                state: current.base)
            return CompletionSearchFrame(
                key: key, preferred: preferred)
        }

        var stack = [frame(for: key)]
        var visiting: Set<CompletionKey> = [key]

        func cacheSolvedPath(
            _ leaf: CompletionPlan
        ) -> CompletionPlan {
            var plan = leaf
            completionCache[stack[stack.count - 1].key] = plan
            if stack.count > 1 {
                for index in stride(
                    from: stack.count - 2, through: 0, by: -1)
                {
                    let token = stack[index].selectedToken!
                    plan = CompletionPlan(
                        firstToken: token, length: plan.length + 1)
                    completionCache[stack[index].key] = plan
                }
            }
            return completionCache[key]!
        }

        while !stack.isEmpty {
            let index = stack.count - 1
            let token: Int
            if !stack[index].triedPreferred,
                let preferred = stack[index].preferred {
                stack[index].triedPreferred = true
                token = preferred
            } else {
                if stack[index].alternatives == nil {
                    let preferred = stack[index].preferred
                    stack[index].alternatives =
                        locallyAllowedTokensUnlocked(
                            from: stack[index].key.state
                        ).filter { $0 != preferred }
                }
                let alternatives = stack[index].alternatives!
                guard stack[index].nextAlternative < alternatives.count else {
                    let exhausted = stack.removeLast().key
                    visiting.remove(exhausted)
                    impossibleCompletions.insert(exhausted)
                    continue
                }
                token = alternatives[stack[index].nextAlternative]
                stack[index].nextAlternative += 1
            }
            guard let next = nextStateUnlocked(
                state: stack[index].key.state, tokenID: token)
            else {
                continue
            }
            if next == -1 {
                return cacheSolvedPath(
                    CompletionPlan(firstToken: token, length: 1))
            }
            let child = CompletionKey(
                state: next, remaining: stack[index].key.remaining - 1)
            guard child.remaining > 0 else { continue }
            if let tail = completionCache[child] {
                return cacheSolvedPath(
                    CompletionPlan(
                        firstToken: token, length: tail.length + 1))
            }
            if impossibleCompletions.contains(child) ||
                visiting.contains(child) {
                continue
            }
            stack[index].selectedToken = token
            visiting.insert(child)
            stack.append(frame(for: child))
        }
        impossibleCompletions.insert(key)
        return nil
    }

    private static func failureTable(_ pattern: [UInt8]) -> [Int] {
        guard !pattern.isEmpty else { return [] }
        var table = [Int](repeating: 0, count: pattern.count)
        var length = 0
        for index in 1 ..< pattern.count {
            while length > 0, pattern[index] != pattern[length] {
                length = table[length - 1]
            }
            if pattern[index] == pattern[length] { length += 1 }
            table[index] = length
        }
        return table
    }

    private static func advance(
        pattern: [UInt8],
        failure: [Int],
        prefix: Int,
        byte: UInt8
    ) -> Int {
        guard !pattern.isEmpty else { return 0 }
        var prefix = prefix
        while prefix > 0, byte != pattern[prefix] {
            prefix = failure[prefix - 1]
        }
        if byte == pattern[prefix] { prefix += 1 }
        return prefix
    }
}
