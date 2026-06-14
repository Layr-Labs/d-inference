import CoreImage
import Foundation
import ImageIO
import MLXLMCommon
import MLXLMServer
import Testing
import UniformTypeIdentifiers

@testable import ProviderCore

// Unit tests for the non-batched VLM (image/video) inference path. These
// cover the pure decode + routing helpers — data: URI parsing, image
// decode, media detection, and UserInput construction — without loading
// a model or touching the network. Live generation through a real VLM
// container is covered by the smoke harness / live suites.

// A real, round-trip-verified 1x1 PNG (red pixel), base64 with no
// whitespace. Decodes cleanly through CIImage(data:).
private let tinyPNGBase64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAAAXNSR0IArs4c6QAAAERl"
    + "WElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAAB"
    + "AAAAAaADAAQAAAABAAAAAQAAAAD5Ip3+AAAADElEQVQIHWP4z8AAAAMBAQBb2/lEAAAA"
    + "AElFTkSuQmCC"

private let tinyPNGDataURI = "data:image/png;base64,\(tinyPNGBase64)"

// A real, round-trip-verified 64x64 H.264 mp4 (3 solid-gray frames, ~955
// bytes), base64 with no whitespace. naturalSize = 64x64 = 4096 px, so it is
// rejected by a per-frame cap < 4096 and accepted by one >= 4096. Generated via
// AVAssetWriter. Used by the video frame-cap tests.
private let tinyMP4Base64 =
    "AAAAHGZ0eXBtcDQyAAAAAWlzb21tcDQxbXA0MgAAAAFtZGF0AAAAAAAAAK4AAAA7BgUyR1ZK3FxMQz+U78URPNFDqAEAAAMAAQMAAAMAAQIAAeYACwAAAwAA"
    + "AwAAAwAUDAOJJAEN/////4AAAAAxJbggH4AuSqwRNmYXSACJwyG5akafRwrPDoFqVCtjHBP+QvRWhyAAGk1PzfAEsEedgAAAABEh4QhfAoAvQrFXFN4ACQ7CtgA"
    + "AABEBqIGK/1jQw/VufW+ACvdnuAAAAvFtb292AAAAbG12aGQAAAAA5lOws+ZTsLMAAAJYAAACWAABAAABAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAA"
    + "AAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAACfXRyYWsAAABcdGtoZAAAAAHmU7Cz5lOwswAAAAEAAAAAAAACWAAAAAAAAAAA"
    + "AAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAQAAAAEAAAAAAACRlZHRzAAAAHGVsc3QAAAAAAAAAAQAAAlgAAADIAAEAAAAAAfV"
    + "tZGlhAAAAIG1kaGQAAAAA5lOws+ZTsLMAAAJYAAACWFXEAAAAAAAxaGRscgAAAAAAAAAAdmlkZQAAAAAAAAAAAAAAAENvcmUgTWVkaWEgVmlkZW8AAAABnG1pbm"
    + "YAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAVxzdGJsAAAAoXN0c2QAAAAAAAAAAQAAAJFhdmMxAAAAAA"
    + "AAAAEAAAAAAAAAAAAAAAAAAAAAAEAAQABIAAAASAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGP//AAAAJ2F2Y0MBZAAL/+EADCdkAA"
    + "usVlDDeBBhFAEABCjuPLD9+PgAAAAACmZpZWwBAAAAAApjaHJtAAAAAAAYc3R0cwAAAAAAAAABAAAAAwAAAMgAAAAoY3R0cwAAAAAAAAADAAAAAQAAAMgAAAABAA"
    + "ABkAAAAAEAAAAAAAAAFHN0c3MAAAAAAAAAAQAAAAEAAAAPc2R0cAAAAAAgEBgAAAAcc3RzYwAAAAAAAAABAAAAAQAAAAMAAAABAAAAIHN0c3oAAAAAAAAAAAAAAA"
    + "MAAAB0AAAAFQAAABUAAAAUc3RjbwAAAAAAAAABAAAALA=="

private let tinyMP4DataURI = "data:video/mp4;base64,\(tinyMP4Base64)"

// MARK: - Test helpers

