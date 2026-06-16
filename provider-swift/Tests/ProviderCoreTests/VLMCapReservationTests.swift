import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

private let gib: UInt64 = 1024 * 1024 * 1024

// MARK: - projectedDecodeBytes (VLM media-decode RAM estimate for cap reservation)

@Test func projectedDecodeBytesIsZeroForTextOnlyRequest() {
    let req = OpenAIChatCompletionRequest(
        model: "m", messages: [.init(role: .user, content: .text("hello, no media"))])
    #expect(VLMRequestInference.projectedDecodeBytes(req) == 0)
}

@Test func projectedDecodeBytesScalesWithDeclaredPixels() {
    // A 1000x1000 PNG = 1,000,000 px. Projected = px * 4 (RGBA) * overhead(4) = 16 MB.
    let uri = PNGBomb.dataURI(width: 1000, height: 1000)
    let req = OpenAIChatCompletionRequest(
        model: "m", messages: [.init(role: .user, content: .parts([.imageURL(uri)]))])
    let expected = UInt64(1000 * 1000) * 4 * UInt64(VLMRequestInference.decodeOverheadFactor)
    #expect(VLMRequestInference.projectedDecodeBytes(req) == expected)
}

@Test func projectedDecodeBytesSumsAcrossImages() {
    // Two images aggregate. 800x600 = 480k px each; two -> 960k px.
    let uri = PNGBomb.dataURI(width: 800, height: 600)
    let req = OpenAIChatCompletionRequest(
        model: "m",
        messages: [.init(role: .user, content: .parts([
            .text("describe both"), .imageURL(uri), .imageURL(uri)]))])
    let perImage = UInt64(800 * 600)
    let expected = perImage * 2 * 4 * UInt64(VLMRequestInference.decodeOverheadFactor)
    #expect(VLMRequestInference.projectedDecodeBytes(req) == expected)
}

@Test func projectedDecodeBytesUsesPerImageCapWhenHeaderUnreadable() {
    // A non-PNG/garbage data: payload has no readable header -> charge the
    // per-image cap (worst case the media caps still admit), not 0.
    let uri = "data:image/png;base64,QUJD"  // "ABC" — not a valid PNG
    let req = OpenAIChatCompletionRequest(
        model: "m", messages: [.init(role: .user, content: .parts([.imageURL(uri)]))])
    let capPixels = UInt64(VLMRequestInference.maxImagePixels)
    let expected = capPixels * 4 * UInt64(VLMRequestInference.decodeOverheadFactor)
    #expect(VLMRequestInference.projectedDecodeBytes(req) == expected)
}

@Test func projectedDecodeBytesClampsImageSumToAggregateCap() {
    // Many unreadable-header images each charge the per-image cap; without the
    // aggregate clamp the sum would blow past the request-wide image ceiling
    // validateMedia enforces. The projection must clamp to maxRequestImagePixels.
    let uri = "data:image/png;base64,QUJD"  // unreadable -> per-image cap each
    let perImageCap = VLMRequestInference.maxImagePixels
    let aggCap = VLMRequestInference.maxRequestImagePixels
    // Enough images that the raw sum exceeds the aggregate cap.
    let count = (aggCap / perImageCap) + 3
    let parts: [OpenAIContentPart] = (0..<count).map { _ in .imageURL(uri) }
    let req = OpenAIChatCompletionRequest(
        model: "m", messages: [.init(role: .user, content: .parts(parts))])
    let expected = UInt64(aggCap) * 4 * UInt64(VLMRequestInference.decodeOverheadFactor)
    #expect(VLMRequestInference.projectedDecodeBytes(req) == expected)
}

@Test func projectedDecodeBytesChargesVideoAggregateOncePerRequest() {
    // validateMedia caps the SUM of all videos' frame pixels by
    // maxRequestVideoFramePixels — so the projection charges that aggregate ONCE
    // regardless of video count. Charging per-video would over-reserve by the
    // video count and could falsely 503 a valid multi-video request. (The URI is
    // never decoded by projectedDecodeBytes; only the part kind matters.)
    let videoURI = "data:video/mp4;base64,AAAAAA"
    func projForVideos(_ n: Int) -> UInt64 {
        let parts: [OpenAIContentPart] = (0..<n).map { _ in .videoURL(videoURI) }
        let req = OpenAIChatCompletionRequest(
            model: "m", messages: [.init(role: .user, content: .parts(parts))])
        return VLMRequestInference.projectedDecodeBytes(req)
    }
    let expectedAggregate =
        UInt64(VLMRequestInference.maxRequestVideoFramePixels) * 4
        * UInt64(VLMRequestInference.decodeOverheadFactor)
    #expect(projForVideos(1) == expectedAggregate)
    #expect(projForVideos(3) == expectedAggregate)  // NOT 3x — aggregate, charged once
    #expect(projForVideos(8) == expectedAggregate)
}

// MARK: - GlobalKVCacheBudget.reserveBytes (the cap reservation primitive)

