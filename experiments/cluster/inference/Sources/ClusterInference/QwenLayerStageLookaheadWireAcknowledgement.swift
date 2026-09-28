import Foundation

/// The v2 namespace binds flow, phase and the exact admitted outer wire bytes.
/// `received` does not assert model consumption; `consumed` remains a separate
/// transition. This codec admits bytes only and implements no transport state.
enum QwenLayerStageLookaheadWireAcknowledgement {
    enum Phase: String, CaseIterable { case ready, received, consumed }
    static let elements = 64
    static let byteCount = elements * MemoryLayout<Int32>.size

    static func values(envelope: QwenLayerStageLookaheadWireEnvelope,
                       phase: Phase) -> [Int32] {
        let identity = "qwen-stage-ack-v2|\(QwenLayerStageLookaheadWireEnvelope.flow)|\(phase.rawValue)|\(sha256(envelope.encoded()))"
        return sha256(Data(identity.utf8)).utf8.map(Int32.init)
    }

    static func validate(_ actual: [Int32], envelope: QwenLayerStageLookaheadWireEnvelope,
                         phase: Phase) throws {
        guard actual == values(envelope: envelope, phase: phase) else {
            throw ProbeError("Lookahead v2 acknowledgement differs from its exact envelope, flow or transition")
        }
    }
}