/// Run a throwing media-decode body and assert it threw
/// `MediaError.invalidURL(expectedURI)`. `MediaError` is not `Equatable`, so
/// we pattern-match the case and compare its associated URI rather than using
/// the value form of `#expect(throws:)`.
private func expectInvalidURL(
    _ expectedURI: String,
    _ body: () throws -> Void
) {
    do {
        try body()
        Issue.record(
            "expected MediaError.invalidURL(\(expectedURI)) but no error was thrown")
    } catch let error as VLMRequestInference.MediaError {
        guard case .invalidURL(let uri) = error else {
            Issue.record("expected .invalidURL, got \(error)")
            return
        }
        #expect(uri == expectedURI)
    } catch {
        Issue.record("expected MediaError.invalidURL, got \(error)")
    }
}

// MARK: - dataFromDataURI

@Test("dataFromDataURI decodes a base64 image payload")
func vlmDataFromDataURIBase64() throws {
    let data = try VLMRequestInference.dataFromDataURI(tinyPNGDataURI)
    // PNG magic number: 89 50 4E 47 0D 0A 1A 0A
    let magic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    #expect(Array(data.prefix(8)) == magic)
}

@Test("dataFromDataURI decodes a percent-encoded (non-base64) payload")
func vlmDataFromDataURIPercentEncoded() throws {
    let uri = "data:text/plain,hello%20world"
    let data = try VLMRequestInference.dataFromDataURI(uri)
    #expect(String(data: data, encoding: .utf8) == "hello world")
}

@Test("dataFromDataURI tolerates whitespace in base64 payload")
func vlmDataFromDataURIStripsWhitespace() throws {
    // Inject newlines/spaces the way some clients line-wrap base64.
    let wrapped = "data:image/png;base64," + tinyPNGBase64.prefix(40) + "\n  "
        + tinyPNGBase64.dropFirst(40)
    let data = try VLMRequestInference.dataFromDataURI(String(wrapped))
    #expect(data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
}

@Test("dataFromDataURI throws on a malformed data: URI (no comma)")
func vlmDataFromDataURIMalformedThrows() {
    #expect(throws: VLMRequestInference.MediaError.self) {
        _ = try VLMRequestInference.dataFromDataURI("data:image/png;base64")
    }
}

@Test("dataFromDataURI throws on undecodable base64")
func vlmDataFromDataURIBadBase64Throws() {
    #expect(throws: VLMRequestInference.MediaError.self) {
        _ = try VLMRequestInference.dataFromDataURI("data:image/png;base64,!!!not base64!!!")
    }
}

// MARK: - decodeImage

@Test("decodeImage decodes a base64 data: URI into a CIImage")
func vlmDecodeImageDataURI() throws {
    let image = try VLMRequestInference.decodeImage(tinyPNGDataURI)
    guard case .ciImage(let ci) = image else {
        Issue.record("expected .ciImage, got \(image)")
        return
    }
    #expect(ci.extent.width == 1)
    #expect(ci.extent.height == 1)
}

// SECURITY (SSRF / local-file-read): the provider is the only thing that can
// enforce media policy on an E2E-encrypted request, so inline media MUST be a
// `data:` URI. A non-`data:` URL (http(s):// or file://) must be rejected with
// `invalidURL` and NEVER turned into a `.url(...)` that `CIImage(contentsOf:)`
// / `AVAsset(url:)` would later fetch. These tests lock that guarantee so it
// can't silently regress.
@Test("decodeImage rejects an http:// URI with invalidURL (no SSRF)")
func vlmDecodeImageHTTPRejected() {
    expectInvalidURL("https://example.com/cat.png") {
        _ = try VLMRequestInference.decodeImage("https://example.com/cat.png")
    }
}

@Test("decodeImage rejects a file:// URI with invalidURL (no local-file read)")
func vlmDecodeImageFileRejected() {
    expectInvalidURL("file:///etc/passwd") {
        _ = try VLMRequestInference.decodeImage("file:///etc/passwd")
    }
}

@Test("decodeImage throws when a data: URI holds non-image bytes")
func vlmDecodeImageGarbageThrows() {
    // Valid base64 but not a decodable image.
    let garbage = "data:image/png;base64," + Data("not an image".utf8).base64EncodedString()
    #expect(throws: VLMRequestInference.MediaError.self) {
        _ = try VLMRequestInference.decodeImage(garbage)
    }
}

// MARK: - decodeVideo

