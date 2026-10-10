import Foundation

/// One fixed-size control transfer: a four-byte big-endian body length, the
/// body, zero padding. The receiver posts one buffer of a size it already
/// knows, so a message needs no separate length transfer.
enum QwenControlFrame {
    static let headerBytes = 4

    static func encode(_ body: Data, frameBytes: Int) throws -> Data {
        guard frameBytes > headerBytes, !body.isEmpty, body.count <= frameBytes - headerBytes else {
            throw ProbeError("Control frame body does not fit its fixed frame")
        }
        var frame = Data(count: frameBytes)
        let length = UInt32(body.count)
        frame[0] = UInt8(truncatingIfNeeded: length >> 24); frame[1] = UInt8(truncatingIfNeeded: length >> 16)
        frame[2] = UInt8(truncatingIfNeeded: length >> 8); frame[3] = UInt8(truncatingIfNeeded: length)
        frame.replaceSubrange(headerBytes..<(headerBytes + body.count), with: body)
        return frame
    }

    /// The padding must be zero: stale bytes after a body are a transport
    /// fault, not something to ignore.
    static func decode(_ frame: Data, frameBytes: Int) throws -> Data {
        guard frameBytes > headerBytes, frame.count == frameBytes else {
            throw ProbeError("Control frame has the wrong fixed size")
        }
        let bytes = [UInt8](frame)
        let length = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        guard length > 0, length <= frameBytes - headerBytes,
              bytes[(headerBytes + length)...].allSatisfy({ $0 == 0 }) else {
            throw ProbeError("Control frame length or zero padding is invalid")
        }
        return Data(bytes[headerBytes..<(headerBytes + length)])
    }
}

/// What rank 0 states about the state it is about to send: the frontier, the
/// selected history so far, and one digest per component. Everything except
/// the digests must equal the receiver's own expectation exactly.
struct QwenPhaseSplitHandoffHeader {
    struct Entry: Codable, Equatable {
        let globalLayerIndex: Int
        let component: String
        let shape: [Int]
        let dtype: String
        let byteCount: Int
        let sha256: String

        var identity: String { "\(globalLayerIndex)|\(component)|\(shape)|\(dtype)|\(byteCount)|\(sha256)" }
    }
    struct Content: Encodable, Equatable {
        let schema = "qwen_stage_phase_split_handoff_v1"
        let agreementFingerprint: String
        let membershipEpoch: String
        let requestFingerprint: String
        let committedTokens: Int
        let selectedTokenCount: Int
        let tokenChainSHA256: String
        let entries: [Entry]
        /// The state-snapshot fingerprint of exactly these entries.
        let stateSHA256: String
    }
    static let frameBytes = 32_768
    let content: Content
    let fingerprint: String

    init(agreement: QwenLayerStageGenerationAgreement, tokenChainSHA256: String, digests: [String]) throws {
        guard let split = agreement.phaseSplit, digests.count == split.shapes.count,
              digests.allSatisfy(qwenStageWireIsSHA256), qwenStageWireIsSHA256(tokenChainSHA256) else {
            throw ProbeError("Hand-off header needs one digest for every agreed state component")
        }
        let committed = split.terms.handoffCommittedTokens
        let entries = zip(split.shapes, digests).map {
            Entry(globalLayerIndex: $0.globalLayerIndex, component: $0.component, shape: $0.shape,
                  dtype: $0.dtype, byteCount: $0.byteCount, sha256: $1)
        }
        // The frontier fixes every position offset, so its digest is known here.
        let offsets = Self.positionOffsetsSHA256(committedTokens: committed)
        guard entries.allSatisfy({ $0.component != QwenPhaseSplitStateShape.positionOffsets || $0.sha256 == offsets }) else {
            throw ProbeError("Hand-off position offsets differ from the committed frontier")
        }
        content = .init(agreementFingerprint: agreement.fingerprint,
            membershipEpoch: agreement.descriptor.membershipEpoch,
            requestFingerprint: agreement.request.fingerprint, committedTokens: committed,
            selectedTokenCount: split.terms.handoffSelectedTokens, tokenChainSHA256: tokenChainSHA256,
            entries: entries, stateSHA256: Self.stateSHA256(entries, committedTokens: committed))
        fingerprint = try qwenGenerationFingerprint("phase-split-handoff", content)
    }

