import Foundation
import MLX
import Testing
@testable import DarkbloomClusterRuntime

/// The tool path's request (`generateRounds`, `darkbloom-cluster-tp-check gemma run --mtp-depth`) for a prompt
/// shorter than the chunk size: the prompt is one chunk, as the plain path takes it. CPU only; never a model pass.
@Suite("Gemma 4 rounds request")
struct Gemma4TensorParallelAssistantChunkTests {
    /// H1/H2 ran 43-167-token prompts with `--chunk-size 512`: the rounds request must accept them (it refused with
    /// "Generation profile exceeds native software bounds") and prefill them in one chunk of the prompt's length.
    @Test func aChunkLongerThanThePromptIsThePrompt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gemma4-rounds-chunk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Device.withDefaultDevice(.cpu) {
            try Gemma4TensorParallelModel.writeSyntheticCheckpoint(directory: directory, bits: 4)
            let model = try Gemma4TensorParallelModel.load(modelDirectory: directory, role: .full, reduction: nil)
            let prompt = (0 ..< 40).map { ($0 * 37 + 11) % 512 }
            let short = try model.roundsRequest(prompt: prompt, outputCount: 8, chunk: 512)
            #expect(short.chunkSize == prompt.count && short.promptCount == prompt.count)
            let long = try model.roundsRequest(prompt: prompt, outputCount: 8, chunk: 16)
            #expect(long.chunkSize == 16)
        }
    }
}