@Test("decodeVideo writes an inline data: URI to a tracked temp file")
func vlmDecodeVideoDataURIWritesTempFile() async throws {
    var tempFiles: [URL] = []
    // A real, probeable 64x64 video passes the limits and is written + tracked.
    let (video, _) = try await VLMRequestInference.decodeVideo(
        tinyMP4DataURI, tempFiles: &tempFiles)
    guard case .url(let url) = video else {
        Issue.record("expected .url, got \(video)")
        return
    }
    #expect(tempFiles == [url])
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(url.pathExtension == "mp4")
    #expect((try Data(contentsOf: url)).count > 0)
    // cleanup (production code removes these when the stream ends)
    try? FileManager.default.removeItem(at: url)
}

@Test("decodeVideo fails closed when video metadata is unprobeable")
func vlmDecodeVideoUnreadableMetadataRejected() async {
    // Bytes that aren't a real video: duration/tracks can't be proven within
    // cap, so it's rejected — the byte cap doesn't bound decoded frames.
    var tempFiles: [URL] = []
    let uri = "data:video/mp4;base64,\(Data("not a real video".utf8).base64EncodedString())"
    await expectMediaTooLarge {
        _ = try await VLMRequestInference.decodeVideo(uri, tempFiles: &tempFiles)
    }
    #expect(tempFiles.isEmpty)  // rejected -> temp file cleaned up, not tracked
}

@Test("decodeVideo rejects an http:// URI with invalidURL (no SSRF)")
func vlmDecodeVideoHTTPRejected() async {
    var tempFiles: [URL] = []
    await expectInvalidURLAsync("https://example.com/clip.mp4") {
        _ = try await VLMRequestInference.decodeVideo(
            "https://example.com/clip.mp4", tempFiles: &tempFiles)
    }
    // A rejected URI must not have spawned a temp file.
    #expect(tempFiles.isEmpty)
}

@Test("decodeVideo rejects a file:// URI with invalidURL (no local-file read)")
func vlmDecodeVideoFileRejected() async {
    var tempFiles: [URL] = []
    await expectInvalidURLAsync("file:///etc/passwd") {
        _ = try await VLMRequestInference.decodeVideo(
            "file:///etc/passwd", tempFiles: &tempFiles)
    }
    #expect(tempFiles.isEmpty)
}

// MARK: - hasMedia

@Test("hasMedia is true when a message carries an image_url part")
func vlmHasMediaImage() {
    let request = OpenAIChatCompletionRequest(
        model: "vlm",
        messages: [
            .init(
                role: .user,
                content: .parts([
                    .text("What is in this image?"),
                    .imageURL(tinyPNGDataURI),
                ]))
        ])
    #expect(VLMRequestInference.hasMedia(request))
}

@Test("hasMedia is true when a message carries a video_url part")
func vlmHasMediaVideo() {
    let request = OpenAIChatCompletionRequest(
        model: "vlm",
        messages: [
            .init(
                role: .user,
                content: .parts([.videoURL("https://example.com/clip.mp4")]))
        ])
    #expect(VLMRequestInference.hasMedia(request))
}

@Test("hasMedia is false for a plain text request")
func vlmHasMediaTextFalse() {
    let request = OpenAIChatCompletionRequest(
        model: "vlm",
        messages: [.init(role: .user, content: .text("hello"))])
    #expect(!VLMRequestInference.hasMedia(request))
}

@Test("hasMedia is false for parts that are text-only")
func vlmHasMediaTextPartsFalse() {
    let request = OpenAIChatCompletionRequest(
        model: "vlm",
        messages: [
            .init(role: .user, content: .parts([.text("hi"), .text(" there")]))
        ])
    #expect(!VLMRequestInference.hasMedia(request))
}

// MARK: - buildUserInput

@Test("buildUserInput collects text + one image into the user message")
func vlmBuildUserInputTextAndImage() async throws {
    let request = OpenAIChatCompletionRequest(
        model: "vlm",
        messages: [
            .init(role: .system, content: .text("You are a vision assistant.")),
            .init(
                role: .user,
                content: .parts([
                    .text("Describe "),
                    .text("this image."),
                    .imageURL(tinyPNGDataURI),
                ])),
        ])

    let userInput = try await VLMRequestInference.buildUserInput(from: request)

    // UserInput aggregates media across all chat messages.
    #expect(userInput.images.count == 1)
    #expect(userInput.videos.isEmpty)

    guard case .chat(let messages) = userInput.prompt else {
        Issue.record("expected .chat prompt")
        return
    }
    #expect(messages.count == 2)
    #expect(messages[0].role == .system)
    #expect(messages[0].content == "You are a vision assistant.")
    let user = messages[1]
    #expect(user.role == .user)
    // text parts are concatenated in order
    #expect(user.content == "Describe this image.")
    #expect(user.images.count == 1)
    #expect(user.videos.isEmpty)
}

