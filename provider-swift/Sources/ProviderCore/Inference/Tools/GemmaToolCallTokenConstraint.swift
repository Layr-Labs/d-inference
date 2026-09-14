// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon

final class GemmaToolCallTokenConstraint: CBv2TokenConstraint, @unchecked Sendable {
    let mode: CBv2TokenConstraintMode
    let maxTokens: Int
    let fallbackTokenID: Int
    let initialState: Int

    private let nfa: GemmaByteNFA
    private let vocabulary: GemmaTokenVocabulary
    private let lock = NSLock()
    private var dfaStates: [[Int]] = []
    private var dfaIndex: [String: Int] = [:]
    private var transitionCache: [UInt64: Int] = [:]
    private var invalidTransitions = Set<UInt64>()
    private var allowedCache: [Int: [Int]] = [:]
    private struct CompletionPlan {
        let firstToken: Int
        let length: Int
    }
    private struct ViabilityEnvelope {
        let tokens: [Int]
        let requiredRemaining: Int
    }
    private var completionCache: [Int: CompletionPlan] = [:]
    private var impossibleCompletionStates = Set<Int>()
    private var viabilityEnvelopeCache: [Int: ViabilityEnvelope] = [:]

    init(
        mode: ToolConstraintMode,
        tools: [CompiledToolSchema],
        allowsParallel: Bool,
        maxTokens: Int,
        vocabulary: GemmaTokenVocabulary
    ) throws {
        switch mode {
        case .required:
            self.mode = .required
        case .named:
            self.mode = .named
        case .none, .auto:
            throw ToolConstraintSchemaError.invalid(
                "Gemma tool-call grammar requires required or named mode")
        }
        self.maxTokens = maxTokens
        self.vocabulary = vocabulary
        self.fallbackTokenID = vocabulary.fallbackTokenID
        var builder = GemmaByteNFABuilder()
        let nfa = try builder.build(
            tools: tools, allowsParallel: allowsParallel)
        guard nfa.nodes.count <= 100_000 else {
            throw ToolConstraintSchemaError.unsupported(
                "compiled tool grammar exceeds the 100000-state safety limit")
        }
        self.nfa = nfa
        self.initialState = 0
        let closure = Self.epsilonClosure([nfa.start], nodes: nfa.nodes)
        dfaStates = [closure]
        dfaIndex[Self.stateKey(closure)] = 0
        guard let plan = completionPlanUnlocked(from: 0), plan.length <= maxTokens else {
            throw ToolConstraintSchemaError.invalid(
                "max_tokens is too small to complete the constrained tool envelope")
        }
    }

