import Foundation
import MLXLMCommon

/// Qwen4 byte-level vocabulary projection used only to track ASCII framing.
/// Non-ASCII payload bytes remain opaque; generated token IDs are not rewritten.
final class Qwen4ToolFramingVocabulary: @unchecked Sendable {
    let pieces: [String?]
    let tokenIDs: [Int]
    let nonStopTokenIDs: [Int]
    let stopTokenIDs: Set<Int>

    init(tokenizer: any MLXLMCommon.Tokenizer, stopTokenIDs: Set<Int>) throws {
        guard !stopTokenIDs.isEmpty else {
            throw ToolConstraintSchemaError.invalid("Qwen4 tool envelope requires terminal token IDs")
        }
        // Validate the native Qwen4 framing tokens, not another family's IDs.
        for (text, expected) in [("<tool_call>", 248058), ("</tool_call>", 248059),
                                 ("<think>", 248068), ("</think>", 248069)] {
            guard tokenizer.convertTokenToId(text) == expected,
                  tokenizer.convertIdToToken(expected) == text else {
                throw ToolConstraintSchemaError.invalid("Native Qwen4 framing vocabulary does not match")
            }
        }
        var decoded: [String?] = []
        var missing = 0
        for id in 0..<400_000 {
            guard let raw = tokenizer.convertIdToToken(id) else {
                decoded.append(nil)
                missing += 1
                if !decoded.isEmpty && missing == 1024 {
                    decoded.removeLast(missing)
                    break
                }
                continue
            }
            missing = 0
            decoded.append(Self.framingProjection(raw))
        }
        guard decoded.count > 248069, stopTokenIDs.allSatisfy({ $0 >= 0 && $0 < decoded.count && decoded[$0] != nil }) else {
            throw ToolConstraintSchemaError.invalid("Incomplete native Qwen4 vocabulary")
        }
        self.pieces = decoded
        self.tokenIDs = decoded.indices.filter { decoded[$0] != nil }
        self.stopTokenIDs = stopTokenIDs
        self.nonStopTokenIDs = tokenIDs.filter { !stopTokenIDs.contains($0) }
    }

    /// Injectable tiny vocabulary for deterministic boundary tests.
    init(pieces: [String?], stopTokenIDs: Set<Int>) {
        self.pieces = pieces
        self.tokenIDs = pieces.indices.filter { pieces[$0] != nil }
        self.stopTokenIDs = stopTokenIDs
        self.nonStopTokenIDs = tokenIDs.filter { !stopTokenIDs.contains($0) }
    }

    private static let byteDecoder: [Unicode.Scalar: UInt8] = {
        var bytes = Array(33...126) + Array(161...172) + Array(174...255)
        var scalars = bytes
        var extra = 0
        for byte in 0...255 where !bytes.contains(byte) {
            bytes.append(byte); scalars.append(256 + extra); extra += 1
        }
        return Dictionary(uniqueKeysWithValues: zip(scalars, bytes).map { (Unicode.Scalar($0.0)!, UInt8($0.1)) })
    }()

    static func framingProjection(_ raw: String) -> String {
        String(String.UnicodeScalarView(raw.unicodeScalars.map { scalar in
            guard let byte = byteDecoder[scalar], byte < 128 else { return Unicode.Scalar(0xFFFD)! }
            return Unicode.Scalar(Int(byte))!
        }))
    }
}

/// Terminal guard, NOT an argument repair or a complete schema grammar.
/// While an outer tool envelope is open, EOS is not legal. All other tokens
/// remain model-selected. Budget exhaustion and malformed calls still fail
/// normal post-validation. CBv2 currently serves constrained rows target-only.
final class Qwen4ToolEnvelopeConstraint: CBv2TokenConstraint, @unchecked Sendable {
    private struct Boundary {
        var opening = ""
        var scanner: Qwen35ToolFrameScanner?

        mutating func consume(_ text: String) {
            for scalar in text.unicodeScalars {
                if var scanner {
                    let closed = scanner.consume(scalar)
                    self.scanner = closed ? nil : scanner
                    continue
                }
                opening.unicodeScalars.append(scalar)
                while !"<tool_call>".hasPrefix(opening) && !opening.isEmpty {
                    opening.unicodeScalars.removeFirst()
                }
                if opening == "<tool_call>" {
                    scanner = Qwen35ToolFrameScanner()
                    opening = ""
                }
            }
        }
        var isOpen: Bool { scanner != nil || !opening.isEmpty }
    }
    private struct Transition: Hashable { let state: Int; let token: Int }
    let mode: CBv2TokenConstraintMode
    let maxTokens: Int
    let initialState = 0
    let fallbackTokenID: Int
    private let vocabulary: Qwen4ToolFramingVocabulary
    private let lock = NSLock()
    private var states = [Boundary()]
    private var transitions: [Transition: Int] = [:]

    init(mode: ToolConstraintMode, maxTokens: Int, vocabulary: Qwen4ToolFramingVocabulary) throws {
        guard maxTokens > 0, let terminal = vocabulary.stopTokenIDs.min(), !vocabulary.nonStopTokenIDs.isEmpty else {
            throw ToolConstraintSchemaError.invalid("Invalid Qwen4 constrained output budget or vocabulary")
        }
        switch mode {
        case .required: self.mode = .required
        case .named: self.mode = .named
        default: throw ToolConstraintSchemaError.invalid("Qwen4 envelope guard requires required or named tool choice")
        }
        self.maxTokens = maxTokens
        self.vocabulary = vocabulary
        self.fallbackTokenID = terminal
    }

    func allowedTokenIDs(state: Int, remainingTokens: Int) -> [Int] {
        lock.lock(); defer { lock.unlock() }
        guard remainingTokens > 0, states.indices.contains(state) else { return [] }
        return states[state].isOpen ? vocabulary.nonStopTokenIDs : vocabulary.tokenIDs
    }

    func nextState(state: Int, tokenID: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard states.indices.contains(state), vocabulary.pieces.indices.contains(tokenID),
              let piece = vocabulary.pieces[tokenID] else { return nil }
        if vocabulary.stopTokenIDs.contains(tokenID) { return states[state].isOpen ? nil : -1 }
        let key = Transition(state: state, token: tokenID)
        if let next = transitions[key] { return next }
        // Bound adversarial state exploration independently of request size.
        guard states.count < 100_000 else { return nil }
        var next = states[state]
        next.consume(piece)
        let index = states.count
        states.append(next)
        transitions[key] = index
        return index
    }
}