@Test("buildUserInput keeps a text-only request media-free")
func vlmBuildUserInputTextOnly() async throws {
    let request = OpenAIChatCompletionRequest(
        model: "vlm",
        messages: [.init(role: .user, content: .text("just text"))])

    let userInput = try await VLMRequestInference.buildUserInput(from: request)
    #expect(userInput.images.isEmpty)
    #expect(userInput.videos.isEmpty)
    guard case .chat(let messages) = userInput.prompt else {
        Issue.record("expected .chat prompt")
        return
    }
    #expect(messages.count == 1)
    #expect(messages[0].content == "just text")
}

// MARK: - error → HTTP status mapping

// These lock the status contract for the VLM-side errors:
//   - client-fault MediaError cases (bad/oversized/non-`data:` payloads the
//     caller controls) → 400
//   - the provider-side temp-file write failure → 500
//   - media sent to a non-VLM model → 400
// They also guard the propagation premise behind FIX F: these exact error
// values are what `VLMRequestInference.stream` / the engine throw upward, and
// `mapInferenceErrorToStatus` is what ProviderLoop calls on them.

@Test("client-fault MediaError cases map to HTTP 400")
func vlmMediaErrorMapsTo400() {
    let clientFaults: [VLMRequestInference.MediaError] = [
        .invalidURL("file:///etc/passwd"),
        .malformedDataURI("missing ','"),
        .base64DecodeFailed,
        .percentDecodeFailed,
        .imageDecodeFailed,
        .mediaTooLarge("image is 1600000000 px; per-image cap is 100000000 px"),
    ]
    for err in clientFaults {
        #expect(
            ProviderLoop.mapInferenceErrorToStatus(err) == 400,
            "expected 400 for \(err)")
    }
}

@Test("videoWriteFailed (provider IO fault) maps to HTTP 500")
func vlmVideoWriteFailedMapsTo500() {
    let err = VLMRequestInference.MediaError.videoWriteFailed("disk full")
    #expect(ProviderLoop.mapInferenceErrorToStatus(err) == 500)
}

@Test("media-to-non-VLM-model error maps to HTTP 400")
func vlmMediaUnsupportedByModelMapsTo400() {
    let err = MultiModelBatchSchedulerEngineError.mediaUnsupportedByModel("text-only")
    #expect(ProviderLoop.mapInferenceErrorToStatus(err) == 400)
}

@Test("MediaError surfaces a useful localizedDescription (LocalizedError)")
func vlmMediaErrorLocalizedDescription() {
    // FIX B: conforming to LocalizedError means the human-readable message
    // (not the generic Cocoa "operation couldn't be completed") reaches the
    // client via error.localizedDescription.
    let err = VLMRequestInference.MediaError.invalidURL("file:///etc/passwd")
    #expect(err.localizedDescription == "media must be sent as an inline base64 data: URI (e.g. \"data:image/jpeg;base64,…\") on this end-to-end-encrypted endpoint; remote http(s):// and file:// URLs are rejected. Got: file:///etc/passwd")
    #expect(!err.localizedDescription.contains("couldn’t be completed"))
}

// MARK: - Decompression-bomb / media-size caps

/// Assert `body` threw `MediaError.mediaTooLarge` (async: `decodeVideo` /
/// `buildUserInput` are async; sync bodies satisfy the closure type too).
private func expectMediaTooLarge(_ body: () async throws -> Void) async {
    do {
        try await body()
        Issue.record("expected MediaError.mediaTooLarge but no error was thrown")
    } catch let error as VLMRequestInference.MediaError {
        guard case .mediaTooLarge = error else {
            Issue.record("expected .mediaTooLarge, got \(error)")
            return
        }
    } catch {
        Issue.record("expected MediaError.mediaTooLarge, got \(error)")
    }
}

/// Async variant of `expectInvalidURL` for the now-async `decodeVideo`.
private func expectInvalidURLAsync(
    _ expectedURI: String, _ body: () async throws -> Void
) async {
    do {
        try await body()
        Issue.record("expected MediaError.invalidURL(\(expectedURI)) but nothing was thrown")
    } catch let error as VLMRequestInference.MediaError {
        guard case .invalidURL(let uri) = error else {
            Issue.record("expected .invalidURL, got \(error)")
            return
        }
        #expect(uri == expectedURI)
    } catch {
        Issue.record("expected MediaError.invalidURL, got \(error)")
    }
}

