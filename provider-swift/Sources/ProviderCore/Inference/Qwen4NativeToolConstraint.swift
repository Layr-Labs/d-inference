// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon


/// Native Qwen4 framing constraint. Required/named responses may reason
/// only in the declared native channel, then emit framed calls, not prose.
/// Argument bodies remain opaque/model-selected and post-validation is required.
final class Qwen4NativeToolConstraint: CBv2TokenConstraint, @unchecked Sendable {
    private struct Boundary {
        var reasoningDepth: Int
        let permitsReasoning: Bool
        let allowsParallel: Bool
        var reasoningMarker = ""
        var opening = ""
        var frame: Qwen35ToolFrameScanner?
        var completed = false

        var canStop: Bool { completed && reasoningDepth == 0 && frame == nil && opening.isEmpty }
        var inOpaqueSpan: Bool { reasoningDepth > 0 || frame != nil }

        mutating func consume(_ piece: String) -> Bool {
            for scalar in piece.unicodeScalars {
                if var frame {
                    let closed = frame.consume(scalar)
                    self.frame = closed ? nil : frame
                    if closed { completed = true }
                    continue
                }
                if reasoningDepth > 0 {
                    reasoningMarker.unicodeScalars.append(scalar)
                    while !reasoningMarker.isEmpty && !["<think>", "</think>"].contains(where: { $0.hasPrefix(reasoningMarker) }) {
                        reasoningMarker.unicodeScalars.removeFirst()
                    }
                    if reasoningMarker == "<think>" {
                        guard reasoningDepth <= NativeChannelSplitter.maximumInnerReasoningDepth else { return false }
                        reasoningDepth += 1
                        reasoningMarker = ""
                    } else if reasoningMarker == "</think>" {
                        reasoningDepth -= 1
                        reasoningMarker = ""
                    }
                    continue
                }
                if opening.isEmpty && scalar.properties.isWhitespace { continue }
                opening.unicodeScalars.append(scalar)
                var candidates: [String] = []
                if !completed || allowsParallel { candidates.append("<tool_call>") }
                if permitsReasoning && !completed { candidates.append("<think>") }
                guard candidates.contains(where: { $0.hasPrefix(opening) }) else { return false }
                if opening == "<tool_call>" {
                    frame = Qwen35ToolFrameScanner()
                    opening = ""
                } else if opening == "<think>" {
                    reasoningDepth = 1
                    opening = ""
                }
            }
            return true
        }
    }
    private struct Transition: Hashable { let state: Int; let token: Int }
    let mode: CBv2TokenConstraintMode
    let maxTokens: Int
    let initialState = 0
    let fallbackTokenID: Int
    private let vocabulary: Qwen4ToolFramingVocabulary
    private let markerCompleters: [Int]
    private var states: [Boundary]
    private var transitions: [Transition: Int] = [:]
    private let lock = NSLock()

    init(mode: ToolConstraintMode, maxTokens: Int, vocabulary: Qwen4ToolFramingVocabulary,
         nativePrefix: String, allowsParallel: Bool) throws {
        guard ["<think>", "<think></think>"].contains(nativePrefix), maxTokens > 0,
              let terminal = vocabulary.stopTokenIDs.min(), !vocabulary.nonStopTokenIDs.isEmpty else {
            throw ToolConstraintSchemaError.invalid("Native Qwen4 framing requires a verified rendered reasoning boundary")
        }
        switch mode {
        case .required: self.mode = .required
        case .named: self.mode = .named
        default: throw ToolConstraintSchemaError.invalid("Native Qwen4 framing requires required or named tool choice")
        }
        self.maxTokens = maxTokens
        self.vocabulary = vocabulary
        fallbackTokenID = terminal
        markerCompleters = vocabulary.nonStopTokenIDs.filter { vocabulary.pieces[$0]!.contains(">") }
        states = [.init(reasoningDepth: nativePrefix == "<think>" ? 1 : 0,
            permitsReasoning: nativePrefix == "<think>", allowsParallel: allowsParallel)]
    }

    func allowedTokenIDs(state: Int, remainingTokens: Int) -> [Int] {
        lock.lock(); defer { lock.unlock() }
        guard remainingTokens > 0, states.indices.contains(state) else { return [] }
        let boundary = states[state]
        if boundary.inOpaqueSpan {
            // Only a '>' can close a native marker/frame or hit the nesting
            // limit. All other nonterminal tokens remain valid opaque input.
            // Check whole token pieces, including text after a closing marker.
            let rejected = Set(markerCompleters.filter { id in
                var next = boundary
                return !next.consume(vocabulary.pieces[id]!)
            })
            return rejected.isEmpty ? vocabulary.nonStopTokenIDs
                : vocabulary.nonStopTokenIDs.filter { !rejected.contains($0) }
        }
        return vocabulary.tokenIDs.filter { id in
            if vocabulary.stopTokenIDs.contains(id) { return boundary.canStop }
            var next = boundary
            return next.consume(vocabulary.pieces[id]!)
        }
    }

    func nextState(state: Int, tokenID: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard states.indices.contains(state), vocabulary.pieces.indices.contains(tokenID),
              let piece = vocabulary.pieces[tokenID] else { return nil }
        if vocabulary.stopTokenIDs.contains(tokenID) { return states[state].canStop ? -1 : nil }
        let transition = Transition(state: state, token: tokenID)
        if let known = transitions[transition] { return known }
        guard states.count < 100_000 else { return nil }
        var next = states[state]
        guard next.consume(piece) else { return nil }
        let index = states.count
        states.append(next)
        transitions[transition] = index
        return index
    }
}