    func allowedTokenIDs(state: Int, remainingTokens: Int) -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        guard state >= 0, state < dfaStates.count, remainingTokens > 0,
            let completion = completionPlanUnlocked(from: state),
            completion.length <= remainingTokens
        else { return [] }
        if remainingTokens <= completion.length + 1 {
            return [completion.firstToken]
        }
        let envelope = viabilityEnvelopeUnlocked(from: state)
        if remainingTokens >= envelope.requiredRemaining {
            return envelope.tokens
        }
        let viable = envelope.tokens.filter { token in
            guard let next = nextStateUnlocked(
                state: state, tokenID: token)
            else { return false }
            return next == -1 ||
                completionPlanUnlocked(from: next).map {
                    $0.length <= remainingTokens - 1
                } ?? false
        }
        return viable.isEmpty ? [completion.firstToken] : viable
    }

    func nextState(state: Int, tokenID: Int) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return nextStateUnlocked(state: state, tokenID: tokenID)
    }

    func unbudgetedAllowedTokenIDs(state: Int) -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        guard state >= 0, state < dfaStates.count else { return [] }
        return allowedTokensUnlocked(from: state)
    }

    func shortestCompletionFirstToken(state: Int) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return completionPlanUnlocked(from: state)?.firstToken
    }

    private func allowedTokensUnlocked(from state: Int) -> [Int] {
        if let cached = allowedCache[state] { return cached }
        var candidates = Set<Int>()
        var directlyAllowed: [Int] = []
        if isAccepting(state) {
            candidates.formUnion(vocabulary.stopTokenIDs)
        }
        if isPermissiveStringState(state) {
            directlyAllowed = vocabulary.stringSafeTokenIDs
            candidates.formUnion(vocabulary.nonStringSafeTokenIDs)
        } else {
            for byte in firstBytes(state) {
                candidates.formUnion(vocabulary.byFirstByte[Int(byte)])
            }
        }
        let extra = candidates.filter {
            nextStateUnlocked(state: state, tokenID: $0) != nil
        }.sorted()
        let allowed = gemmaMergeSortedUnique(directlyAllowed, extra)
        allowedCache[state] = allowed
        return allowed
    }

    private func viabilityEnvelopeUnlocked(
        from state: Int
    ) -> ViabilityEnvelope {
        if let cached = viabilityEnvelopeCache[state] { return cached }
        var viable: [Int] = []
        var requiredRemaining = 1
        for token in allowedTokensUnlocked(from: state) {
            guard let next = nextStateUnlocked(
                state: state, tokenID: token)
            else { continue }
            if next == -1 {
                viable.append(token)
                continue
            }
            guard let completion = completionPlanUnlocked(
                from: next)
            else { continue }
            viable.append(token)
            requiredRemaining = max(
                requiredRemaining, completion.length + 1)
        }
        let envelope = ViabilityEnvelope(
            tokens: viable,
            requiredRemaining: requiredRemaining)
        viabilityEnvelopeCache[state] = envelope
        return envelope
    }

    private func nextStateUnlocked(state: Int, tokenID: Int) -> Int? {
        guard state >= 0, state < dfaStates.count else { return nil }
        if vocabulary.stopTokenIDs.contains(tokenID) {
            return isAccepting(state) ? -1 : nil
        }
        guard tokenID >= 0, tokenID < vocabulary.pieces.count,
            let piece = vocabulary.pieces[tokenID], !piece.isEmpty
        else { return nil }
        let key = transitionKey(state: state, tokenID: tokenID)
        if let cached = transitionCache[key] { return cached }
        if invalidTransitions.contains(key) { return nil }

        var active = dfaStates[state]
        for byte in piece {
            var next = Set<Int>()
            for node in active {
                for edge in nfa.nodes[node].edges where edge.range.contains(byte) {
                    next.insert(edge.destination)
                }
            }
            if next.isEmpty {
                invalidTransitions.insert(key)
                return nil
            }
            active = Self.epsilonClosure(Array(next), nodes: nfa.nodes)
        }
        let nextState = intern(active)
        transitionCache[key] = nextState
        return nextState
    }

    private func completionPlanUnlocked(from state: Int) -> CompletionPlan? {
        if state == -1 {
            return .init(firstToken: fallbackTokenID, length: 0)
        }
        if let cached = completionCache[state] { return cached }
        if impossibleCompletionStates.contains(state) { return nil }
        if isAccepting(state) {
            let plan = CompletionPlan(firstToken: fallbackTokenID, length: 1)
            completionCache[state] = plan
            return plan
        }

        var path: [(state: Int, token: Int)] = []
        var current = state
        var visited = Set<Int>()
        for _ in 0 ..< maxTokens {
            if isAccepting(current) {
                var length = 1
                completionCache[current] = .init(
                    firstToken: fallbackTokenID, length: length)
                for step in path.reversed() {
                    length += 1
                    completionCache[step.state] = .init(
                        firstToken: step.token, length: length)
                }
                return completionCache[state]
            }
            guard visited.insert(current).inserted else { break }
            let currentDistance = byteDistance(current)
            let candidates = isPermissiveStringState(current)
                ? vocabulary.nonStringSafeTokenIDs
                : allowedTokensUnlocked(from: current)
            var best: (token: Int, state: Int, distance: Int, pieceLength: Int)?
            for token in candidates {
                guard !vocabulary.stopTokenIDs.contains(token),
                    let next = nextStateUnlocked(state: current, tokenID: token)
                else { continue }
                let distance = byteDistance(next)
                guard distance < currentDistance else { continue }
                let pieceLength = vocabulary.pieces[token]?.count ?? .max
                if best == nil
                    || distance < best!.distance
                    || (distance == best!.distance && pieceLength > best!.pieceLength)
                {
                    best = (token, next, distance, pieceLength)
                }
            }
            guard let best else { break }
            path.append((current, best.token))
            current = best.state
        }
        impossibleCompletionStates.insert(state)
        return nil
    }

    private func firstBytes(_ state: Int) -> Set<UInt8> {
        var bytes = Set<UInt8>()
        for node in dfaStates[state] {
            for edge in nfa.nodes[node].edges {
                for value in Int(edge.range.lowerBound) ... Int(edge.range.upperBound) {
                    bytes.insert(UInt8(value))
                }
            }
        }
        return bytes
    }

    private func isPermissiveStringState(_ state: Int) -> Bool {
        dfaStates[state].contains { nfa.nodes[$0].permissiveStringLoop }
    }

    private func byteDistance(_ state: Int) -> Int {
        dfaStates[state].map { nfa.minBytesToAccept[$0] }.min() ?? .max
    }

    private func isAccepting(_ state: Int) -> Bool {
        !nfa.accepting.isDisjoint(with: dfaStates[state])
    }

    private func intern(_ active: [Int]) -> Int {
        let key = Self.stateKey(active)
        if let existing = dfaIndex[key] { return existing }
        let id = dfaStates.count
        dfaStates.append(active)
        dfaIndex[key] = id
        return id
    }

    private func transitionKey(state: Int, tokenID: Int) -> UInt64 {
        (UInt64(UInt32(state)) << 32) | UInt64(UInt32(tokenID))
    }

    private static func epsilonClosure(
        _ seeds: [Int],
        nodes: [GemmaByteNFA.Node]
    ) -> [Int] {
        var seen = Set(seeds)
        var stack = seeds
        while let state = stack.popLast() {
            for destination in nodes[state].epsilon where seen.insert(destination).inserted {
                stack.append(destination)
            }
        }
        return seen.sorted()
    }

    private static func stateKey(_ states: [Int]) -> String {
        states.map(String.init).joined(separator: ",")
    }
}
