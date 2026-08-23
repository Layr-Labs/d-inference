// Copyright © 2026 Eigen Labs.
//
// Live (weight-gated) validation of v0.7.5 VIDEO-THROUGH-ENGINE_V2 on the
// production Gemma 4 checkpoint (`gemma-4-26b-qat-4bit`). Self-contained
// harness — deliberately independent of `GemmaVLMVisionEngineV2LiveTests`
// (same precedent that file set vs the 0.7.3 suites; nothing here touches
// it). Slots use `LiveInferenceFixtures.loadBridge`, which follows production
// direct shared-tower construction: one engine serves every slot request.
//
//   (a) CONSTRUCTION INTROSPECTION — `EngineV2VisionPrefill.prepare` on a
//       real 4-distinct-frame clip: one span per sampled frame, spans ==
//       embeddings, uniform per-frame soft-token counts (the data-driven
//       ~70-token video budget, far below the 280-token image spans),
//       `mediaKind == .video`. A mixed image+video request additionally
//       proves the interleaved pairing (one 280-token image span + N small
//       video spans in prompt order).
//
//   (b) VIDEO THROUGH V2 — a real video request routed through the
//       production seam (`MultiModelBatchSchedulerEngine
//       .streamChatCompletion`) on a v2-bridged slot. Asserted: the request
//       took the v2 path (bridge admit count grew, zero refusal ERRORs);
//       greedy determinism (same clip + prompt twice ⇒ identical);
//       embedding steering (an all-red clip vs an all-blue clip with the
//       same prompt produce different completions); a mixed image+video
//       request serves end-to-end; and an interleaved video request leaves
//       a v2 text decode byte-identical. TTFT for the v2 video request is
//       measured and logged (informational — the vision tower runs
//       pre-submit).
//
//       The removed legacy comparison is no longer needed for tower parity:
//       direct VLM and CBv2 now invoke the same `Gemma4TextModel` instance.
//       Media without a v2 bridge still fails loudly, as pinned by non-live
//       routing tests.
//
//   (c) 32-FRAME SAMPLING CAP — a 40-second, 40-frame clip: the processor
//       samples uniformly and caps at 32; construction must carve ≤ 32
//       per-frame spans (and ≥ 30 — edge samples may be skipped by
//       AVAssetImageGenerator at exact boundaries) and the request must
//       still serve end-to-end through v2.
//
// FIXTURES are generated AT TEST TIME via AVFoundation (AVAssetWriter →
// H.264 mp4 of solid-color frames — deterministic content, nothing binary
// checked in) and passed inline as base64 `data:` URIs, exactly like a
// real E2E-encrypted request.
//
// Teardown here is structured (bridge shutdown awaited on every exit path)
// so this suite never overlaps residency with other serialized live runs.
//
// Gated like the other multi-GB Gemma tests: DARKBLOOM_LIVE_MLX_TESTS +
// DARKBLOOM_LIVE_MLX_GEMMA, and the checkpoint is skipped cleanly when not
// in the local HF cache. Run live suites one at a time (--filter) —
// distinct suites are parallel by default and two 26B loads won't coexist.

import AVFoundation
import CoreVideo
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXLMServer
import MLXVLM
import Testing

@testable import ProviderCore

// A real, round-trip-verified 16x16 solid-red PNG (same bytes as the vision
// live suite) for the mixed image+video stage.
private let videoSuiteRedPNGDataURI =
    "data:image/png;base64,"
    + "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAFklEQVR42mO4IyJCEmIY"
    + "1TCqYfhqAAACcQQQFd0BdQAAAABJRU5ErkJggg=="

// MARK: - Synthetic clip generation (AVFoundation, test-time)

private struct VideoFixtureError: Error, CustomStringConvertible {
    let description: String
}

