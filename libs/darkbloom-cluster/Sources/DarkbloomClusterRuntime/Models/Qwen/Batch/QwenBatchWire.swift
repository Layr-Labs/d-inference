import Foundation

/// Fixed-size int32 messages of the batch loop. Rank 0 decides every step and
/// tells rank 1 in a header; rank 1 answers with the tokens it selected. Both
/// carry the step number and a checksum, so a message from another step or a
/// damaged one stops both ranks instead of desynchronizing them.
enum QwenBatchWire {
    static let maximumLanes = 8
    static let headerWords = 16 + maximumLanes * slotWords + 1
    static let slotWords = 28
    /// Prefix frontiers rank 0 offers for a joining lane, deepest first.
    static let maximumOffers = 8
    static let replyWords = 8 + maximumLanes * 2 + 1
    static let openingWords = 16
    static let headerMagic: Int32 = 0x4251_4831   // "BQH1"
    static let replyMagic: Int32 = 0x4251_5231    // "BQR1"
    static let openingMagic: Int32 = 0x4251_4F31  // "BQO1"

    /// What a slot is doing in this step.
    enum SlotState: Int32 { case empty = 0, joining = 1, active = 2, leaving = 3 }
    /// The forward a slot runs in this step.
    enum Role: Int32 { case none = 0, decode = 1, prefill = 2 }

    static func reasonCode(_ reason: QwenLayerStageGenerationFinishReason?) -> Int32 {
        switch reason { case nil: 0; case .eos?: 1; case .length?: 2; case .clientStop?: 3 }
    }
    static func reason(_ code: Int32) throws -> QwenLayerStageGenerationFinishReason {
        switch code {
        case 1: return .eos
        case 2: return .length
        case 3: return .clientStop
        default: throw ProbeError("Batch header names no finish reason for a leaving lane")
        }
    }

    static func checksum(_ words: ArraySlice<Int32>) -> Int32 {
        // FNV-1a over the words' bytes; integrity of the framing, not security.
        var hash: UInt32 = 0x811C_9DC5
        for word in words {
            var value = UInt32(bitPattern: word)
            for _ in 0..<4 { hash = (hash ^ (value & 0xFF)) &* 0x0100_0193; value >>= 8 }
        }
        return Int32(bitPattern: hash)
    }

