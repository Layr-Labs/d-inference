// Copyright © 2026 Eigen Labs.

import MLXLMServer
import Testing

@testable import ProviderCore
// MARK: - Media-kind classification

@Suite("MediaIngest.hasVideo + EngineV2VisionPrefill.mediaKind")
struct MediaKindClassificationTests {
    @Test("media processor receives the request's reasoning template switch")
    func reasoningTemplateContext() async throws {
        for enabled in [false, true] {
            var request = visionImageRequest()
            request.reasoning = OpenAIReasoningConfig(enabled: enabled)
            let input = try await MediaIngest.buildUserInput(from: request)
            #expect(input.additionalContext?["enable_thinking"] as? Bool == enabled)
        }
    }

    @Test("media processor preserves out-of-band reasoning effort")
    func reasoningEffortTemplateContext() async throws {
        let request = visionImageRequest()
        let input = try await MediaIngest.buildUserInput(
            from: request, reasoningEffort: "high")
        #expect(input.additionalContext?["reasoning_effort"] as? String == "high")
    }

    @Test("image-only request has no video and classifies as .image")
    func imageOnly() {
        #expect(!MediaIngest.hasVideo(visionImageRequest()))
        #expect(EngineV2VisionPrefill.mediaKind(of: visionImageRequest()) == .image)
    }

    @Test("video part is detected; video/mixed classify correctly")
    func videoDetected() {
        let video = visionImageRequest(parts: [.videoURL("data:video/mp4;base64,AAAA")])
        #expect(MediaIngest.hasVideo(video))
        #expect(EngineV2VisionPrefill.mediaKind(of: video) == .video)
        let mixed = visionImageRequest(parts: [
            .imageURL(visionTinyPNGDataURI), .videoURL("data:video/mp4;base64,AAAA"),
        ])
        #expect(MediaIngest.hasVideo(mixed))
        #expect(EngineV2VisionPrefill.mediaKind(of: mixed) == .mixed)
    }

    @Test("mediaKind ignores non-user-role media (mirrors buildUserInput)")
    func nonUserRolesIgnored() {
        // A video part on an assistant message is dropped by buildUserInput,
        // so the kind must reflect the user-message media only — keeping
        // refusal tags consistent with the success path's lmInput-derived
        // kind.
        let request = OpenAIChatCompletionRequest(
            model: "test/vlm-stub",
            messages: [
                OpenAIChatMessage(
                    role: .assistant,
                    content: .parts([.videoURL("data:video/mp4;base64,AAAA")])),
                OpenAIChatMessage(
                    role: .user,
                    content: .parts([.text("what is this?"), .imageURL(visionTinyPNGDataURI)])),
            ],
            temperature: 0,
            maxTokens: 8
        )
        #expect(EngineV2VisionPrefill.mediaKind(of: request) == .image)
    }
}