    func encoded() throws -> Data {
        let data = try canonicalJSONData(content)
        guard data.count <= Self.frameBytes - QwenControlFrame.headerBytes else {
            throw ProbeError("Hand-off header exceeds its fixed frame")
        }
        return data
    }

    /// An upper bound on the encoded header for these components, whatever the
    /// digests and identities turn out to be: every digest and fingerprint has
    /// a fixed length, and the other fields are bounded by `fixedFieldBytes`.
    static let fixedFieldBytes = 1024
    static func encodedBytesBound(shapes: [QwenPhaseSplitStateShape]) throws -> Int {
        let placeholder = String(repeating: "0", count: 64)
        let entries = shapes.map {
            Entry(globalLayerIndex: $0.globalLayerIndex, component: $0.component, shape: $0.shape,
                  dtype: $0.dtype, byteCount: $0.byteCount, sha256: placeholder)
        }
        return try QwenLongPrefillCheckedBytes.sum([fixedFieldBytes, try canonicalJSONData(entries).count])
    }

    /// Only the digests are read from the wire. The header is then rebuilt
    /// from local values and must equal the received bytes field for field.
    static func decode(_ data: Data, agreement: QwenLayerStageGenerationAgreement,
                       tokenChainSHA256: String) throws -> Self {
        let object = try QwenLayerStageGenerationWireJSON.object(data, maximumBytes: frameBytes)
        guard let entries = object["entries"] as? [[String: Any]] else { throw ProbeError("Hand-off header lists no entries") }
        let digests = try entries.map { entry -> String in
            guard let digest = entry["sha256"] as? String else { throw ProbeError("Hand-off entry digest missing") }
            return digest
        }
        let result = try Self(agreement: agreement, tokenChainSHA256: tokenChainSHA256, digests: digests)
        try QwenLayerStageGenerationWireJSON.requireExact(object, result.content)
        return result
    }

    /// The runtime's state-identity convention (`CBv2OwnedStateSnapshot`).
    static func stateSHA256(_ entries: [Entry], committedTokens: Int) -> String {
        sha256(Data((["cbv2-owned-state-v1", "tokens=\(committedTokens)"] + entries.map(\.identity))
            .joined(separator: "\n").utf8))
    }

    static func positionOffsetsSHA256(committedTokens: Int) -> String {
        var value = Int32(committedTokens).littleEndian
        return sha256(Data(bytes: &value, count: 4))
    }
}

/// Tokens rank 1 selected alone, with the digest of the residual each one was
/// computed from. Rank 0 replays them through the same control state machine,
/// so both ranks hold one selected history and one token chain.
struct QwenPhaseSplitRelayPacket {
    struct Content: Encodable, Equatable {
        let schema = "qwen_stage_phase_split_relay_v1"
        let agreementFingerprint: String
        let membershipEpoch: String
        let requestFingerprint: String
        let handoffFingerprint: String
        let firstOrdinal: Int
        let previousTokenChainSHA256: String
        let tokenIDs: [Int]
        let payloadSHA256: [String]
    }
    static let frameBytes = 8192
    let content: Content
    let fingerprint: String

    init(agreement: QwenLayerStageGenerationAgreement, handoffFingerprint: String, firstOrdinal: Int,
         previousTokenChainSHA256: String, tokenIDs: [Int], payloadSHA256: [String]) throws {
        let request = agreement.request
        guard let split = agreement.phaseSplit, (1...split.terms.relayBatchTokens).contains(tokenIDs.count),
              payloadSHA256.count == tokenIDs.count, payloadSHA256.allSatisfy(qwenStageWireIsSHA256),
              qwenStageWireIsSHA256(handoffFingerprint), qwenStageWireIsSHA256(previousTokenChainSHA256),
              firstOrdinal >= split.terms.handoffSelectedTokens, firstOrdinal <= request.outputCount - tokenIDs.count,
              tokenIDs.allSatisfy({ (0..<request.profile.vocabularySize).contains($0) }),
              // A stop token ends the batch; nothing may follow it.
              !tokenIDs.dropLast().contains(where: request.stopTokenIDs.contains) else {
            throw ProbeError("Relay batch differs from the agreed ordinals, size or vocabulary")
        }
        content = .init(agreementFingerprint: agreement.fingerprint, membershipEpoch: agreement.descriptor.membershipEpoch,
            requestFingerprint: request.fingerprint, handoffFingerprint: handoffFingerprint, firstOrdinal: firstOrdinal,
            previousTokenChainSHA256: previousTokenChainSHA256, tokenIDs: tokenIDs, payloadSHA256: payloadSHA256)
        fingerprint = try qwenGenerationFingerprint("phase-split-relay", content)
    }

