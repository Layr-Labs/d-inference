import Foundation

enum QwenLayerStageGenerationFinishReason: String, Encodable { case eos, length, clientStop }