@Test("decodeImage rejects an image whose pixel count exceeds the per-image cap")
func vlmDecodeImageRejectsOverPixelCap() async {
    // The 1x1 tiny PNG is 1 px; a 0-px cap makes any real image over-cap, so we
    // hit the header-read reject path without allocating a multi-GB raster. On
    // hardware a real 40000x40000 bomb (256 Mpx–1.6 Gpx) takes this same branch
    // — measured peak 1.78 GB at 16000^2 on the real path before this fix.
    await expectMediaTooLarge {
        _ = try VLMRequestInference.decodeImage(tinyPNGDataURI, maxImagePixels: 0)
    }
}

@Test("decodeImage accepts an image within the per-image cap (no regression)")
func vlmDecodeImageWithinPixelCapPasses() throws {
    let image = try VLMRequestInference.decodeImage(tinyPNGDataURI, maxImagePixels: 100)
    guard case .ciImage = image else {
        Issue.record("expected a decoded .ciImage")
        return
    }
}

@Test("imagePixelCount reads dimensions from the header (no raster decode)")
func vlmImagePixelCountReadsHeader() throws {
    let data = try VLMRequestInference.dataFromDataURI(tinyPNGDataURI)
    #expect(VLMRequestInference.imagePixelCount(data) == 1)  // 1x1
    // Non-image bytes can't be sized -> nil (decodeImage then fails closed).
    #expect(VLMRequestInference.imagePixelCount(Data("not an image".utf8)) == nil)
}

@Test("dataFromDataURI rejects a payload over the decoded-byte cap")
func vlmDataFromDataURIRejectsOverByteCap() async {
    // 0-byte cap: any non-empty payload is over-cap, rejected from the base64
    // length before the decoded buffer is ever allocated.
    await expectMediaTooLarge {
        _ = try VLMRequestInference.dataFromDataURI(tinyPNGDataURI, maxMediaDecodedBytes: 0)
    }
}

@Test("buildUserInput rejects images whose aggregate pixels exceed the request cap")
func vlmBuildUserInputRejectsAggregatePixels() async {
    // Two 1x1 images = 2 px total; a 1-px aggregate cap trips on the second,
    // bounding the "pack many max-size images into one frame" amplification.
    let request = OpenAIChatCompletionRequest(
        model: "vlm",
        messages: [
            .init(
                role: .user,
                content: .parts([
                    .imageURL(tinyPNGDataURI),
                    .imageURL(tinyPNGDataURI),
                ]))
        ])
    await expectMediaTooLarge {
        _ = try await VLMRequestInference.buildUserInput(from: request, maxRequestImagePixels: 1)
    }
}

@Test("buildUserInput accepts images within the aggregate cap (no regression)")
func vlmBuildUserInputWithinAggregatePasses() async throws {
    let request = OpenAIChatCompletionRequest(
        model: "vlm",
        messages: [
            .init(
                role: .user,
                content: .parts([.imageURL(tinyPNGDataURI), .imageURL(tinyPNGDataURI)]))
        ])
    _ = try await VLMRequestInference.buildUserInput(from: request, maxRequestImagePixels: 10)
}

@Test("resolveMaxPixels honors a valid env override and falls back otherwise")
func vlmResolveMaxPixels() {
    let key = "DARKBLOOM_MAX_IMAGE_MEGAPIXELS"
    #expect(
        VLMRequestInference.resolveMaxPixels(
            env: key, defaultMegapixels: 100, environment: [key: "8"]) == 8_000_000)
    #expect(
        VLMRequestInference.resolveMaxPixels(
            env: key, defaultMegapixels: 100, environment: [:]) == 100_000_000)
    #expect(
        VLMRequestInference.resolveMaxPixels(
            env: key, defaultMegapixels: 100, environment: [key: "-1"]) == 100_000_000)
    #expect(
        VLMRequestInference.resolveMaxPixels(
            env: key, defaultMegapixels: 100, environment: [key: "abc"]) == 100_000_000)
}

