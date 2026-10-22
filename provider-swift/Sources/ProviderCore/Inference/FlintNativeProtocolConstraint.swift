// Copyright © 2026 Eigen Labs.
//
// Protocol design credit: Recursive's Apache-2.0 rec grammar_builder.py at
// e53663b262af4cb1ca498e596ca8b1a2d79e0800, for the official Flint artifact
// 3b93f9053b530488405ae9fca51d4900d6ce21f0. This independently implemented
// Swift boundary machine uses optional reasoning followed by content/calls.
// Unlike rec, it supports required/named and single-call policy, covers the
// artifact's developer EOS, and leaves JSON/schema validity to the existing
// native parser/validator. See the SDK ThirdPartyNotices/Flint.md for notices.

import Foundation
import MLXLMCommon

/// Per-request, bounded host-only protocol constraint. State interning collapses
/// arbitrarily long ordinary text and raw values to the same framing state.
/// It does not force a visible answer, invent argument values or repair EOF.
final class FlintNativeProtocolConstraint: CBv2TokenConstraint, @unchecked Sendable {
    let mode: CBv2TokenConstraintMode
    let maxTokens: Int
    let initialState = 0
    let fallbackTokenID: Int
    private let vocabulary: FlintNativeVocabulary
    let rules: FlintNativeProtocolBoundary.Rules
    private let lock = NSLock()
    private var states = [FlintNativeProtocolBoundary()]
    private var stateIndex = [FlintNativeProtocolBoundary(): 0]
    private var allowedCache: [(state: Int, tokens: [Int])] = []
    private var broadMasks: [(rejected: Set<Int>, stops: Set<Int>, tokens: [Int])] = []
    private var resourceExhausted = false
    static let maximumStates = 8192
    private static let maximumMaskEntries = 4

    init(mode: ToolConstraintMode, maxTokens: Int, vocabulary: FlintNativeVocabulary,
         allowsParallel: Bool, allowedToolNames: Set<String>, tools: [[String: any Sendable]]?) throws {
        guard maxTokens > 0,
              vocabulary.pieces.indices.contains(vocabulary.fallbackTokenID),
              vocabulary.stopTokenIDs.contains(vocabulary.fallbackTokenID) else {
            throw ToolConstraintSchemaError.invalid("Flint protocol requires a positive output budget and terminal token")
        }
        guard allowedToolNames.count <= ToolConstraintSchemaCompiler.maxTools,
              allowedToolNames.allSatisfy(ToolChoicePromptPolicy.isValidFunctionName) else {
            throw ToolConstraintSchemaError.unsupported("Flint protocol function declarations exceed framing limits")
        }
        var names = allowedToolNames
        let requiresCall: Bool
        switch mode {
        case .none:
            self.mode = .none; names = []; requiresCall = false
        case .auto:
            self.mode = .auto; requiresCall = false
        case .required:
            self.mode = .required; requiresCall = true
        case .named(let name):
            guard names.contains(name) else {
                throw ToolConstraintSchemaError.invalid("Flint protocol names an undeclared function")
            }
            self.mode = .named; names = [name]; requiresCall = true
        }
        guard !requiresCall || !names.isEmpty else {
            throw ToolConstraintSchemaError.invalid("Flint required tool choice needs declared functions")
        }
        var rawKeys = [String: Set<String>]()
        var declaredNames = Set<String>()
        var keyBytes = 0
        for tool in tools ?? [] {
            guard let function = tool["function"] as? [String: any Sendable],
                  let name = function["name"] as? String, names.contains(name) else { continue }
            declaredNames.insert(name)
            guard let parameters = function["parameters"] as? [String: any Sendable],
                  let properties = parameters["properties"] as? [String: any Sendable] else { continue }
            for (key, schema) in properties {
                guard key.utf8.count <= FlintNativeProtocolBoundary.maxKeyBytes else {
                    throw ToolConstraintSchemaError.unsupported("Flint protocol argument key exceeds framing limits")
                }
                // Match isStringType exactly, without resolving unions, refs,
                // enum/default values or compiling a narrower auto schema.
                if (schema as? [String: any Sendable])?["type"] as? String == "string" {
                    keyBytes += key.utf8.count
                    guard keyBytes <= 65_536 else {
                        throw ToolConstraintSchemaError.unsupported("Flint protocol string-key metadata exceeds framing limits")
                    }
                    rawKeys[name, default: []].insert(key)
                }
            }
        }
        guard names.isSubset(of: declaredNames) else {
            throw ToolConstraintSchemaError.invalid("Flint protocol requires the prepared tool schemas")
        }
        self.maxTokens = maxTokens
        self.vocabulary = vocabulary
        self.fallbackTokenID = vocabulary.fallbackTokenID
        rules = .init(requiresCall: requiresCall, allowsParallel: allowsParallel, names: names, rawKeys: rawKeys)
    }

