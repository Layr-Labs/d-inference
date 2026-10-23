import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLMCommon
import MLXVLM
import Testing
@testable import DarkbloomClusterRuntime

@Suite(.serialized)
struct QwenMediaStateTests {
    private let hash = String(repeating: "a", count: 64)
    private let prompt = [4, 57, 60, 60, 60, 60, 58, 5, 57, 61, 61, 58, 6]
    private func fixture(positionHash: String? = nil, encoded: UInt8 = 1) throws
        -> (ClusterQwenMedia, QwenMediaModelIdentity) {
        let configuration = try JSONDecoder().decode(Qwen35Configuration.self, from: Data(#"{"model_type":"qwen3_5","image_token_id":60,"video_token_id":61,"vision_start_token_id":57,"vision_end_token_id":58,"text_config":{"model_type":"qwen3_5_text","hidden_size":8,"num_hidden_layers":1,"intermediate_size":16,"num_attention_heads":1,"num_key_value_heads":1,"head_dim":8,"linear_num_key_heads":1,"linear_num_value_heads":1,"linear_key_head_dim":8,"linear_value_head_dim":8,"linear_conv_kernel_dim":2,"vocab_size":64,"full_attention_interval":1},"vision_config":{"model_type":"qwen3_5_vision","depth":1,"hidden_size":8,"intermediate_size":16,"out_hidden_size":8,"num_heads":2,"patch_size":16,"spatial_merge_size":2,"temporal_patch_size":2,"num_position_embeddings":16,"in_channels":3,"hidden_act":"gelu_pytorch_tanh","deepstack_visual_indexes":[]}}"#.utf8))
        let result = try QwenVisionSeamSupport.positionResult(tokens: MLXArray(prompt.map(Int32.init)),
            imageGrids: [THW(1, 4, 4)], videoGrids: [THW(2, 2, 2)], attentionMask: nil,
            seam: configuration.visionSeamConfiguration)
        let data = Data([encoded])
        let media = ClusterQwenMedia(artifactSHA256: hash, configurationSHA256: hash,
            processorSHA256: hash, processorPolicy: .qwen35, promptLength: prompt.count,
            promptSHA256: ClusterQwenMedia.int32SHA256(prompt.map(Int32.init)),
            positionIDsSHA256: positionHash ?? ClusterQwenMedia.int32SHA256(result.promptPositionIds.asArray(Int32.self)),
            decodeDeltas: result.decodeState.deltas, items: [
                .init(kind: .image, sha256: ClusterQwenMedia.sha256(data), byteCount: 1, decodedPixels: 4096,
                    encoded: data, temporal: 1, height: 4, width: 4, tokenOffset: 2, tokenCount: 4, patchesSHA256: hash),
                .init(kind: .video, sha256: ClusterQwenMedia.sha256(data), byteCount: 1, decodedPixels: 1024,
                    encoded: data, temporal: 2, height: 2, width: 2, tokenOffset: 9, tokenCount: 2, patchesSHA256: hash)])
        return (media, .init(artifactSHA256: hash, configurationSHA256: hash,
            processorSHA256: hash, configuration: configuration, featureDType: .bfloat16))
    }
    private func state(_ media: ClusterQwenMedia, _ identity: QwenMediaModelIdentity) throws -> QwenMediaRequestState {
        try QwenMediaRequestState(media: media, prompt: prompt, identity: identity,
            maximumPrompt: 128, maximumContext: 256)
    }
    @Test func independentPositionsAndPartialSplicesMatchWholePrompt() throws {
        try Device.withDefaultDevice(.cpu) {
            let (media, identity) = try fixture()
            let a = try state(media, identity)
            let follower = try state(media.withoutEncodedBytes, identity)
            #expect(a.prefixIdentity == follower.prefixIdentity)
            #expect(a.promptPositions == follower.promptPositions)
            let image = MLXArray((0..<32).map { Float($0) }).reshaped(4, 8).asType(.bfloat16)
            let video = MLXArray((0..<16).map { Float($0 + 100) }).reshaped(2, 8).asType(.bfloat16)
            try a.installFeatures([image, video])
            let text = MLXArray.ones([1, prompt.count, 8], dtype: .bfloat16)
            let whole = try a.merging(text, range: 0..<prompt.count)
            let chunks = try [0..<3, 3..<5, 5..<10, 10..<prompt.count].map {
                try a.merging(text[0..., $0, 0...], range: $0)
            }
            let joined = concatenated(chunks, axis: 1)
            eval(whole, joined)
            #expect(whole.asArray(Float.self).map(\.bitPattern) == joined.asArray(Float.self).map(\.bitPattern))
            let values = whole.asArray(Float.self)
            #expect(Array(values[16..<48]) == image.asArray(Float.self))
            #expect(Array(values[72..<88]) == video.asArray(Float.self))
            let decode = try a.positions(in: prompt.count..<(prompt.count + 2)).asArray(Int32.self)
            let start = Int32(prompt.count) + media.decodeDeltas[0]
            #expect(decode == [start, start + 1, start, start + 1, start, start + 1])
            let (other, _) = try fixture(encoded: 2)
            #expect(try state(other, identity).prefixIdentity != a.prefixIdentity)
            a.releaseAfterCheckedDrain()
            #expect(a.features.isEmpty)
            #expect(throws: (any Error).self) { try a.merging(text, range: 0..<prompt.count) }
        }
    }
    @Test func badReceiptAndFeatureGeometryRefuseBeforeStateMutation() throws {
        try Device.withDefaultDevice(.cpu) {
            let (bad, identity) = try fixture(positionHash: hash)
            #expect(throws: (any Error).self) { try state(bad, identity) }
            let (media, _) = try fixture()
            let a = try state(media, identity)
            #expect(throws: (any Error).self) {
                try a.installFeatures([MLXArray.zeros([4, 8], dtype: .bfloat16),
                    MLXArray.zeros([2, 8], dtype: .float16)])
            }
            #expect(a.features.isEmpty)
            #expect(throws: (any Error).self) { try a.positions(in: 255..<257) }
            #expect(throws: (any Error).self) { try a.positions(in: -1..<1) }
            #expect(throws: (any Error).self) { try a.positions(in: 0..<0) }
        }
    }
    @Test func quotePricesNativeOwnershipAndRefusesOverflow() throws {
        try Device.withDefaultDevice(.cpu) {
            let (media, _) = try fixture()
            func quote(_ rank: Int, _ tp: Bool, _ chunk: Int = 128, _ maximum: Int = Int.max) throws -> QwenMediaBudget {
                try QwenMediaBudget(media: media, rank: rank, hiddenSize: 8, featureElementBytes: 2, maximumVideoPatches: 64,
                    tensorParallel: tp, chunkTokens: chunk, minimumActivationBytes: 1024,
                    maximumBufferBytes: maximum, sealedFrameOverhead: 1024, allocationBound: { $0 })
            }

            var allocations: [Int] = []
            let rounded = try QwenMediaBudget(media: media, rank: 1, hiddenSize: 8,
                featureElementBytes: 2, maximumVideoPatches: 64, tensorParallel: true,
                chunkTokens: 3, minimumActivationBytes: 0, maximumBufferBytes: Int.max,
                sealedFrameOverhead: 1024, allocationBound: { bytes in
                    allocations.append(bytes); return bytes + 16_384
                })
            let exact = try quote(1, true, 3)
            #expect(rounded.nativeBytes > exact.nativeBytes && rounded.hostBytes > exact.hostBytes)
            // Four image feature rows transfer as 3+1 separately; rounding
            // must see both chunks and both full source/result allocations.
            #expect(allocations.contains(48) && allocations.contains(16))
            #expect(allocations.contains(3 * 8 * 4 * 2 + 1024))
            #expect(throws: (any Error).self) {
                try QwenMediaBudget(media: media, rank: 1, hiddenSize: 8, featureElementBytes: 2,
                    maximumVideoPatches: 64, tensorParallel: true, chunkTokens: 3,
                    minimumActivationBytes: 0, maximumBufferBytes: Int.max,
                    sealedFrameOverhead: 1024, allocationBound: { $0 - 1 })
            }
            let lead = try quote(0, true), follow = try quote(1, true), pipeline = try quote(1, false)
            #expect(lead.hostBytes > follow.hostBytes)
            #expect(lead.nativeBytes > follow.nativeBytes)
            #expect(follow.nativeBytes > pipeline.nativeBytes)
            #expect(lead.totalBytes == lead.hostBytes + lead.nativeBytes)
            #expect(try quote(0, true, media.promptLength) == lead)
            #expect(throws: (any Error).self) { try quote(0, true, 128, 16) }
            #expect(throws: (any Error).self) { try quote(2, true) }
            #expect(throws: (any Error).self) { try quote(0, true, 0) }
            #expect(throws: (any Error).self) {
                try QwenMediaBudget(media: media, rank: 0, hiddenSize: Int.max, featureElementBytes: 2, maximumVideoPatches: 64,
                    tensorParallel: true, chunkTokens: 128, minimumActivationBytes: 1024,
                    maximumBufferBytes: Int.max, sealedFrameOverhead: 1024, allocationBound: { $0 })
            }
        }
    }
}
