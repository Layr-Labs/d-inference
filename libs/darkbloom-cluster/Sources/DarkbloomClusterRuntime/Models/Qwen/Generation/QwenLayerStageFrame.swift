import Foundation

struct QwenLayerStageFrame: Codable, Equatable {
    enum Phase: String, Codable { case prefill, decode }
    let sequence: Int
    let phase: Phase
    let tokenOffset: Int
    let tokenCount: Int
    let finalPromptChunk: Bool
}
