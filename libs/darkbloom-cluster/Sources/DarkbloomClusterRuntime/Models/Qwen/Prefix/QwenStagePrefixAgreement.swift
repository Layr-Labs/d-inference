import Foundation
import MLX

/// What one rank holds for this request's prompt, sent to its peer before the
/// first forward. Fixed 64 int32 words on the wire. Each frontier carries a
/// tier bit: set when this rank holds it only on its SSD tier. The choice
/// does not depend on tiers (each rank restores from its own); they are
/// carried so both ranks log the same picture and a later policy can weigh
/// a disk read against a shallower resident hit.
struct QwenStagePrefixOffer: Equatable {
    static let magic: Int32 = 0x5046_5833 // "PFX3"
    static let diskBit: Int32 = 1 << 30
    let enabled: Bool
    /// Deepest first; every value is in 1..<promptCount.
    let frontiers: [Int]
    /// The frontiers above that this rank holds only on disk.
    let onDisk: Set<Int>

    init(enabled: Bool, frontiers: [Int], onDisk: Set<Int> = []) {
        self.enabled = enabled
        self.frontiers = enabled ? Array(frontiers.prefix(QwenStagePrefixCache.maximumOffered)) : []
        self.onDisk = onDisk.intersection(self.frontiers)
    }

    var words: [Int32] {
        var words = [Self.magic, enabled ? 1 : 0, Int32(frontiers.count)]
            + frontiers.map { Int32($0) | (onDisk.contains($0) ? Self.diskBit : 0) }
        words += Array(repeating: 0, count: 64 - words.count)
        return words
    }

    /// A peer's words. Anything malformed is an offer of nothing with the
    /// switch off, which settles to a cold request on both ranks.
    init(words: [Int32], promptCount: Int) {
        guard words.count == 64, words[0] == Self.magic, words[1] == 0 || words[1] == 1,
              (0...QwenStagePrefixCache.maximumOffered).contains(Int(words[2])) else {
            self.init(enabled: false, frontiers: []); return
        }
        let raw = Array(words[3..<(3 + Int(words[2]))])
        let values = raw.map { Int($0 & ~Self.diskBit) }
        guard raw.allSatisfy({ $0 >= 0 }), values.allSatisfy({ (1..<promptCount).contains($0) }),
              Set(values).count == values.count else {
            self.init(enabled: false, frontiers: []); return
        }
        self.init(enabled: words[1] == 1, frontiers: values,
                  onDisk: Set(zip(raw, values).filter { $0.0 & Self.diskBit != 0 }.map(\.1)))
    }
}

/// The plan both ranks derive from both offers: reuse the deepest frontier
/// both hold, and split the last prompt token off only if both caches are on.
struct QwenStagePrefixChoice: Equatable {
    let reusedPrefix: Int
    let splitFinalToken: Bool

    static func choose(local: QwenStagePrefixOffer, peer: QwenStagePrefixOffer, promptCount: Int) -> Self {
        guard local.enabled, peer.enabled, promptCount >= 2 else { return .init(reusedPrefix: 0, splitFinalToken: false) }
        let common = Set(local.frontiers).intersection(peer.frontiers).filter { (1..<promptCount).contains($0) }
        return .init(reusedPrefix: common.max() ?? 0, splitFinalToken: true)
    }
}

/// Second exchange, after each rank tried to restore the chosen frontier.
/// Reuse goes ahead only if both ranks chose the same plan for the same key
/// and both restored; otherwise both ranks prefill from zero.
struct QwenStagePrefixConfirmation: Equatable {
    static let magic: Int32 = 0x5046_5832 // "PFX2"
    let choice: QwenStagePrefixChoice
    let restored: Bool
    /// The first 16 bytes of the shared key at the chosen frontier (zeros when
    /// nothing is reused).
    let keyWords: [Int32]

    init(choice: QwenStagePrefixChoice, restored: Bool, key: String?) {
        self.choice = choice; self.restored = restored
        var words: [Int32] = []
        if let key, choice.reusedPrefix > 0 {
            let hex = Array(key.utf8.prefix(32))
            for index in Swift.stride(from: 0, to: hex.count, by: 8) {
                words.append(Int32(bitPattern: UInt32(String(decoding: hex[index..<min(hex.count, index + 8)], as: UTF8.self),
                    radix: 16) ?? 0))
            }
        }
        keyWords = words + Array(repeating: 0, count: max(0, 4 - words.count))
    }