@Test("resolveMaxPixels clamps a huge env value to Int.max instead of trapping")
func vlmResolveMaxPixelsClampsHuge() {
    // A very large finite megapixel value would, naively, do
    // `Int(min(mp*1e6, Double(Int.max)))` — but `Double(Int.max)` rounds up to
    // 2^63 (> Int.max), so `Int(...)` traps at the boundary, crashing the
    // provider at static init. The fix saturates to Int.max.
    let key = "DARKBLOOM_MAX_IMAGE_MEGAPIXELS"
    #expect(
        VLMRequestInference.resolveMaxPixels(
            env: key, defaultMegapixels: 100, environment: [key: "1e308"]) == Int.max)
    // A value whose ×1e6 lands exactly at the 2^63 boundary also saturates,
    // not traps.
    let boundaryMP = String(VLMRequestInference.intMaxAsDouble / 1_000_000)
    #expect(
        VLMRequestInference.resolveMaxPixels(
            env: key, defaultMegapixels: 100, environment: [key: boundaryMP]) == Int.max)
    // A normal large-but-representable value still scales correctly.
    #expect(
        VLMRequestInference.resolveMaxPixels(
            env: key, defaultMegapixels: 100, environment: [key: "1000"]) == 1_000_000_000)
}

@Test("resolveMaxBytes honors a valid env override and falls back otherwise")
func vlmResolveMaxBytes() {
    let key = "DARKBLOOM_MAX_MEDIA_MIB"
    #expect(
        VLMRequestInference.resolveMaxBytes(
            env: key, defaultMiB: 25, environment: [key: "4"]) == 4 * 1024 * 1024)
    #expect(
        VLMRequestInference.resolveMaxBytes(
            env: key, defaultMiB: 25, environment: [:]) == 25 * 1024 * 1024)
    #expect(
        VLMRequestInference.resolveMaxBytes(
            env: key, defaultMiB: 25, environment: [key: "0"]) == 25 * 1024 * 1024)
}

@Test("resolveMaxBytes clamps an overflowing MiB env value to Int.max instead of trapping")
func vlmResolveMaxBytesClampsOverflow() {
    // A MiB value that parses as Int but whose `* 1024 * 1024` overflows would
    // trap during static init. The fix saturates to Int.max.
    let key = "DARKBLOOM_MAX_MEDIA_MIB"
    let hugeMiB = String(Int.max)
    #expect(
        VLMRequestInference.resolveMaxBytes(
            env: key, defaultMiB: 25, environment: [key: hugeMiB]) == Int.max)
    // Just past the overflow threshold (Int.max / 1 MiB + 1) also saturates.
    let overThreshold = String((Int.max / (1024 * 1024)) + 1)
    #expect(
        VLMRequestInference.resolveMaxBytes(
            env: key, defaultMiB: 25, environment: [key: overThreshold]) == Int.max)
}

@Test("secondsString renders extreme/non-finite durations without trapping on Int(_:)")
func vlmSecondsStringNeverTraps() {
    // Whole numbers print cleanly (the common "600s" case).
    #expect(VLMRequestInference.secondsString(600) == "600")
    #expect(VLMRequestInference.secondsString(0) == "0")
    // Fractional values keep one decimal.
    #expect(VLMRequestInference.secondsString(12.5) == "12.5")
    // A duration far beyond Int.max seconds (untrusted video metadata) must NOT
    // trap — it would if formatted via `Int(duration.seconds)`. Just assert it
    // produces some non-empty string without crashing.
    #expect(!VLMRequestInference.secondsString(1e300).isEmpty)
    #expect(!VLMRequestInference.secondsString(Double.infinity).isEmpty)
    #expect(!VLMRequestInference.secondsString(Double.nan).isEmpty)
}

@Test("media-limit defaults are the documented values")
func vlmMediaLimitDefaults() {
    #expect(VLMRequestInference.maxImagePixels == 100_000_000)
    #expect(VLMRequestInference.maxRequestImagePixels == 384_000_000)
    #expect(VLMRequestInference.maxMediaDecodedBytes == 25 * 1024 * 1024)
    #expect(VLMRequestInference.maxVideoDurationSeconds == 600)
    #expect(VLMRequestInference.maxVideosPerRequest == 8)
    #expect(VLMRequestInference.maxRequestVideoFramePixels == 384_000_000)
}

