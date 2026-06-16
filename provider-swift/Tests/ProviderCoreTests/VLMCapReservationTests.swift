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
