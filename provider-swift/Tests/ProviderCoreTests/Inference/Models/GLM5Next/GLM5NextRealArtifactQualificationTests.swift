import CoreImage
import Foundation
import MLXLMCommon
import ProviderCoreFoundation
import Testing

@_spi(Benchmarking) @testable import ProviderCore

/// Explicit offline qualification only. No directory defaults, catalog calls,
/// downloads or live provider accounts. Enabling this test is authorization for
/// its expensive real LOAD; ordinary test runs never read the artifact.
@Suite(.serialized) struct GLM5NextRealArtifactQualificationTests {
    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["DARKBLOOM_TEST_GLM5_REAL_ARTIFACT"] == "1"))
    func realPinnedArtifactShortTextBaseline() async throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = URL(
            fileURLWithPath: try #require(environment["DARKBLOOM_TEST_GLM5_REAL_MODEL_DIR"]))
        let manifest = URL(
            fileURLWithPath: try #require(environment["DARKBLOOM_TEST_GLM5_REAL_MANIFEST"]))
        let expected = try #require(environment["DARKBLOOM_TEST_GLM5_REAL_AGGREGATE_SHA256"])
        let maximumContextLength = try #require(
            environment["DARKBLOOM_TEST_GLM5_REAL_MAX_CONTEXT"].flatMap(Int.init))
        try #require(expected == "446d3674694940f8e3c3282e4296b185774d1f76c7ca0a540c880e3e80cbe6e7")
        let plan = try GLM5NextLocalQualification.plan(
            directory: directory, manifestURL: manifest,
            source: .init(
                repoID: "Vontra/GLM-5.3-Flash-MLX-4bit-MTP",
                revision: "76add2a341a1cd90ad0e86bb69839ea9c35827c6"),
            expectedAggregateSHA256: expected)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "glm5-real-qualification-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        let oldCache = ModelScanner.configuredCacheDirectory
        ModelScanner.configureCacheDirectory(temporary.appendingPathComponent("hub").path)
        defer {
            ModelScanner.configureCacheDirectory(oldCache)
            if !GLM5NextLoadFaultState.isRetained {
                try? FileManager.default.removeItem(at: temporary)
            }
        }
        var isolated = environment
        isolated["DARKBLOOM_PREFIX_CACHE"] = "0"
        isolated["DARKBLOOM_PREFIX_CACHE_MEMORY"] = "0"
        var loaded:
            (
                container: ModelContainer, session: EngineV2BenchmarkSession,
                maximumContextLength: Int
            )?
        do {
            loaded = try await EngineV2Factory.loadGLM5NextBenchmarkSession(
                directory: directory,
                catalog: plan.weights.catalog, manifest: plan.weights.manifest,
                maximumContextLength: maximumContextLength,
                operatorReserveBytes: MLXMemoryGuard.defaultReserveGB * (1 << 30),
                environment: isolated)
            #expect(loaded!.maximumContextLength == maximumContextLength)
            let prompt = try await loaded!.container.perform { context in
                try context.tokenizer.applyChatTemplate(
                    messages: [["role": "user", "content": "Say hello briefly."]],
                    tools: nil,
                    additionalContext: ["reasoning_effort": "low", "clear_thinking": false])
            }
            #expect(!prompt.isEmpty)
            try GLM5NextExecutionBound.validateRequest(
                promptTokens: prompt.count, maximumOutputTokens: 4,
                limit: loaded!.maximumContextLength)
            let submission = try await loaded!.session.submit(
                .init(
                    id: .init(1), promptTokens: prompt,
                    sampling: .init(temperature: 0), maxTokens: 4, prefixCacheEnabled: false))
            var generated: [Int] = []
            var finished = false
            for await event in submission.events {
                if case .delta(_, let tokens, _) = event { generated += tokens }
                if case .finished = event { finished = true }
            }
            await loaded!.session.complete(receiptID: submission.receiptID)
            #expect(finished && !generated.isEmpty && generated.count <= 4)
            // These are separate requested probes, never inferred from a
            // successful text load or counted as cross-framework parity.
            if environment["DARKBLOOM_TEST_GLM5_REAL_MEDIA"] == "1" {
                let image = CIImage(color: CIColor(red: 0.2, green: 0.3, blue: 0.4))
                    .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
                let png = try #require(
                    CIContext(options: [.useSoftwareRenderer: true]).pngRepresentation(
                        of: image, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()))
                let body = try JSONSerialization.data(withJSONObject: [
                    "model": plan.weights.catalog.id,
                    "messages": [
                        [
                            "role": "user",
                            "content": [
                                ["type": "text", "text": "Describe the color."],
                                [
                                    "type": "image_url",
                                    "image_url": [
                                        "url": "data:image/png;base64," + png.base64EncodedString()
                                    ],
                                ],
                            ],
                        ]
                    ],
                ])
                let request = try ProviderLoop.decodeOpenAIRequest(body, modelType: "glm5_next")
                let prepared = try await EngineV2VisionPrefill.prepare(
                    container: loaded!.container, request: request)
                try GLM5NextExecutionBound.validateRequest(
                    promptTokens: prepared.promptTokens.count,
                    maximumOutputTokens: 2, limit: loaded!.maximumContextLength)
                let media = try await loaded!.session.submit(
                    .init(
                        id: .init(2), promptTokens: prepared.promptTokens,
                        sampling: .init(temperature: 0), maxTokens: 2, prefixCacheEnabled: false,
                        multimodal: prepared.multimodalInput()))
                var count = 0
                for await event in media.events {
                    if case .delta(_, let tokens, _) = event { count += tokens.count }
                }
                await loaded!.session.complete(receiptID: media.receiptID)
                #expect(count > 0 && count <= 2)
            }
            if environment["DARKBLOOM_TEST_GLM5_REAL_TOOLS"] == "1" {
                let body = Data(
                    """
                    {"model":"glm5-qualification","messages":[{"role":"user","content":"What time is it?"}],"tools":[{"type":"function","function":{"name":"clock","parameters":{"type":"object","properties":{}}}}],"reasoning_effort":"low"}
                    """.utf8)
                let tokens = try await loaded!.container.perform { context in
                    try ProviderPromptContractPipeline.tokenizeProviderBody(
                        body, tokenizer: context.tokenizer, modelType: "glm5_next")
                }
                #expect(!tokens.isEmpty)
                try GLM5NextExecutionBound.validateRequest(
                    promptTokens: tokens.count, maximumOutputTokens: 2,
                    limit: loaded!.maximumContextLength)
                let tools = try await loaded!.session.submit(
                    .init(
                        id: .init(3), promptTokens: tokens,
                        sampling: .init(temperature: 0), maxTokens: 2, prefixCacheEnabled: false))
                for await _ in tools.events {}
                await loaded!.session.complete(receiptID: tools.receiptID)
            }
            try await loaded!.session.shutdownReportingCompletion()
            await ModelContainerLoading.releaseExternalResources(in: loaded!.container)
            loaded = nil
        } catch {
            if let loaded {
                try await loaded.session.shutdownReportingCompletion()
                await ModelContainerLoading.releaseExternalResources(in: loaded.container)
            }
            throw error
        }
    }
}