/// Build a real PNG of the given dimensions (uniform gray) via ImageIO — to
/// exercise the header pixel-read on a genuine multi-pixel image (not the 1x1).
private func makePNGDataURI(width: Int, height: Int) -> String {
    let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(
        out, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    _ = CGImageDestinationFinalize(dest)
    return "data:image/png;base64,\((out as Data).base64EncodedString())"
}

@Test("dataFromDataURI rejects an over-cap percent-encoded payload")
func vlmDataFromDataURIRejectsOverByteCapPercentEncoded() async {
    // The non-base64 (percent-encoded) branch enforces the cap after decode.
    let uri = "data:text/plain," + String(repeating: "x", count: 64)
    await expectMediaTooLarge {
        _ = try VLMRequestInference.dataFromDataURI(uri, maxMediaDecodedBytes: 8)
    }
}

@Test("decodeVideo applies the byte cap before writing a temp file")
func vlmDecodeVideoRejectsOverByteCap() async {
    var tempFiles: [URL] = []
    await expectMediaTooLarge {
        _ = try await VLMRequestInference.decodeVideo(
            tinyMP4DataURI, tempFiles: &tempFiles, maxMediaDecodedBytes: 0)
    }
    #expect(tempFiles.isEmpty)  // rejected before any temp file is written
}

@Test("decodeVideo rejects a video whose frame exceeds the per-frame pixel cap")
func vlmDecodeVideoRejectsOverFrameCap() async {
    // The 64x64 fixture = 4096 px; a 1000-px per-frame cap rejects it, probed
    // from track metadata (naturalSize) without decoding frames.
    var tempFiles: [URL] = []
    await expectMediaTooLarge {
        _ = try await VLMRequestInference.decodeVideo(
            tinyMP4DataURI, tempFiles: &tempFiles, maxFramePixels: 1000)
    }
    #expect(tempFiles.isEmpty)  // rejected -> temp file cleaned up, not tracked
}

@Test("decodeVideo accepts a video within the per-frame cap (no regression)")
func vlmDecodeVideoWithinFrameCapPasses() async throws {
    var tempFiles: [URL] = []
    let (video, _) = try await VLMRequestInference.decodeVideo(
        tinyMP4DataURI, tempFiles: &tempFiles, maxFramePixels: 10_000)
    guard case .url(let url) = video else {
        Issue.record("expected .url, got \(video)")
        return
    }
    #expect(tempFiles == [url])
    try? FileManager.default.removeItem(at: url)
}

@Test("imagePixelCount + decodeImage reject a real multi-pixel image over the cap")
func vlmDecodeImageRealMultiPixelRejected() async throws {
    let uri = makePNGDataURI(width: 200, height: 150)  // 30000 px, ~120 KB raster
    let data = try VLMRequestInference.dataFromDataURI(uri)
    #expect(VLMRequestInference.imagePixelCount(data) == 30_000)
    await expectMediaTooLarge {
        _ = try VLMRequestInference.decodeImage(uri, maxImagePixels: 1_000)
    }
}

@Test("buildUserInput rejects more videos than the per-request count cap")
func vlmBuildUserInputRejectsVideoCount() async {
    // Three tiny valid videos with a 2-video cap -> rejected on the third,
    // bounding the "many tiny MP4s" aggregate-frame amplification.
    var tempFiles: [URL] = []
    let request = OpenAIChatCompletionRequest(
        model: "vlm",
        messages: [
            .init(
                role: .user,
                content: .parts([
                    .videoURL(tinyMP4DataURI),
                    .videoURL(tinyMP4DataURI),
                    .videoURL(tinyMP4DataURI),
                ]))
        ])
    await expectMediaTooLarge {
        _ = try await VLMRequestInference.buildUserInput(
            from: request, tempFiles: &tempFiles, maxVideosPerRequest: 2)
    }
    for u in tempFiles { try? FileManager.default.removeItem(at: u) }
}

@Test("buildUserInput rejects videos whose aggregate frame pixels exceed the cap")
func vlmBuildUserInputRejectsVideoFramePixels() async {
    // One 64x64 video = 4096 frame px; a 1-px aggregate cap trips it.
    var tempFiles: [URL] = []
    let request = OpenAIChatCompletionRequest(
        model: "vlm",
        messages: [.init(role: .user, content: .parts([.videoURL(tinyMP4DataURI)]))])
    await expectMediaTooLarge {
        _ = try await VLMRequestInference.buildUserInput(
            from: request, tempFiles: &tempFiles, maxRequestVideoFramePixels: 1)
    }
    for u in tempFiles { try? FileManager.default.removeItem(at: u) }
}