    static func uuidWords(_ id: UUID) -> [Int32] {
        let u = id.uuid
        let bytes = [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
        var words: [Int32] = []
        for i in 0..<4 {
            var value: UInt32 = 0
            for j in 0..<4 { value = (value << 8) | UInt32(bytes[4 * i + j]) }
            words.append(Int32(bitPattern: value))
        }
        return words
    }

    static func uuid(_ words: ArraySlice<Int32>) -> UUID {
        let w = Array(words)
        var b = [UInt8](repeating: 0, count: 16)
        for i in 0..<4 {
            let v = UInt32(bitPattern: w[i])
            b[4 * i] = UInt8(v >> 24); b[4 * i + 1] = UInt8((v >> 16) & 0xFF)
            b[4 * i + 2] = UInt8((v >> 8) & 0xFF); b[4 * i + 3] = UInt8(v & 0xFF)
        }
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// The loop's first exchange: both ranks run the same lanes on the same
    /// storage, and split the last prompt token only when both prefix caches
    /// are on (the arithmetic the one-request path uses with the cache on).
    struct Opening: Equatable {
        let lanes: Int
        let pagedKV: Bool
        let prefixCacheEnabled: Bool
        let vocabularySize: Int
        let hiddenSize: Int

        var words: [Int32] {
            var w = [Int32](repeating: 0, count: openingWords)
            w[0] = openingMagic; w[1] = 1; w[2] = Int32(lanes); w[3] = pagedKV ? 1 : 0
            w[4] = prefixCacheEnabled ? 1 : 0; w[5] = Int32(vocabularySize); w[6] = Int32(hiddenSize)
            w[openingWords - 1] = checksum(w[0..<(openingWords - 1)])
            return w
        }

        init(lanes: Int, pagedKV: Bool, prefixCacheEnabled: Bool, vocabularySize: Int, hiddenSize: Int) {
            self.lanes = lanes; self.pagedKV = pagedKV; self.prefixCacheEnabled = prefixCacheEnabled
            self.vocabularySize = vocabularySize; self.hiddenSize = hiddenSize
        }

        init(words w: [Int32]) throws {
            guard w.count == openingWords, w[0] == openingMagic, w[1] == 1,
                  w[openingWords - 1] == checksum(w[0..<(openingWords - 1)]),
                  (1...maximumLanes).contains(Int(w[2])), [0, 1].contains(w[3]), [0, 1].contains(w[4]) else {
                throw ProbeError("Batch opening from the peer is malformed")
            }
            self.init(lanes: Int(w[2]), pagedKV: w[3] == 1, prefixCacheEnabled: w[4] == 1,
                      vocabularySize: Int(w[5]), hiddenSize: Int(w[6]))
        }
    }

    struct Slot: Equatable {
        var state: SlotState = .empty
        var requestID: UUID?
        var role: Role = .none
        /// Committed tokens of the lane before this step's forward.
        var committedTokens = 0
        /// Tokens selected for the lane before this step.
        var selectedTokens = 0
        /// For a decode row: the token it decodes.
        var inputToken = -1
        /// For the prefill slot: this frame's offset, count and whether it is the last.
        var frameOffset = 0
        var frameCount = 0
        var finalChunk = false
        /// For a leaving slot: how its request finished.
        var leaveReason: QwenLayerStageGenerationFinishReason?
        /// For a joining slot: the first 16 bytes of the request fingerprint,
        /// which rank 1 compares with the request its own owner gave it.
        var fingerprintWords: [Int32] = [0, 0, 0, 0]
        /// For a joining slot: the prefix frontiers rank 0 holds for the
        /// prompt, deepest first (empty when either cache is off).
        var offers: [Int] = []
        /// For a confirming slot (the step after its join): the prefix both
        /// ranks reuse, rank 0's decision from rank 1's restore.
        var confirming = false
        var reusedPrefix = 0
    }

    /// The first 16 bytes of a hex SHA-256 as four words.
    static func fingerprintWords(_ hex: String) -> [Int32] {
        let digits = Array(hex.utf8.prefix(32))
        guard digits.count == 32 else { return [0, 0, 0, 0] }
        func nibble(_ c: UInt8) -> UInt32 { c >= 97 ? UInt32(c - 87) : c >= 65 ? UInt32(c - 55) : UInt32(c - 48) }
        return (0..<4).map { i in
            var v: UInt32 = 0
            for j in 0..<8 { v = v << 4 | nibble(digits[8 * i + j]) }
            return Int32(bitPattern: v)
        }
    }

    struct Header: Equatable {
        var step: Int
        var stop: Bool
        var slots: [Slot]

        var words: [Int32] {
            var w = [Int32](repeating: 0, count: headerWords)
            w[0] = headerMagic; w[1] = Int32(truncatingIfNeeded: step); w[2] = Int32(truncatingIfNeeded: step >> 31)
            w[3] = stop ? 1 : 0; w[4] = Int32(slots.count)
            for (index, slot) in slots.enumerated() {
                let base = 16 + index * slotWords
                w[base] = slot.state.rawValue
                if let id = slot.requestID { w.replaceSubrange((base + 1)...(base + 4), with: uuidWords(id)) }
                w[base + 5] = slot.role.rawValue
                w[base + 6] = Int32(slot.committedTokens); w[base + 7] = Int32(slot.selectedTokens)
                w[base + 8] = Int32(slot.inputToken); w[base + 9] = Int32(slot.frameOffset)
                w[base + 10] = Int32(slot.frameCount) | (slot.finalChunk ? Int32(1 << 30) : 0)
                w[base + 11] = reasonCode(slot.leaveReason)
                w.replaceSubrange((base + 12)...(base + 15), with: slot.fingerprintWords)
                w[base + 16] = Int32(min(slot.offers.count, maximumOffers))
                for (i, offer) in slot.offers.prefix(maximumOffers).enumerated() { w[base + 17 + i] = Int32(offer) }
                w[base + 25] = slot.confirming ? 1 : 0
                w[base + 26] = Int32(slot.reusedPrefix)
            }
            w[headerWords - 1] = checksum(w[0..<(headerWords - 1)])
            return w
        }

        init(step: Int, stop: Bool, slots: [Slot]) { self.step = step; self.stop = stop; self.slots = slots }

        init(words w: [Int32], expectedStep: Int, lanes: Int) throws {
            guard w.count == headerWords, w[0] == headerMagic, w[headerWords - 1] == checksum(w[0..<(headerWords - 1)]),
                  Int(w[1]) | (Int(w[2]) << 31) == expectedStep, [0, 1].contains(w[3]), Int(w[4]) == lanes else {
                throw ProbeError("Batch header from rank 0 is malformed or from another step")
            }
            step = expectedStep; stop = w[3] == 1
            slots = try (0..<lanes).map { index in
                let base = 16 + index * slotWords
                guard let state = SlotState(rawValue: w[base]), let role = Role(rawValue: w[base + 5]) else {
                    throw ProbeError("Batch header slot state or role is unknown")
                }
                var slot = Slot(state: state, requestID: state == .empty ? nil : uuid(w[(base + 1)...(base + 4)]), role: role)
                slot.committedTokens = Int(w[base + 6]); slot.selectedTokens = Int(w[base + 7])
                slot.inputToken = Int(w[base + 8]); slot.frameOffset = Int(w[base + 9])
                slot.frameCount = Int(w[base + 10] & 0x3FFF_FFFF); slot.finalChunk = w[base + 10] & Int32(1 << 30) != 0
                slot.leaveReason = state == .leaving ? try reason(w[base + 11]) : nil
                slot.fingerprintWords = Array(w[(base + 12)...(base + 15)])
                let offered = Int(w[base + 16])
                guard (0...maximumOffers).contains(offered), [0, 1].contains(w[base + 25]), w[base + 26] >= 0 else {
                    throw ProbeError("Batch header slot prefix fields are malformed")
                }
                slot.offers = (0..<offered).map { Int(w[base + 17 + $0]) }
                slot.confirming = w[base + 25] == 1; slot.reusedPrefix = Int(w[base + 26])
                return slot
            }
        }
    }

    struct Reply: Equatable {
        var step: Int
        /// Per slot: the token rank 1 selected in this step, or -1.
        var tokens: [Int]
        /// Per slot: for a lane that joined in this step, the prefix frontier
        /// rank 1 restored (0 for none).
        var restored: [Int]

        var words: [Int32] {
            var w = [Int32](repeating: 0, count: replyWords)
            w[0] = replyMagic; w[1] = Int32(truncatingIfNeeded: step); w[2] = Int32(truncatingIfNeeded: step >> 31)
            w[3] = Int32(tokens.count)
            for (index, token) in tokens.enumerated() {
                w[8 + 2 * index] = Int32(token); w[9 + 2 * index] = Int32(restored[index])
            }
            w[replyWords - 1] = checksum(w[0..<(replyWords - 1)])
            return w
        }

        init(step: Int, tokens: [Int], restored: [Int]? = nil) {
            self.step = step; self.tokens = tokens; self.restored = restored ?? tokens.map { _ in 0 }
        }

        init(words w: [Int32], expectedStep: Int, lanes: Int) throws {
            guard w.count == replyWords, w[0] == replyMagic, w[replyWords - 1] == checksum(w[0..<(replyWords - 1)]),
                  Int(w[1]) | (Int(w[2]) << 31) == expectedStep, Int(w[3]) == lanes else {
                throw ProbeError("Batch reply from rank 1 is malformed or from another step")
            }
            step = expectedStep; tokens = (0..<lanes).map { Int(w[8 + 2 * $0]) }
            restored = (0..<lanes).map { Int(w[9 + 2 * $0]) }
            guard restored.allSatisfy({ $0 >= 0 }) else { throw ProbeError("Batch reply restore fields are malformed") }
        }
    }
}
