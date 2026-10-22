// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon

/// Ends exact-Flint generation at the first client stop sequence in visible
/// answer bytes (``FlintAnswerStops``). Masks and protocol transitions stay the
/// native constraint's own; this layer only tracks bounded match progress. After
/// a match only an answer EOS remains, so the engine finishes with `stop` and
/// counts every sampled token, while ``FlintAnswerStopFilter`` withholds the
/// sequence and anything after it from the client.
final class FlintAnswerStopConstraint: CBv2TokenConstraint, @unchecked Sendable {
    private enum Node: Hashable {
        case scanning(base: Int, progress: [Int])
        /// Bytes after the match in the completing token are discarded output,
        /// so the native frame they may open is never entered.
        case matched
    }

    let mode: CBv2TokenConstraintMode
    let maxTokens: Int
    let initialState = 0
    let fallbackTokenID: Int
    private let base: FlintNativeProtocolConstraint
    private let stops: FlintAnswerStops
    private let pieces: [[UInt8]]
    private let answerStops: [Int]
    private let lock = NSLock()
    private var nodes: [Node]
    private var nodeIndex: [Node: Int]
    private var resourceExhausted = false
    /// Progress is non-zero only in the answer channel, so reachable nodes are
    /// native states plus answer states times at most 1 + total stop bytes.
    static let maximumStates = 2 * FlintNativeProtocolConstraint.maximumStates

    init(base: FlintNativeProtocolConstraint, vocabulary: FlintNativeVocabulary, stops: FlintAnswerStops) {
        self.base = base
        self.stops = stops
        mode = base.mode
        maxTokens = base.maxTokens
        fallbackTokenID = base.fallbackTokenID
        pieces = vocabulary.pieces
        answerStops = vocabulary.answerStops.sorted()
        let initial = Node.scanning(base: base.initialState, progress: stops.initialProgress)
        nodes = [initial]
        nodeIndex = [initial: 0]
    }

    /// A client-text filter over the same rules, sequences and initial boundary.
    func makeStreamFilter() -> FlintAnswerStopFilter {
        FlintAnswerStopFilter(stops: stops, rules: base.rules,
            boundary: base.boundary(at: base.initialState) ?? FlintNativeProtocolBoundary())
    }

    func allowedTokenIDs(state: Int, remainingTokens: Int) -> [Int] {
        lock.lock()
        guard !resourceExhausted, remainingTokens > 0, nodes.indices.contains(state) else {
            lock.unlock()
            return []
        }
        let node = nodes[state]
        lock.unlock()
        switch node {
        case .matched: return answerStops
        case .scanning(let baseState, _):
            return base.allowedTokenIDs(state: baseState, remainingTokens: remainingTokens)
        }
    }

    /// Matched nodes share the answer-stop set (key -1); scanning nodes share
    /// the base state's set whatever their stop progress, so they reuse its key.
    func maskCacheKey(state: Int, remainingTokens: Int) -> Int? {
        lock.lock()
        guard !resourceExhausted, remainingTokens > 0, nodes.indices.contains(state) else {
            lock.unlock()
            return nil
        }
        let node = nodes[state]
        lock.unlock()
        switch node {
        case .matched: return -1
        case .scanning(let baseState, _):
            guard let key = base.maskCacheKey(state: baseState, remainingTokens: remainingTokens),
                  key >= 0 else { return nil }
            return key
        }
    }

    /// Masks and transitions keep the base constraint's purity; interning here
    /// also runs only for host-confirmed tokens.
    var allowsChainedDecode: Bool { base.allowsChainedDecode }

    func nextState(state: Int, tokenID: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard !resourceExhausted, nodes.indices.contains(state), pieces.indices.contains(tokenID) else { return nil }
        guard case .scanning(let baseState, var progress) = nodes[state] else {
            return answerStops.contains(tokenID) ? -1 : nil
        }
        guard let nextBase = base.nextState(state: baseState, tokenID: tokenID) else { return nil }
        if nextBase == -1 { return -1 }
        guard var boundary = base.boundary(at: baseState) else { return nil }
        for byte in pieces[tokenID] {
            guard let step = stops.step(byte, boundary: &boundary, progress: &progress, rules: base.rules) else {
                return nil
            }
            if step.match != nil { return intern(.matched) }
        }
        return intern(.scanning(base: nextBase, progress: progress))
    }

    var cachedStateCount: Int { lock.lock(); defer { lock.unlock() }; return nodes.count }

    private func intern(_ node: Node) -> Int? {
        if let known = nodeIndex[node] { return known }
        guard nodes.count < Self.maximumStates else {
            // Same typed impossible-state failure as the native constraint.
            resourceExhausted = true
            return nil
        }
        nodes.append(node)
        nodeIndex[node] = nodes.count - 1
        return nodes.count - 1
    }
}
