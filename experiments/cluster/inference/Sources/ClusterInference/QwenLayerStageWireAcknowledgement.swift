import Foundation

/// Acknowledgements bind both the completed header and the particular protocol
/// transition. No acknowledgement by itself claims model or state correctness.
enum QwenLayerStageWireAcknowledgement {
    enum Phase: String { case ready, consumed }
    static let elements = 64
    static let byteCount = elements * MemoryLayout<Int32>.size

    static func values(header: Data, phase: Phase) -> [Int32] {
        let identity = "qwen-stage-ack-v1|\(phase.rawValue)|\(sha256(header))"
        return sha256(Data(identity.utf8)).utf8.map(Int32.init)
    }

    static func validate(_ actual: [Int32], header: Data, phase: Phase) throws {
        guard actual == values(header: header, phase: phase) else {
            throw ProbeError("Stage wire acknowledgement differs from its header or transition")
        }
    }
}