    var words: [Int32] {
        var words = [Self.magic, Int32(choice.reusedPrefix), choice.splitFinalToken ? 1 : 0, restored ? 1 : 0] + keyWords
        words += Array(repeating: 0, count: 64 - words.count)
        return words
    }

    init?(words: [Int32]) {
        guard words.count == 64, words[0] == Self.magic, words[1] >= 0,
              words[2] == 0 || words[2] == 1, words[3] == 0 || words[3] == 1 else { return nil }
        choice = .init(reusedPrefix: Int(words[1]), splitFinalToken: words[2] == 1)
        restored = words[3] == 1; keyWords = Array(words[4..<8])
    }

    /// Both ranks call this with the same two values in swapped roles and
    /// reach the same result.
    static func settle(local: Self, peer: Self?) -> QwenStagePrefixChoice {
        guard let peer, peer.choice.splitFinalToken == local.choice.splitFinalToken else {
            return .init(reusedPrefix: 0, splitFinalToken: false)
        }
        guard local.choice == peer.choice, local.keyWords == peer.keyWords, local.restored, peer.restored else {
            return .init(reusedPrefix: 0, splitFinalToken: local.choice.splitFinalToken)
        }
        return local.choice
    }
}

/// What a request reports of its prefix plan.
public struct QwenStagePrefixSummary: Equatable, Encodable, Sendable {
    /// Prompt tokens both ranks restored instead of computing.
    public let reusedPromptTokens: Int
    /// Where this rank restored them from: `resident`, `ssd`, or nil.
    public var restoredTier: String? = nil
    /// The deepest frontier both ranks held before restore was confirmed.
    public let agreedPromptTokens: Int
    public let splitFinalToken: Bool
    /// Frontiers this rank stored after the request retired cleanly.
    public let storedFrontiers: [Int]
    public let cacheEntries: Int
}

/// Both ranks publish their words before either reads its peer's, exactly as
/// the readiness exchange does. Fixed size; never a variable-length message.
func exchangeQwenStagePrefixWords(collective: Collective, words: [Int32], scope: CollectiveRecordScope,
                                  check: () throws -> Void) throws -> [Int32] {
    guard collective.size == 2, (0..<2).contains(collective.rank), words.count == 64 else {
        throw ProbeError("Prefix agreement requires exactly two ranks and a fixed message")
    }
    return try MLX.withError { error in
        func checked() throws { try error.check(); try check(); try error.check() }
        func send() throws {
            let array = MLXArray(words)
            try checked()
            _ = try collective.sendCompleted(array, to: 1 - collective.rank, maximumBytes: 256,
                scope: scope.part("rank\(collective.rank)"), check: checked)
        }
        func receive() throws -> [Int32] {
            let actual = try collective.receiveCompleted(shape: [64], dtype: .int32,
                from: 1 - collective.rank, maximumBytes: 256, scope: scope.part("rank\(1 - collective.rank)"),
                check: checked).asArray(Int32.self)
            try checked()
            return actual
        }
        if collective.rank == 0 { try send(); return try receive() }
        let actual = try receive(); try send(); return actual
    }
}

/// The scope both ranks key their entries by for one request. Every field is
/// part of the generation agreement both ranks already proved equal.
func qwenStagePrefixScope(_ agreement: QwenLayerStageGenerationAgreement) -> String {
    let d = agreement.descriptor
    return [d.planFingerprint, d.artifactAggregateSHA256, d.storageCommitmentSHA256, d.sourceConfigurationSHA256,
            d.numericalPolicySHA256, d.profileFingerprint, "chunk=\(agreement.request.chunkSize)"].joined(separator: "|")
        + (agreement.request.mimoImages.map { "|mimo-images=" + $0.fingerprint } ?? "")
}

/// The same scope before the agreement exists (at reservation), from the
/// fields the agreement takes it from.
func qwenStagePrefixScope(source: QwenLayerStageWireSourceIdentity, numericalPolicySHA256: String,
                          request: QwenLayerStageGenerationRequest) -> String {
    [source.planFingerprint, source.artifactAggregateSHA256, source.storageCommitmentSHA256,
     source.sourceConfigurationSHA256, numericalPolicySHA256, request.profile.fingerprint,
     "chunk=\(request.chunkSize)"].joined(separator: "|")
        + (request.mimoImages.map { "|mimo-images=" + $0.fingerprint } ?? "")
}