    func allowedTokenIDs(state: Int, remainingTokens: Int) -> [Int] {
        lock.lock(); defer { lock.unlock() }
        guard !resourceExhausted, remainingTokens > 0, states.indices.contains(state) else { return [] }
        if let index = allowedCache.firstIndex(where: { $0.state == state }) {
            let entry = allowedCache.remove(at: index)
            allowedCache.append(entry)
            return entry.tokens
        }
        let boundary = states[state]
        let stops = vocabulary.stopTokenIDs.filter { boundary.canStop($0, vocabulary: vocabulary, rules: rules) }
        var allowed: [Int]
        if let sensitive = boundary.broadCandidates(vocabulary, rules: rules) {
            // No simulation over the complete vocabulary in opaque spans.
            // Broad masks are assembled once per cached canonical boundary;
            // common raw/reasoning states return the shared non-stop array.
            let rejected = Set(sensitive.filter { transition(boundary, token: $0) == nil })
            if let index = broadMasks.firstIndex(where: { $0.rejected == rejected && $0.stops == stops }) {
                let mask = broadMasks.remove(at: index)
                broadMasks.append(mask)
                allowed = mask.tokens
            } else {
                allowed = rejected.isEmpty ? vocabulary.nonStopTokenIDs
                    : vocabulary.nonStopTokenIDs.filter { !rejected.contains($0) }
                if !stops.isEmpty { allowed = (allowed + Array(stops)).sorted() }
                if broadMasks.count == Self.maximumMaskEntries { broadMasks.removeFirst() }
                broadMasks.append((rejected, stops, allowed))
            }
        } else {
            let candidates = boundary.firstBytes(rules: rules).map { bytes in
                bytes.sorted().flatMap { vocabulary.byFirstByte[Int($0)] }
            } ?? vocabulary.nonStopTokenIDs
            allowed = candidates.filter { transition(boundary, token: $0) != nil }.sorted()
            if !stops.isEmpty { allowed = (allowed + Array(stops)).sorted() }
        }
        if allowedCache.count == Self.maximumMaskEntries { allowedCache.removeFirst() }
        allowedCache.append((state, allowed))
        return allowed
    }

    func nextState(state: Int, tokenID: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard !resourceExhausted, states.indices.contains(state), vocabulary.pieces.indices.contains(tokenID) else { return nil }
        let boundary = states[state]
        if vocabulary.stopTokenIDs.contains(tokenID) {
            return boundary.canStop(tokenID, vocabulary: vocabulary, rules: rules) ? -1 : nil
        }
        guard let next = transition(boundary, token: tokenID) else { return nil }
        if let known = stateIndex[next] { return known }
        guard states.count < Self.maximumStates else {
            // Resource exhaustion is a typed impossible-state failure, never an
            // unconstrained continuation or a fabricated successful stop.
            resourceExhausted = true
            allowedCache = []
            broadMasks = []
            return nil
        }
        let id = states.count
        states.append(next)
        stateIndex[next] = id
        return id
    }

    private func transition(_ boundary: FlintNativeProtocolBoundary, token: Int) -> FlintNativeProtocolBoundary? {
        var next = boundary
        return next.consume(vocabulary.pieces[token], rules: rules) ? next : nil
    }

    var cachedStateCount: Int { lock.lock(); defer { lock.unlock() }; return states.count }

    /// Read-only interned boundary, for answer-stop classification only.
    func boundary(at state: Int) -> FlintNativeProtocolBoundary? {
        lock.lock(); defer { lock.unlock() }
        return states.indices.contains(state) ? states[state] : nil
    }
}