    func encoded() throws -> Data {
        let data = try canonicalJSONData(content)
        guard data.count <= Self.frameBytes - QwenControlFrame.headerBytes else { throw ProbeError("Relay batch exceeds its fixed frame") }
        return data
    }

    static func decode(_ data: Data, agreement: QwenLayerStageGenerationAgreement, handoffFingerprint: String,
                       firstOrdinal: Int, previousTokenChainSHA256: String) throws -> Self {
        let object = try QwenLayerStageGenerationWireJSON.object(data, maximumBytes: frameBytes)
        guard let rawTokens = object["tokenIDs"] as? [Any], let digests = object["payloadSHA256"] as? [String] else {
            throw ProbeError("Relay batch lists no tokens")
        }
        let tokens = try rawTokens.map { value -> Int in
            guard let token = BoundedProbeInput.integer(value) else { throw ProbeError("Relay token must be an integer") }
            return token
        }
        let result = try Self(agreement: agreement, handoffFingerprint: handoffFingerprint, firstOrdinal: firstOrdinal,
            previousTokenChainSHA256: previousTokenChainSHA256, tokenIDs: tokens, payloadSHA256: digests)
        try QwenLayerStageGenerationWireJSON.requireExact(object, result.content)
        return result
    }
}

/// Rank 0's answer to one relay batch: how many of its tokens were published
/// and the decision that followed the last of them.
struct QwenPhaseSplitRelayDecisionPacket {
    struct Content: Encodable, Equatable {
        let schema = "qwen_stage_phase_split_relay_decision_v1"
        let agreementFingerprint: String
        let membershipEpoch: String
        let requestFingerprint: String
        let relayFingerprint: String
        let acceptedCount: Int
        let selectedTokenCount: Int
        let tokenChainSHA256: String
        let decision: QwenLayerStageGenerationDecision
    }
    static let frameBytes = 2048
    let content: Content
    let fingerprint: String

    init(agreement: QwenLayerStageGenerationAgreement, relay: QwenPhaseSplitRelayPacket, acceptedCount: Int,
         selectedTokenCount: Int, tokenChainSHA256: String, decision: QwenLayerStageGenerationDecision) throws {
        let count = relay.content.tokenIDs.count
        guard relay.content.agreementFingerprint == agreement.fingerprint, (1...count).contains(acceptedCount),
              selectedTokenCount == relay.content.firstOrdinal + acceptedCount,
              qwenStageWireIsSHA256(tokenChainSHA256),
              // Only a stop may leave relayed tokens unpublished.
              acceptedCount == count || decision != .proceed else {
            throw ProbeError("Relay decision differs from its batch")
        }
        content = .init(agreementFingerprint: agreement.fingerprint, membershipEpoch: agreement.descriptor.membershipEpoch,
            requestFingerprint: agreement.request.fingerprint, relayFingerprint: relay.fingerprint,
            acceptedCount: acceptedCount, selectedTokenCount: selectedTokenCount,
            tokenChainSHA256: tokenChainSHA256, decision: decision)
        fingerprint = try qwenGenerationFingerprint("phase-split-relay-decision", content)
    }

    func encoded() throws -> Data { try canonicalJSONData(content) }

    static func decode(_ data: Data, agreement: QwenLayerStageGenerationAgreement,
                       relay: QwenPhaseSplitRelayPacket) throws -> Self {
        let object = try QwenLayerStageGenerationWireJSON.object(data, maximumBytes: frameBytes)
        guard let accepted = BoundedProbeInput.integer(object["acceptedCount"]),
              let selected = BoundedProbeInput.integer(object["selectedTokenCount"]),
              let chain = object["tokenChainSHA256"] as? String, let spelling = object["decision"] as? String,
              let decision = QwenLayerStageGenerationDecision(rawValue: spelling) else {
            throw ProbeError("Relay decision is incomplete")
        }
        let result = try Self(agreement: agreement, relay: relay, acceptedCount: accepted,
            selectedTokenCount: selected, tokenChainSHA256: chain, decision: decision)
        try QwenLayerStageGenerationWireJSON.requireExact(object, result.content)
        return result
    }
}