@Test func reserveBytesAdmitsWhatFitsAndRejectsOverCap() async {
    // 64 GiB box, cap 0.9*64 = 57.6, no activation reserve, nothing held -> ~57.6
    // GiB reservable. A 4 GiB media decode fits; a further 60 GiB does not.
    let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
        GlobalKVCacheBudget.MemorySnapshot(total: 64 * gib, active: 0, cache: 0, systemAvailable: .max)
    }
    #expect(await budget.reserveBytes(requestID: "media-a", bytes: 4 * gib))
    #expect(!(await budget.reserveBytes(requestID: "media-b", bytes: 60 * gib)))
    // Releasing the first frees its headroom so a later decode can proceed.
    await budget.release(requestID: "media-a")
    #expect(await budget.reserveBytes(requestID: "media-c", bytes: 50 * gib))
}

@Test func reserveBytesCountsAgainstResidentKVAndWeights() async {
    // MLX already holds 55 GiB (weights+KV) of a 64 GiB box, cap 57.6 -> only
    // ~2.6 GiB reservable. A 4 GiB media decode must be rejected (it would push
    // past the cap toward jetsam); a 2 GiB one fits.
    let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
        GlobalKVCacheBudget.MemorySnapshot(total: 64 * gib, active: 55 * gib, cache: 0, systemAvailable: .max)
    }
    #expect(!(await budget.reserveBytes(requestID: "big", bytes: 4 * gib)))
    #expect(await budget.reserveBytes(requestID: "ok", bytes: 2 * gib))
}

@Test func reserveBytesRejectsZeroAndDuplicate() async {
    let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
        GlobalKVCacheBudget.MemorySnapshot(total: 64 * gib, active: 0, cache: 0, systemAvailable: .max)
    }
    #expect(!(await budget.reserveBytes(requestID: "z", bytes: 0)))
    #expect(await budget.reserveBytes(requestID: "dup", bytes: gib))
    #expect(!(await budget.reserveBytes(requestID: "dup", bytes: gib)))  // already reserved
}

// MARK: - Vision-path output-token resolution (sizes the generation-KV reservation)

@Test func resolveMaxOutputTokensPrefersRequestThenDefault() {
    // Consumer-set max_tokens wins.
    let withMax = OpenAIChatCompletionRequest(
        model: "m", messages: [.init(role: .user, content: .text("hi"))], maxTokens: 321)
    #expect(VLMRequestInference.resolveMaxOutputTokens(for: withMax, defaultMaxTokens: 1024) == 321)
    // Omitted max_tokens falls back to the model default — the SAME value the
    // generator uses, so the KV reservation matches actual generation.
    let noMax = OpenAIChatCompletionRequest(
        model: "m", messages: [.init(role: .user, content: .text("hi"))])
    #expect(VLMRequestInference.resolveMaxOutputTokens(for: noMax, defaultMaxTokens: 1024) == 1024)
}

// MARK: - projectedKVTokens (full KV span: prompt + vision + output)

@Test func projectedKVTokensIncludesVisionAndOutputNotJustOutput() {
    // One image + a short prompt + 100 output tokens. The KV span must include
    // the per-image vision soft tokens — NOT just the output (which would badly
    // under-reserve, the bug Codex flagged).
    let uri = PNGBomb.dataURI(width: 64, height: 64)
    let req = OpenAIChatCompletionRequest(
        model: "m",
        messages: [.init(role: .user, content: .parts([.text("hi"), .imageURL(uri)]))],
        maxTokens: 100)
    let tokens = VLMRequestInference.projectedKVTokens(
        req, defaultMaxTokens: 1024, contextLength: 0)
    // >= vision tokens for the image + the 100 output tokens.
    #expect(tokens >= VLMRequestInference.visionTokensPerImage + 100)
    // And strictly greater than output-only (the old, buggy sizing).
    #expect(tokens > 100)
}

@Test func projectedKVTokensClampsPromptPlusVisionToContext() {
    // Many images would project a huge prompt+vision span; it must clamp to the
    // model's context window (the cache can't hold more input tokens than that),
    // then add output on top — mirroring the batched path's promptTokens+maxTokens.
    let uri = PNGBomb.dataURI(width: 64, height: 64)
    let parts: [OpenAIContentPart] = (0..<64).map { _ in .imageURL(uri) }
    let req = OpenAIChatCompletionRequest(
        model: "m", messages: [.init(role: .user, content: .parts(parts))], maxTokens: 50)
    let ctx = 4096
    let tokens = VLMRequestInference.projectedKVTokens(
        req, defaultMaxTokens: 1024, contextLength: ctx)
    // 64 × 1024 vision tokens = 65536 >> 4096 ctx → clamped to ctx, + 50 output.
    #expect(tokens == ctx + 50)
}

@Test func projectedKVTokensTextOnlyHasNoVisionCharge() {
    // A text-only request (no media) charges only the text estimate + output —
    // no spurious vision tokens.
    let req = OpenAIChatCompletionRequest(
        model: "m", messages: [.init(role: .user, content: .text("hello there"))],
        maxTokens: 10)
    let tokens = VLMRequestInference.projectedKVTokens(
        req, defaultMaxTokens: 1024, contextLength: 0)
    // "hello there" = 11 utf8 bytes / 3 = 3 text tokens, + 10 output = 13.
    #expect(tokens == 11 / VLMRequestInference.textCharsPerToken + 10)
    #expect(tokens < VLMRequestInference.visionTokensPerImage)  // no vision charge
}
