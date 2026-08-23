// Copyright © 2026 Eigen Labs.

import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore
// MARK: - Span carving

@Suite("EngineV2VisionPrefill span carving")
struct EngineV2VisionSpanCarvingTests {
    let p = 990  // image placeholder id
    let v = 991  // video placeholder id

    /// Image-only convenience over the generalized two-kind carve.
    private func carveImages(tokens: [Int], spanLengths: [Int]) throws -> [CBv2ImageSpan] {
        try EngineV2VisionPrefill.carveSpans(
            tokens: tokens, imagePlaceholderId: p, imageSpanLengths: spanLengths,
            videoPlaceholderId: nil, videoSpanLengths: []
        ).map(\.span)
    }

    @Test("single image mid-prompt")
    func singleImage() throws {
        let tokens = [1, 5, 6, p, p, p, p, 9]
        let spans = try carveImages(tokens: tokens, spanLengths: [4])
        #expect(spans == [CBv2ImageSpan(tokenOffset: 3, length: 4)])
    }

    @Test("two images separated by text/delimiters")
    func twoImages() throws {
        let tokens = [1, p, p, 42, 43, p, p, 9]
        let spans = try carveImages(tokens: tokens, spanLengths: [2, 2])
        #expect(spans == [
            CBv2ImageSpan(tokenOffset: 1, length: 2),
            CBv2ImageSpan(tokenOffset: 5, length: 2),
        ])
    }

    @Test("adjacent images carve one run into back-to-back spans")
    func adjacentImages() throws {
        // One contiguous 5-token run = a 2-token image + a 3-token image;
        // the engine coalesces the two spans back into one bidirectional
        // block (the wrapper's contiguous-run semantics).
        let tokens = [1, p, p, p, p, p, 9]
        let spans = try carveImages(tokens: tokens, spanLengths: [2, 3])
        #expect(spans == [
            CBv2ImageSpan(tokenOffset: 1, length: 2),
            CBv2ImageSpan(tokenOffset: 3, length: 3),
        ])
    }

    @Test("image at prompt start")
    func imageAtStart() throws {
        let tokens = [p, p, p, 4, 5]
        let spans = try carveImages(tokens: tokens, spanLengths: [3])
        #expect(spans == [CBv2ImageSpan(tokenOffset: 0, length: 3)])
    }

    @Test("missing placeholder run throws")
    func missingRun() {
        #expect(throws: EngineV2VisionPrefillError.self) {
            try carveImages(tokens: [1, 2, 3], spanLengths: [2])
        }
    }

    @Test("run shorter than the image's soft-token count throws")
    func runTooShort() {
        #expect(throws: EngineV2VisionPrefillError.self) {
            try carveImages(tokens: [1, p, p, 4], spanLengths: [3])
        }
    }

    @Test("leftover placeholders after pairing throw")
    func trailingPlaceholders() {
        #expect(throws: EngineV2VisionPrefillError.self) {
            try carveImages(tokens: [1, p, p, 4, p, 9], spanLengths: [2])
        }
    }

    @Test("non-positive feature length throws")
    func invalidLength() {
        #expect(throws: EngineV2VisionPrefillError.self) {
            try carveImages(tokens: [p], spanLengths: [0])
        }
    }

    // MARK: video + mixed (v0.7.5)

    @Test("video-only: one span per frame block, timestamps/text between")
    func videoOnlyPerFrame() throws {
        // Two frame blocks (3 soft tokens each), separated by the timestamp
        // text tokens the processor emits between per-frame blocks — the
        // engine never coalesces across frames because of them.
        let tokens = [1, 60, v, v, v, 61, 60, v, v, v, 61, 9]
        let carved = try EngineV2VisionPrefill.carveSpans(
            tokens: tokens, imagePlaceholderId: nil, imageSpanLengths: [],
            videoPlaceholderId: v, videoSpanLengths: [3, 3])
        #expect(carved == [
            EngineV2VisionPrefill.CarvedSpan(
                kind: .video, span: CBv2ImageSpan(tokenOffset: 2, length: 3)),
            EngineV2VisionPrefill.CarvedSpan(
                kind: .video, span: CBv2ImageSpan(tokenOffset: 7, length: 3)),
        ])
    }

    @Test("mixed image+video preserves prompt-order interleave")
    func mixedInterleave() throws {
        // image, frame, frame, image — spans must come out ascending with
        // per-kind features consumed in prompt order.
        let tokens = [1, p, p, 5, v, v, v, 6, v, v, v, 7, p, p, p, 9]
        let carved = try EngineV2VisionPrefill.carveSpans(
            tokens: tokens, imagePlaceholderId: p, imageSpanLengths: [2, 3],
            videoPlaceholderId: v, videoSpanLengths: [3, 3])
        #expect(carved == [
            EngineV2VisionPrefill.CarvedSpan(
                kind: .image, span: CBv2ImageSpan(tokenOffset: 1, length: 2)),
            EngineV2VisionPrefill.CarvedSpan(
                kind: .video, span: CBv2ImageSpan(tokenOffset: 4, length: 3)),
            EngineV2VisionPrefill.CarvedSpan(
                kind: .video, span: CBv2ImageSpan(tokenOffset: 8, length: 3)),
            EngineV2VisionPrefill.CarvedSpan(
                kind: .image, span: CBv2ImageSpan(tokenOffset: 12, length: 3)),
        ])
    }

    @Test("cross-kind adjacency: image run directly followed by a frame run")
    func crossKindAdjacency() throws {
        let tokens = [p, p, v, v, v, 9]
        let carved = try EngineV2VisionPrefill.carveSpans(
            tokens: tokens, imagePlaceholderId: p, imageSpanLengths: [2],
            videoPlaceholderId: v, videoSpanLengths: [3])
        #expect(carved == [
            EngineV2VisionPrefill.CarvedSpan(
                kind: .image, span: CBv2ImageSpan(tokenOffset: 0, length: 2)),
            EngineV2VisionPrefill.CarvedSpan(
                kind: .video, span: CBv2ImageSpan(tokenOffset: 2, length: 3)),
        ])
    }

    @Test("fewer video runs than frames throws (frame-count assertion)")
    func fewerRunsThanFrames() {
        // Tower returned 2 frames, prompt has only 1 frame block.
        do {
            _ = try EngineV2VisionPrefill.carveSpans(
                tokens: [1, v, v, v, 9], imagePlaceholderId: nil, imageSpanLengths: [],
                videoPlaceholderId: v, videoSpanLengths: [3, 3])
            Issue.record("expected placeholderRunMissing throw")
        } catch let error as EngineV2VisionPrefillError {
            guard case .placeholderRunMissing(let kind, let index) = error else {
                Issue.record("expected .placeholderRunMissing, got \(error)")
                return
            }
            #expect(kind == .video)
            #expect(index == 1)
        } catch {
            Issue.record("expected EngineV2VisionPrefillError, got \(error)")
        }
    }

    @Test("more video runs than frames throws (frame-count assertion)")
    func moreRunsThanFrames() {
        // Tower returned 1 frame, prompt has 2 frame blocks.
        do {
            _ = try EngineV2VisionPrefill.carveSpans(
                tokens: [1, v, v, v, 5, v, v, v, 9], imagePlaceholderId: nil,
                imageSpanLengths: [],
                videoPlaceholderId: v, videoSpanLengths: [3])
            Issue.record("expected unexpectedTrailingPlaceholders throw")
        } catch let error as EngineV2VisionPrefillError {
            guard case .unexpectedTrailingPlaceholders(let kind, let count) = error else {
                Issue.record("expected .unexpectedTrailingPlaceholders, got \(error)")
                return
            }
            #expect(kind == .video)
            #expect(count == 3)
        } catch {
            Issue.record("expected EngineV2VisionPrefillError, got \(error)")
        }
    }

    @Test("video frame run shorter than its soft-token count throws")
    func videoRunTooShort() {
        #expect(throws: EngineV2VisionPrefillError.self) {
            _ = try EngineV2VisionPrefill.carveSpans(
                tokens: [1, v, v, 5], imagePlaceholderId: nil, imageSpanLengths: [],
                videoPlaceholderId: v, videoSpanLengths: [3])
        }
    }

    @Test("image and video sharing one placeholder id throws")
    func conflictingIds() {
        #expect(throws: EngineV2VisionPrefillError.self) {
            _ = try EngineV2VisionPrefill.carveSpans(
                tokens: [p, p], imagePlaceholderId: p, imageSpanLengths: [2],
                videoPlaceholderId: p, videoSpanLengths: [2])
        }
    }

    @Test("a disabled kind's id is an ordinary token (mirrors the processor)")
    func disabledKindIgnored() throws {
        // No video features ⇒ the video id is not watched: a stray 991 in
        // the prompt stays an ordinary token, exactly as the wrapper would
        // embed it (the processor only expands placeholders it produced
        // pixels for).
        let tokens = [1, p, p, 4, v, 9]
        let carved = try EngineV2VisionPrefill.carveSpans(
            tokens: tokens, imagePlaceholderId: p, imageSpanLengths: [2],
            videoPlaceholderId: nil, videoSpanLengths: [])
        #expect(carved.map(\.span) == [CBv2ImageSpan(tokenOffset: 1, length: 2)])
    }
}