/// Encode `colors.count` solid-color frames as an H.264 mp4 at `fps` and
/// return the file bytes. Frame i spans [i/fps, (i+1)/fps); the session
/// ends at colors.count/fps, so a 4-frame 32 fps clip is 0.125 s (the
/// Gemma4 sampler — `round(32/max(duration,1) × duration)` — then samples
/// ~4 frames) and a 40-frame 1 fps clip is 40 s (sampled at the 32 cap).
private func makeSolidColorClip(
    colors: [(r: UInt8, g: UInt8, b: UInt8)],
    fps: Int32,
    width: Int = 128,
    height: Int = 128
) async throws -> Data {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("v075-video-fixture-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: url) }

    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
    writer.add(input)
    guard writer.startWriting() else {
        throw VideoFixtureError(
            description: "startWriting failed: \(String(describing: writer.error))")
    }
    writer.startSession(atSourceTime: .zero)

    for (index, color) in colors.enumerated() {
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        var pixelBufferOut: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBufferOut)
        guard status == kCVReturnSuccess, let buffer = pixelBufferOut else {
            throw VideoFixtureError(description: "CVPixelBufferCreate failed (\(status))")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            CVPixelBufferUnlockBaseAddress(buffer, [])
            throw VideoFixtureError(description: "pixel buffer has no base address")
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0 ..< height {
            let rowPtr = base.advanced(by: row * bytesPerRow)
                .assumingMemoryBound(to: UInt8.self)
            for col in 0 ..< width {
                rowPtr[col * 4 + 0] = color.b
                rowPtr[col * 4 + 1] = color.g
                rowPtr[col * 4 + 2] = color.r
                rowPtr[col * 4 + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard
            adaptor.append(
                buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: fps))
        else {
            throw VideoFixtureError(
                description: "append(frame \(index)) failed: \(String(describing: writer.error))")
        }
    }
    input.markAsFinished()
    writer.endSession(
        atSourceTime: CMTime(value: CMTimeValue(colors.count), timescale: fps))
    await writer.finishWriting()
    guard writer.status == .completed else {
        throw VideoFixtureError(
            description: "finishWriting status \(writer.status.rawValue): "
                + String(describing: writer.error))
    }
    return try Data(contentsOf: url)
}

private func dataURI(forMP4 data: Data) -> String {
    "data:video/mp4;base64," + data.base64EncodedString()
}

/// Thread-safe recorder for the vision plumbing's refusal ERRORs.
private final class VideoLiveRefusalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [TelemetryEvent] = []
    var events: [TelemetryEvent] { lock.withLock { _events } }
    func append(_ event: TelemetryEvent) { lock.withLock { _events.append(event) } }
}

@Suite("Gemma 4 VLM video through engine_v2 (live)", .serialized)
struct GemmaVLMVideoEngineV2LiveTests {

    /// The production qat checkpoint (coordinator catalog id
    /// `gemma-4-26b-qat-4bit`) — the sole gemma build going forward.
    static let qat4bitModelID = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"

    // MARK: - Harness (mirrors GemmaVLMVisionEngineV2LiveTests' slot shape)

    /// One loaded v2 VLM slot: the PRODUCTION bridge, the retained VLM
    /// container the vision tower runs in, and the tokenizer for the
    /// registry entry.
    private struct LoadedV2VLMSlot {
        let modelID: String
        let bridge: EngineV2Bridge
        let container: ModelContainer
        let tokenizer: TokenizerHandle
    }

    /// Structured slot lifecycle: load through the shared fixture (the
    /// exact production construction) and AWAIT `bridge.shutdown()` + pool
    /// trim on every exit path.
    private func withV2VLMSlot(
        modelID: String, budgetBytes: Int,
        _ body: (LoadedV2VLMSlot) async throws -> Void
    ) async throws {
        let loaded = try await LiveInferenceFixtures.loadBridge(
            modelID: modelID,
            maxConcurrentRequests: 4,
            memoryBudgetBytes: budgetBytes,
            defaultMaxTokens: 256)
        let tokenizer: TokenizerHandle = await loaded.container.perform { ctx in
            TokenizerHandle(ctx.tokenizer)
        }
        let slot = LoadedV2VLMSlot(
            modelID: modelID,
            bridge: loaded.bridge,
            container: loaded.container,
            tokenizer: tokenizer)
        do {
            try await body(slot)
        } catch {
            await loaded.bridge.shutdown()
            MLX.Memory.clearCache()
            throw error
        }
        await loaded.bridge.shutdown()
        MLX.Memory.clearCache()
    }

    /// Drive one OpenAI-shaped request through the production routing seam
    /// over the slot's registry entry, join the streamed content, and
    /// report the time to first content chunk.
    private func streamText(
        slot: LoadedV2VLMSlot,
        userContent: OpenAIMessageContent,
        maxTokens: Int,
        visionPlumbing: EngineV2VisionPlumbing? = nil
    ) async throws -> (content: String, ttft: TimeInterval) {
        let modelID = slot.modelID
        let bridge = slot.bridge
        let tokenizer = slot.tokenizer
        let container = slot.container
        let engine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    modelID: .init(
                        tokenizer: tokenizer,
                        modelType: "gemma4",
                        container: container,
                        isVLM: true,
                        engineV2Bridge: bridge)
                ]
            },
            defaultMaxTokens: 256,
            engineV2Vision: visionPlumbing
        )
        let request = OpenAIChatCompletionRequest(
            model: slot.modelID,
            messages: [OpenAIChatMessage(role: .user, content: userContent)],
            temperature: 0,
            maxTokens: maxTokens
        )
        let startedAt = Date()
        var firstContentAt: Date?
        var content = ""
        for try await event in try await engine.streamChatCompletion(request: request) {
            if case .content(let text) = event {
                if firstContentAt == nil { firstContentAt = Date() }
                content += text
            }
        }
        let ttft = (firstContentAt ?? Date()).timeIntervalSince(startedAt)
        return (content, ttft)
    }

    /// Stream a media request through v2 and REQUIRE it took the v2 path:
    /// zero refusal ERRORs and a bridge admit for this request.
    private func streamMediaThroughV2(
        slot: LoadedV2VLMSlot,
        userContent: OpenAIMessageContent,
        maxTokens: Int,
        stage: String
    ) async throws -> (content: String, ttft: TimeInterval) {
        let recorder = VideoLiveRefusalRecorder()
        let plumbing = EngineV2VisionPlumbing(
            prepare: { container, request, reasoningEffort, enableThinkingOverride in
                try await EngineV2VisionPrefill.prepare(
                    container: container, request: request, reasoningEffort: reasoningEffort, enableThinkingOverride: enableThinkingOverride)
            },
            emitTelemetry: { recorder.append($0) }
        )
        let admitsBefore = await slot.bridge._testCounters().admits
        let result = try await streamText(
            slot: slot, userContent: userContent,
            maxTokens: maxTokens, visionPlumbing: plumbing)
        let admitsAfter = await slot.bridge._testCounters().admits
        #expect(
            recorder.events.isEmpty,
            Comment(
                rawValue: "[\(stage)] media request was refused: "
                    + "\(recorder.events.map(\.message))"))
        #expect(
            admitsAfter == admitsBefore + 1,
            Comment(
                rawValue: "[\(stage)] bridge admits \(admitsBefore) → \(admitsAfter); "
                    + "the media request did not reach the v2 engine"))
        return result
    }

    /// `EngineV2VisionPrefill.prepare` for one request, for construction
    /// introspection (span/embedding counts, lengths, media kind).
    private func prepareSubmission(
        slot: LoadedV2VLMSlot, userContent: OpenAIMessageContent
    ) async throws -> EngineV2VisionPrefill.PreparedSubmission {
        try await EngineV2VisionPrefill.prepare(
            container: slot.container,
            request: OpenAIChatCompletionRequest(
                model: slot.modelID,
                messages: [OpenAIChatMessage(role: .user, content: userContent)],
                temperature: 0,
                maxTokens: 16
            ))
    }

    // MARK: - (a)+(b): construction, v2 serve, determinism, steering, TTFT

    @Test(
        "qat-4bit: video through v2 — construction, steering, determinism, TTFT",
        .enabled(if: LiveInferenceFixtures.gemmaTestsEnabled)
    )
    func qat4bitVideoThroughV2() async throws {
        // 4 distinct frames at 32 fps → 0.125 s → the Gemma4 sampler takes
        // ~4 frames (round(32 × 0.125)); all-red / all-blue variants for
        // steering.
        let rainbowClip = try await makeSolidColorClip(
            colors: [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 255)], fps: 32)
        let redClip = try await makeSolidColorClip(
            colors: Array(repeating: (255, 0, 0), count: 4), fps: 32)
        let blueClip = try await makeSolidColorClip(
            colors: Array(repeating: (0, 0, 255), count: 4), fps: 32)
        print(
            "[gemma-vlm-video-v2] fixtures: rainbow=\(rainbowClip.count)B "
                + "red=\(redClip.count)B blue=\(blueClip.count)B")

        try await withV2VLMSlot(
            modelID: Self.qat4bitModelID, budgetBytes: 48 * 1024 * 1024 * 1024
        ) { slot in
            // (a) CONSTRUCTION INTROSPECTION — video-only.
            let videoPrepared = try await prepareSubmission(
                slot: slot,
                userContent: .parts([
                    .text("Describe this video."), .videoURL(dataURI(forMP4: rainbowClip)),
                ]))
            #expect(videoPrepared.mediaKind == .video)
            #expect(videoPrepared.spans.count == videoPrepared.embeddings.count)
            #expect(
                (1 ... 32).contains(videoPrepared.spans.count),
                "sampled frame count out of range: \(videoPrepared.spans.count)")
            let frameLengths = Set(videoPrepared.spans.map(\.length))
            #expect(
                frameLengths.count == 1,
                "per-frame soft-token counts must be uniform within one video: \(frameLengths)")
            let frameTokens = frameLengths.first ?? 0
            #expect(
                frameTokens > 0 && frameTokens < 280,
                "video frames use the smaller video patch budget (got \(frameTokens))")
            // Spans strictly ascending + non-overlapping (engine validation
            // would reject otherwise; assert here for a readable failure).
            for (a, b) in zip(videoPrepared.spans, videoPrepared.spans.dropFirst()) {
                #expect(a.tokenOffset + a.length <= b.tokenOffset)
            }
            print(
                "[gemma-vlm-video-v2] construction: \(videoPrepared.spans.count) frame spans × "
                    + "\(frameTokens) soft tokens, prompt \(videoPrepared.promptTokens.count) tokens")

            // (a) CONSTRUCTION INTROSPECTION — mixed image+video interleave.
            let mixedPrepared = try await prepareSubmission(
                slot: slot,
                userContent: .parts([
                    .text("Compare the image and the video."),
                    .imageURL(videoSuiteRedPNGDataURI),
                    .videoURL(dataURI(forMP4: blueClip)),
                ]))
            #expect(mixedPrepared.mediaKind == .mixed)
            #expect(mixedPrepared.spans.count == mixedPrepared.embeddings.count)
            // Exactly one 280-token image span (Gemma4 imageSeqLength) and
            // ≥1 small video-frame spans; Gemma4MessageGenerator orders
            // images before videos within a message, so the image span
            // comes first.
            let imageSpans = mixedPrepared.spans.filter { $0.length >= 280 }
            let videoSpans = mixedPrepared.spans.filter { $0.length < 280 }
            #expect(imageSpans.count == 1, "expected one image span, got \(imageSpans.count)")
            #expect(!videoSpans.isEmpty)
            #expect(
                imageSpans[0].tokenOffset < (videoSpans.first?.tokenOffset ?? .max),
                "image span must precede video frame spans (prompt order)")
            print(
                "[gemma-vlm-video-v2] mixed construction: image span \(imageSpans[0].length) "
                    + "tokens + \(videoSpans.count) frame spans")

            let colorPrompt =
                "What is the dominant color in this video? Answer with one word."

            // (b) VIDEO THROUGH V2 + TTFT.
            let (redContent, redTTFT) = try await streamMediaThroughV2(
                slot: slot,
                userContent: .parts([
                    .text(colorPrompt), .videoURL(dataURI(forMP4: redClip)),
                ]),
                maxTokens: 16, stage: "red")
            #expect(!redContent.isEmpty, "v2 video request produced no content")
            print(
                "[gemma-vlm-video-v2] red: v2=\(redContent.debugDescription) "
                    + String(format: "ttft=%.2fs", redTTFT))

            // Greedy determinism: identical input ⇒ identical output.
            let (redAgain, redAgainTTFT) = try await streamMediaThroughV2(
                slot: slot,
                userContent: .parts([
                    .text(colorPrompt), .videoURL(dataURI(forMP4: redClip)),
                ]),
                maxTokens: 16, stage: "red2")
            #expect(
                redAgain == redContent,
                Comment(
                    rawValue: "v2 video greedy decode is non-deterministic: "
                        + "\(redContent.debugDescription) vs \(redAgain.debugDescription)"))
            print(
                "[gemma-vlm-video-v2] red2: "
                    + String(format: "ttft=%.2fs (warm tower/weights)", redAgainTTFT))

            // Embedding steering: different pixels, same prompt ⇒ the
            // completions must differ (if spans/embeddings were dropped
            // both would collapse to the same text-only answer).
            let (blueContent, _) = try await streamMediaThroughV2(
                slot: slot,
                userContent: .parts([
                    .text(colorPrompt), .videoURL(dataURI(forMP4: blueClip)),
                ]),
                maxTokens: 16, stage: "blue")
            #expect(!blueContent.isEmpty, "v2 video request (blue) produced no content")
            #expect(
                blueContent != redContent,
                Comment(
                    rawValue: "red and blue clips produced IDENTICAL v2 completions "
                        + "(\(redContent.debugDescription)) — video embeddings are not "
                        + "reaching the model"))

            // Mixed image+video serves end-to-end through v2 too.
            let (mixedContent, mixedTTFT) = try await streamMediaThroughV2(
                slot: slot,
                userContent: .parts([
                    .text(
                        "Is the image the same color as the video? Answer yes or no."),
                    .imageURL(videoSuiteRedPNGDataURI),
                    .videoURL(dataURI(forMP4: blueClip)),
                ]),
                maxTokens: 16, stage: "mixed")
            #expect(!mixedContent.isEmpty, "v2 mixed request produced no content")
            print(
                "[gemma-vlm-video-v2] mixed: v2=\(mixedContent.debugDescription) "
                    + String(format: "ttft=%.2fs", mixedTTFT))

            // Interleave hygiene: a video request must leave no residue
            // in the engine's caches for subsequent text decodes.
            let (textA, _) = try await streamText(
                slot: slot,
                userContent: .text("Count from one to five as digits separated by commas."),
                maxTokens: 32)
            _ = try await streamMediaThroughV2(
                slot: slot,
                userContent: .parts([
                    .text(colorPrompt), .videoURL(dataURI(forMP4: redClip)),
                ]),
                maxTokens: 16, stage: "interleave")
            let (textB, _) = try await streamText(
                slot: slot,
                userContent: .text("Count from one to five as digits separated by commas."),
                maxTokens: 32)
            #expect(
                textA == textB,
                Comment(
                    rawValue: "v2 text decode changed after an interleaved v2 video "
                        + "request: before=\(textA.debugDescription) "
                        + "after=\(textB.debugDescription)"))
        }
    }

    // MARK: - (c): 32-frame sampling cap

    @Test(
        "qat-4bit: 40s clip samples at the 32-frame cap and serves through v2",
        .enabled(if: LiveInferenceFixtures.gemmaTestsEnabled)
    )
    func qat4bitVideo32FrameCap() async throws {
        // 40 frames at 1 fps → 40 s: naive per-frame expansion would be 40
        // blocks; the processor samples uniformly and caps at 32. Alternate
        // colors so sampled frames stay distinct.
        var colors: [(r: UInt8, g: UInt8, b: UInt8)] = []
        for index in 0 ..< 40 {
            colors.append(index % 2 == 0 ? (255, 0, 0) : (0, 255, 0))
        }
        let longClip = try await makeSolidColorClip(colors: colors, fps: 1)
        print("[gemma-vlm-video-v2] 40s fixture: \(longClip.count)B")

        try await withV2VLMSlot(
            modelID: Self.qat4bitModelID, budgetBytes: 48 * 1024 * 1024 * 1024
        ) { slot in
            let prepared = try await prepareSubmission(
                slot: slot,
                userContent: .parts([
                    .text("How many colors appear? Answer with one word."),
                    .videoURL(dataURI(forMP4: longClip)),
                ]))
            #expect(prepared.mediaKind == .video)
            #expect(prepared.spans.count == prepared.embeddings.count)
            #expect(
                prepared.spans.count <= 32,
                "sampling must cap at 32 frames, got \(prepared.spans.count)")
            #expect(
                prepared.spans.count >= 30,
                "a 40s clip should sample ~32 frames, got \(prepared.spans.count)")
            print(
                "[gemma-vlm-video-v2] cap construction: \(prepared.spans.count) frame spans, "
                    + "prompt \(prepared.promptTokens.count) tokens")

            let (content, ttft) = try await streamMediaThroughV2(
                slot: slot,
                userContent: .parts([
                    .text("How many colors appear? Answer with one word."),
                    .videoURL(dataURI(forMP4: longClip)),
                ]),
                maxTokens: 16, stage: "cap")
            #expect(!content.isEmpty, "32-frame v2 video request produced no content")
            print(
                "[gemma-vlm-video-v2] cap: v2=\(content.debugDescription) "
                    + String(format: "ttft=%.2fs", ttft))
        }
    }
}
