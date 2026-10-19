import Foundation
import CryptoKit
import DarkbloomClusterProtocol
import MLXLLM
import MLXLMCommon
import MLXVLM

/// Source-specific host preparation. It never creates model/MLX/raster objects.
/// The factory binds the actual loaded private profile to exact config bytes.
struct DistributedMiMoImageIngress: Sendable {
    let configuration: MiMoV26Configuration
    init(configuration bytes: Data, expectedSHA256: String) throws {
        let digest = SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined()
        guard bytes.count <= 1_048_576, digest == expectedSHA256 else {
            throw DistributedEngineError.invalidConfiguration("MiMo image configuration differs from loaded peers")
        }
        configuration = try JSONDecoder().decode(MiMoV26Configuration.self,from:bytes)
        _ = try MiMoV26ClusterImagePlan.settings(configuration:configuration)
    }
    func prepare(normalized: ProviderPromptContractPipeline.NormalizedInput, tokenizer: any Tokenizer,
                 maximumPromptTokens: Int, maximumOutputTokens: Int) throws -> (tokens:[Int], wire:Data) {
        var messages:[[String:any Sendable]] = []
        var pngs:[Data] = [], inspections:[MiMoV26ClusterImagePlan.Inspection] = []
        var remaining = ClusterMiMoImages.maximumEncodedBytes
        for raw in normalized.messages {
            var message = raw
            if let parts = raw["content"] as? [[String:any Sendable]] {
                var text = ""
                for part in parts {
                    switch part["type"] as? String {
                    case "text":
                        guard let value = part["text"] as? String else { throw bad() };text += value
                    case "image_url":
                        guard pngs.count < ClusterMiMoImages.maximumImages,
                              let uri = part["image_url"] as? String, uri.hasPrefix("data:image/png;base64,") else { throw bad() }
                        let prefix = "data:image/png;base64,"
                        guard uri.utf8.count <= prefix.utf8.count + (remaining+2)/3*4,
                              let data = Data(base64Encoded:String(uri.dropFirst(prefix.count))),data.count <= remaining else { throw bad() }
                        let i = try MiMoV26ClusterImagePlan.inspectPNG(data,configuration:configuration,
                            maximumEncodedBytes:remaining,maximumPixels:ClusterMiMoImages.maximumPixels)
                        guard i.geometry.patchCount <= ClusterMiMoImageCandidate.maximumPreparedPatches else { throw bad() }
                        remaining -= data.count;pngs.append(data);inspections.append(i)
                        text += "<|vision_start|><|image_pad|><|vision_end|>"
                    default: throw bad() // audio/video are still open requirements; never drop them
                    }
                }
                message["content"] = text
            }
            messages.append(message)
        }
        guard !pngs.isEmpty else { throw bad() }
        let symbolic = try tokenizer.applyChatTemplate(messages:messages,tools:normalized.tools,
            additionalContext:normalized.additionalContext)
        let expanded = try MiMoV26ClusterImagePlan.expand(symbolic:symbolic,inspections:inspections,
            configuration:configuration,tokenizer:tokenizer,maximumPromptTokens:maximumPromptTokens,
            maximumOutputTokens:maximumOutputTokens)
        let images = zip(zip(pngs,inspections),expanded.spans).map { value,span in
            ClusterMiMoImages.Image(png:value.0,width:value.1.width,height:value.1.height,
                tokenOffset:span.tokenOffset,tokenCount:span.length)
        }
        let media = ClusterMiMoImages(images:images);try media.validate(prompt:expanded.tokens)
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        let wire = try encoder.encode(media)
        guard wire.count <= 135_000 else { throw bad() }
        _ = try ClusterMiMoImages.decodeBounded(wire)
        return (expanded.tokens,wire)
    }
    private func bad() -> MultiModelBatchSchedulerEngineError {
        .multimodalRejected("MiMo private image slice requires bounded PNG input; video/audio remain unimplemented")
    }
}
