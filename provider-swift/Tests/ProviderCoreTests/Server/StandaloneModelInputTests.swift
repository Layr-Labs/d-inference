import Foundation
import Testing
@testable import ProviderCore

/// `start --local`: this Mac's `/v1/models` takes each served model's input from the model's own word, loaded or not.
/// (A server pins MLX's memory limits when it is made, so this suite needs a Metal device.)
@Suite("The standalone server lists each model's input")
struct StandaloneModelInputTests {
    @Test func theStandaloneServerListsEachModelsInput() async {
        let server = StandaloneServer(config: .init(port: 0), models: [
            ModelInfo(id: "org/vision", modelType: "gpt_oss", sizeBytes: 1, estimatedMemoryGb: 1, isVision: true),
            ModelInfo(id: "org/text", modelType: "gpt_oss", sizeBytes: 1, estimatedMemoryGb: 1),
        ])
        #expect(await server.localModelLimits("org/vision") == LocalModelLimits(inputModalities: ["text", "image"]))
        #expect(await server.localModelLimits("org/text") == LocalModelLimits(inputModalities: ["text"]))
        #expect(await server.localModelLimits("org/absent") == nil)
    }
}
