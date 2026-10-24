import DarkbloomClusterPlacement
import Foundation
import Testing
@testable import DarkbloomClusterRuntime

struct QwenTensorParallelBatchQuoteTests {
    private struct Inputs: Decodable {
        struct Tensor: Decodable { let name: String; let shape: [Int]; let sourceDType: String; let byteCount: Int }
        struct Profile: Decodable { let configuration: Data; let canonicalTensors: [Tensor] }
        let twentySeven: Profile
    }
    private func bound(_ bytes: Int) -> Int { ((bytes + 16383) / 16384) * 16384 }

    @Test func headerOnlyQuoteEqualsActualOwnerBudgetForEveryWidthAndShare() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("StageMetadataChecks/Inputs/qwen-retained-inputs.json")
        let input = try JSONDecoder().decode(Inputs.self, from: Data(contentsOf: source)).twentySeven
        let family = try QwenDensePlacementFamily(configuration: input.configuration)
        let canonical = try family.requireRegisteredInventory(input.canonicalTensors.map {
            .init(name: $0.name, byteCount: $0.byteCount, dtype: $0.sourceDType, shape: $0.shape)
        })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try input.configuration.write(to: directory.appendingPathComponent("config.json"))
        // A sparse zero payload makes payload reads impossible to mistake for
        // artifact validation. Only the real registered tensor headers exist.
        var offset = 0, header: [String: Any] = [:]
        for tensor in input.canonicalTensors {
            header[tensor.name] = ["dtype": tensor.sourceDType, "shape": tensor.shape,
                "data_offsets": [offset, offset + tensor.byteCount]]
            offset += tensor.byteCount
        }
        let encoded = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        var length = UInt64(encoded.count).littleEndian
        let url = directory.appendingPathComponent("header-only.safetensors")
        try withUnsafeBytes(of: &length) { Data($0) }.write(to: url)
        let file = try FileHandle(forWritingTo: url)
        try file.seekToEnd(); try file.write(contentsOf: encoded)
        try file.truncate(atOffset: UInt64(8 + encoded.count + offset)); try file.close()
        let root = try JSONSerialization.jsonObject(with: input.configuration) as! [String: Any]
        let text = root["text_config"] as! [String: Any], quantization = root["quantization"] as! [String: Any]
        for lanes in [1, 2, 4, 8] {
            let quote = try ClusterPlacementArtifact.requestedTensorBatchQuote(directory: directory,
                promptTokens: 1024, outputTokens: 9, chunkTokens: 128, lanes: lanes, allocationBound: bound)
            #expect(quote.request.promptTokens == 1024 && quote.request.outputTokens == 9 && quote.chunkTokens == 128)
            #expect(quote.allowance.maximumContextTokens == family.profile.maximumContextTokens)
            #expect(quote.allowance.maximumChunkTokens == family.profile.maximumChunkTokens)
            for shares in family.tensorParallelShareOptions {
                let plan = try QwenTensorParallelPlan(textConfiguration: text, quantization: quantization, size: 2, shares: shares)
                let native = try QwenTensorParallelBatchBudget.derive(geometry: family.geometry, plan: plan,
                    tensors: canonical, maximumTokens: family.profile.maximumContextTokens,
                    chunkSize: family.profile.maximumChunkTokens, lanes: lanes, paged: true, allocationBound: bound)
                #expect(quote.allowance == native.allowance)
                #expect(quote.perLaneStateBytes == native.perLaneStateBytes)
                let contiguous = try QwenTensorParallelBatchBudget.derive(geometry: family.geometry, plan: plan,
                    tensors: canonical, maximumTokens: family.profile.maximumContextTokens,
                    chunkSize: family.profile.maximumChunkTokens, lanes: lanes, paged: false, allocationBound: bound)
                #expect(quote.allowance.reservedBytes >= contiguous.allowance.reservedBytes)
            }
        }
        #expect(throws: (any Error).self) {
            try ClusterPlacementArtifact.requestedTensorBatchQuote(directory: directory, promptTokens: 1024, outputTokens: 9,
                chunkTokens: 128, lanes: 8, allocationBound: { $0 - 1 })
        }
        #expect(throws: (any Error).self) {
            try ClusterPlacementArtifact.requestedTensorBatchQuote(directory: directory, promptTokens: 1024, outputTokens: 9,
                chunkTokens: 128, lanes: 3, allocationBound: bound)
        }
    }
}
