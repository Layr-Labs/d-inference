import AVFoundation
import Compression
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
    } catch let error as MediaIngest.MediaError {
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
    let data = try MediaIngest.dataFromDataURI(tinyPNGDataURI)
    // PNG magic number: 89 50 4E 47 0D 0A 1A 0A
    let magic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    #expect(Array(data.prefix(8)) == magic)
}

@Test("dataFromDataURI decodes a percent-encoded (non-base64) payload")
func vlmDataFromDataURIPercentEncoded() throws {
    let uri = "data:text/plain,hello%20world"
    let data = try MediaIngest.dataFromDataURI(uri)
    #expect(String(data: data, encoding: .utf8) == "hello world")
}

@Test("dataFromDataURI tolerates whitespace in base64 payload")
func vlmDataFromDataURIStripsWhitespace() throws {
    // Inject newlines/spaces the way some clients line-wrap base64.
    let wrapped = "data:image/png;base64," + tinyPNGBase64.prefix(40) + "\n  "
        + tinyPNGBase64.dropFirst(40)
    let data = try MediaIngest.dataFromDataURI(String(wrapped))
    #expect(data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
}

@Test("dataFromDataURI throws on a malformed data: URI (no comma)")
func vlmDataFromDataURIMalformedThrows() {
    #expect(throws: MediaIngest.MediaError.self) {
        _ = try MediaIngest.dataFromDataURI("data:image/png;base64")
    }
}

@Test("dataFromDataURI throws on undecodable base64")
func vlmDataFromDataURIBadBase64Throws() {
    #expect(throws: MediaIngest.MediaError.self) {
        _ = try MediaIngest.dataFromDataURI("data:image/png;base64,!!!not base64!!!")
    }
}

// MARK: - decodeImage

@Test("decodeImage decodes a base64 data: URI into a CIImage")
func vlmDecodeImageDataURI() throws {
    let image = try MediaIngest.decodeImage(tinyPNGDataURI)
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
        _ = try MediaIngest.decodeImage("https://example.com/cat.png")
    }
}

@Test("decodeImage rejects a file:// URI with invalidURL (no local-file read)")
func vlmDecodeImageFileRejected() {
    expectInvalidURL("file:///etc/passwd") {
        _ = try MediaIngest.decodeImage("file:///etc/passwd")
    }
}

@Test("decodeImage throws when a data: URI holds non-image bytes")
func vlmDecodeImageGarbageThrows() {
    // Valid base64 but not a decodable image.
    let garbage = "data:image/png;base64," + Data("not an image".utf8).base64EncodedString()
    #expect(throws: MediaIngest.MediaError.self) {
        _ = try MediaIngest.decodeImage(garbage)
    }
}

// MARK: - decodeVideo

@Test("decodeVideo retains inline MP4 bytes in memory without creating a temp file")
func vlmDecodeVideoDataURIStaysInMemory() async throws {
    let fileManager = FileManager.default
    let tempDirectory = fileManager.temporaryDirectory
    let oldTempFiles = try Set(
        fileManager.contentsOfDirectory(atPath: tempDirectory.path)
            .filter { $0.hasPrefix("vlm-") && $0.hasSuffix(".mp4") })

    // A real, probeable 64x64 video passes the limits and stays owned by the
    // memory-backed resource loader. Assert only that decode creates no new
    // plaintext file: another parallel suite may legitimately delete a stale
    // pre-existing `vlm-*.mp4` between these snapshots.
    let (video, framePixels) = try await MediaIngest.decodeVideo(tinyMP4DataURI)
    guard case .memoryBacked(let memoryAsset) = video else {
        Issue.record("expected .memoryBacked, got \(video)")
        return
    }
    #expect(memoryAsset.byteCount == Data(base64Encoded: tinyMP4Base64)!.count)
    #expect(framePixels == 64 * 64)

    let newTempFiles = try Set(
        fileManager.contentsOfDirectory(atPath: tempDirectory.path)
            .filter { $0.hasPrefix("vlm-") && $0.hasSuffix(".mp4") })
    let createdTempFiles = newTempFiles.subtracting(oldTempFiles)
    #expect(createdTempFiles.isEmpty, "decodeVideo created plaintext temp files: \(createdTempFiles)")
}

@Test("decodeVideo accepts the coordinator's video/quicktime data URI contract")
func vlmDecodeVideoQuickTimeDataURI() async throws {
    let uri = "data:video/quicktime;base64,\(tinyMP4Base64)"
    let (video, framePixels) = try await MediaIngest.decodeVideo(uri)
    guard case .memoryBacked = video else {
        Issue.record("expected .memoryBacked, got \(video)")
        return
    }
    #expect(framePixels == 64 * 64)
}

@Test("startup purge removes only exact legacy plaintext-video temp files")
func vlmLegacyVideoTempPurgeIsNarrow() throws {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory
        .appendingPathComponent("media-purge-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: directory) }

    let legacy = directory.appendingPathComponent("vlm-\(UUID().uuidString).mp4")
    let unrelated = directory.appendingPathComponent("vlm-not-a-uuid.mp4")
    let directoryCollision = directory.appendingPathComponent(
        "vlm-\(UUID().uuidString).mp4", isDirectory: true)
    try Data("legacy plaintext".utf8).write(to: legacy)
    try Data("keep".utf8).write(to: unrelated)
    try fileManager.createDirectory(at: directoryCollision, withIntermediateDirectories: false)

    MediaIngest.purgeLegacyVideoTempFiles(in: directory)

    #expect(!fileManager.fileExists(atPath: legacy.path))
    #expect(fileManager.fileExists(atPath: unrelated.path))
    #expect(fileManager.fileExists(atPath: directoryCollision.path))
}

@Test("ProviderLoop construction does not mutate the temporary directory")
func vlmProviderLoopConstructionDoesNotRunMediaHousekeeping() throws {
    let fileManager = FileManager.default
    let legacy = fileManager.temporaryDirectory
        .appendingPathComponent("vlm-\(UUID().uuidString).mp4")
    try Data("legacy plaintext".utf8).write(to: legacy)
    defer { try? fileManager.removeItem(at: legacy) }

    let config = ProviderLoopConfig(
        coordinatorURL: "ws://127.0.0.1:0/unused",
        hardware: HardwareInfo(
            machineModel: "Mac16,5",
            chipName: "Apple M4 Max",
            chipFamily: .m4,
            chipTier: .max,
            memoryGb: 128,
            memoryAvailableGb: 124,
            cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
            gpuCores: 40,
            memoryBandwidthGbs: 546),
        models: [],
        config: ProviderConfig(
            provider: ProviderSettings(name: "media-housekeeping-test", memoryReserveGB: 1),
            backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 1),
            coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)))

    _ = try ProviderLoop(
        config: config,
        purgeLegacyFiles: true,
        attestationSigner: nil)

    #expect(fileManager.fileExists(atPath: legacy.path))
}

@Test("decodeVideo fails closed when video metadata is unprobeable")
func vlmDecodeVideoUnreadableMetadataRejected() async {
    // Bytes that aren't an ISO BMFF/MP4 are rejected before AVFoundation sees
    // them and never trigger a disk fallback.
    let uri = "data:video/mp4;base64,\(Data("not a real video".utf8).base64EncodedString())"
    do {
        _ = try await MediaIngest.decodeVideo(uri)
        Issue.record("expected malformedDataURI")
    } catch let error as MediaIngest.MediaError {
        guard case .malformedDataURI = error else {
            Issue.record("expected malformedDataURI, got \(error)")
            return
        }
    } catch {
        Issue.record("expected MediaError, got \(error)")
    }
}

@Test("decodeVideo fails closed on a non-MP4 data URI")
func vlmDecodeVideoRejectsOtherContainerMIME() async {
    let uri = "data:video/webm;base64,\(tinyMP4Base64)"
    do {
        _ = try await MediaIngest.decodeVideo(uri)
        Issue.record("expected malformedDataURI")
    } catch let error as MediaIngest.MediaError {
        guard case .malformedDataURI = error else {
            Issue.record("expected malformedDataURI, got \(error)")
            return
        }
    } catch {
        Issue.record("expected MediaError, got \(error)")
    }
}

@Test("decodeVideo rejects an http:// URI with invalidURL (no SSRF)")
func vlmDecodeVideoHTTPRejected() async {
    await expectInvalidURLAsync("https://example.com/clip.mp4") {
        _ = try await MediaIngest.decodeVideo("https://example.com/clip.mp4")
    }
}

@Test("decodeVideo rejects a file:// URI with invalidURL (no local-file read)")
func vlmDecodeVideoFileRejected() async {
    await expectInvalidURLAsync("file:///etc/passwd") {
        _ = try await MediaIngest.decodeVideo("file:///etc/passwd")
    }
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
    #expect(MediaIngest.hasMedia(request))
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
    #expect(MediaIngest.hasMedia(request))
}

@Test("hasMedia is false for a plain text request")
func vlmHasMediaTextFalse() {
    let request = OpenAIChatCompletionRequest(
        model: "vlm",
        messages: [.init(role: .user, content: .text("hello"))])
    #expect(!MediaIngest.hasMedia(request))
}

@Test("hasMedia is false for parts that are text-only")
func vlmHasMediaTextPartsFalse() {
    let request = OpenAIChatCompletionRequest(
        model: "vlm",
        messages: [
            .init(role: .user, content: .parts([.text("hi"), .text(" there")]))
        ])
    #expect(!MediaIngest.hasMedia(request))
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

    let userInput = try await MediaIngest.buildUserInput(from: request)

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

    let userInput = try await MediaIngest.buildUserInput(from: request)
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
//   - media sent to a non-VLM model → 400
// They also guard the propagation premise behind FIX F: these exact error
// values are what `MediaIngest.stream` / the engine throw upward, and
// `mapInferenceErrorToStatus` is what ProviderLoop calls on them.

@Test("client-fault MediaError cases map to HTTP 400")
func vlmMediaErrorMapsTo400() {
    let clientFaults: [MediaIngest.MediaError] = [
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
    let err = MediaIngest.MediaError.invalidURL("file:///etc/passwd")
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
    } catch let error as MediaIngest.MediaError {
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
    } catch let error as MediaIngest.MediaError {
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
        _ = try MediaIngest.decodeImage(tinyPNGDataURI, maxImagePixels: 0)
    }
}

@Test("decodeImage accepts an image within the per-image cap (no regression)")
func vlmDecodeImageWithinPixelCapPasses() throws {
    let image = try MediaIngest.decodeImage(tinyPNGDataURI, maxImagePixels: 100)
    guard case .ciImage = image else {
        Issue.record("expected a decoded .ciImage")
        return
    }
}

@Test("imagePixelCount reads dimensions from the header (no raster decode)")
func vlmImagePixelCountReadsHeader() throws {
    let data = try MediaIngest.dataFromDataURI(tinyPNGDataURI)
    #expect(MediaIngest.imagePixelCount(data) == 1)  // 1x1
    // Non-image bytes can't be sized -> nil (decodeImage then fails closed).
    #expect(MediaIngest.imagePixelCount(Data("not an image".utf8)) == nil)
}

@Test("dataFromDataURI rejects a payload over the decoded-byte cap")
func vlmDataFromDataURIRejectsOverByteCap() async {
    // 0-byte cap: any non-empty payload is over-cap, rejected from the base64
    // length before the decoded buffer is ever allocated.
    await expectMediaTooLarge {
        _ = try MediaIngest.dataFromDataURI(tinyPNGDataURI, maxMediaDecodedBytes: 0)
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
        _ = try await MediaIngest.buildUserInput(from: request, maxRequestImagePixels: 1)
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
    _ = try await MediaIngest.buildUserInput(from: request, maxRequestImagePixels: 10)
}

@Test("resolveMaxPixels honors a valid env override and falls back otherwise")
func vlmResolveMaxPixels() {
    let key = "DARKBLOOM_MAX_IMAGE_MEGAPIXELS"
    #expect(
        MediaIngest.resolveMaxPixels(
            env: key, defaultMegapixels: 100, environment: [key: "8"]) == 8_000_000)
    #expect(
        MediaIngest.resolveMaxPixels(
            env: key, defaultMegapixels: 100, environment: [:]) == 100_000_000)
    #expect(
        MediaIngest.resolveMaxPixels(
            env: key, defaultMegapixels: 100, environment: [key: "-1"]) == 100_000_000)
    #expect(
        MediaIngest.resolveMaxPixels(
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
        MediaIngest.resolveMaxPixels(
            env: key, defaultMegapixels: 100, environment: [key: "1e308"]) == Int.max)
    // A value whose ×1e6 lands exactly at the 2^63 boundary also saturates,
    // not traps.
    let boundaryMP = String(MediaIngest.intMaxAsDouble / 1_000_000)
    #expect(
        MediaIngest.resolveMaxPixels(
            env: key, defaultMegapixels: 100, environment: [key: boundaryMP]) == Int.max)
    // A normal large-but-representable value still scales correctly.
    #expect(
        MediaIngest.resolveMaxPixels(
            env: key, defaultMegapixels: 100, environment: [key: "1000"]) == 1_000_000_000)
}

@Test("resolveMaxBytes honors a valid env override and falls back otherwise")
func vlmResolveMaxBytes() {
    let key = "DARKBLOOM_MAX_MEDIA_MIB"
    #expect(
        MediaIngest.resolveMaxBytes(
            env: key, defaultMiB: 25, environment: [key: "4"]) == 4 * 1024 * 1024)
    #expect(
        MediaIngest.resolveMaxBytes(
            env: key, defaultMiB: 25, environment: [:]) == 25 * 1024 * 1024)
    #expect(
        MediaIngest.resolveMaxBytes(
            env: key, defaultMiB: 25, environment: [key: "0"]) == 25 * 1024 * 1024)
}

@Test("resolveMaxBytes clamps an overflowing MiB env value to Int.max instead of trapping")
func vlmResolveMaxBytesClampsOverflow() {
    // A MiB value that parses as Int but whose `* 1024 * 1024` overflows would
    // trap during static init. The fix saturates to Int.max.
    let key = "DARKBLOOM_MAX_MEDIA_MIB"
    let hugeMiB = String(Int.max)
    #expect(
        MediaIngest.resolveMaxBytes(
            env: key, defaultMiB: 25, environment: [key: hugeMiB]) == Int.max)
    // Just past the overflow threshold (Int.max / 1 MiB + 1) also saturates.
    let overThreshold = String((Int.max / (1024 * 1024)) + 1)
    #expect(
        MediaIngest.resolveMaxBytes(
            env: key, defaultMiB: 25, environment: [key: overThreshold]) == Int.max)
}

@Test("secondsString renders extreme/non-finite durations without trapping on Int(_:)")
func vlmSecondsStringNeverTraps() {
    // Whole numbers print cleanly (the common "600s" case).
    #expect(MediaIngest.secondsString(600) == "600")
    #expect(MediaIngest.secondsString(0) == "0")
    // Fractional values keep one decimal.
    #expect(MediaIngest.secondsString(12.5) == "12.5")
    // A duration far beyond Int.max seconds (untrusted video metadata) must NOT
    // trap — it would if formatted via `Int(duration.seconds)`. Just assert it
    // produces some non-empty string without crashing.
    #expect(!MediaIngest.secondsString(1e300).isEmpty)
    #expect(!MediaIngest.secondsString(Double.infinity).isEmpty)
    #expect(!MediaIngest.secondsString(Double.nan).isEmpty)
}

@Test("media-limit defaults are the documented values")
func vlmMediaLimitDefaults() {
    #expect(MediaIngest.maxImagePixels == 100_000_000)
    #expect(MediaIngest.maxRequestImagePixels == 384_000_000)
    #expect(MediaIngest.maxMediaDecodedBytes == 25 * 1024 * 1024)
    #expect(MediaIngest.maxVideoDurationSeconds == 600)
    #expect(MediaIngest.maxImagesPerRequest == 16)
    #expect(MediaIngest.maxVideosPerRequest == 8)
    #expect(MediaIngest.maxRequestVideoFramePixels == 384_000_000)
}

/// The aggregate PIXEL cap does not bound the image COUNT: the processor
/// resizes every image down, so a request of tiny images passes it while
/// still driving one vision-tower forward pass each, under the model
/// container's lock.
@Test("buildUserInput caps the number of images per request")
func vlmBuildUserInputCapsImageCount() async throws {
    func request(images: Int) -> OpenAIChatCompletionRequest {
        OpenAIChatCompletionRequest(
            model: "vlm",
            messages: [
                .init(
                    role: .user,
                    content: .parts(
                        (0 ..< images).map { _ in OpenAIContentPart.imageURL(tinyPNGDataURI) }))
            ])
    }
    // At the cap: fine.
    _ = try await MediaIngest.buildUserInput(from: request(images: 4), maxImagesPerRequest: 4)
    // One over: refused, and the message says the count and the cap.
    await expectMediaTooLarge {
        _ = try await MediaIngest.buildUserInput(from: request(images: 5), maxImagesPerRequest: 4)
    }
    // Counted across MESSAGES, not per message — otherwise the cap is trivial
    // to evade by splitting the images into separate turns.
    let split = OpenAIChatCompletionRequest(
        model: "vlm",
        messages: [
            .init(role: .user, content: .parts([.imageURL(tinyPNGDataURI)])),
            .init(role: .user, content: .parts([.imageURL(tinyPNGDataURI)])),
            .init(role: .user, content: .parts([.imageURL(tinyPNGDataURI)])),
        ])
    await expectMediaTooLarge {
        _ = try await MediaIngest.buildUserInput(from: split, maxImagesPerRequest: 2)
    }
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
        _ = try MediaIngest.dataFromDataURI(uri, maxMediaDecodedBytes: 8)
    }
}

@Test("decodeVideo applies the byte cap before constructing an in-memory asset")
func vlmDecodeVideoRejectsOverByteCap() async {
    await expectMediaTooLarge {
        _ = try await MediaIngest.decodeVideo(
            tinyMP4DataURI, maxMediaDecodedBytes: 0)
    }
}

@Test("decodeVideo rejects a video whose frame exceeds the per-frame pixel cap")
func vlmDecodeVideoRejectsOverFrameCap() async {
    // The 64x64 fixture = 4096 px; a 1000-px per-frame cap rejects it, probed
    // from track metadata (naturalSize) without decoding frames.
    await expectMediaTooLarge {
        _ = try await MediaIngest.decodeVideo(
            tinyMP4DataURI, maxFramePixels: 1000)
    }
}

@Test("decodeVideo accepts a video within the per-frame cap (no regression)")
func vlmDecodeVideoWithinFrameCapPasses() async throws {
    let (video, framePixels) = try await MediaIngest.decodeVideo(
        tinyMP4DataURI, maxFramePixels: 10_000)
    guard case .memoryBacked(let memoryAsset) = video else {
        Issue.record("expected .memoryBacked, got \(video)")
        return
    }
    #expect(memoryAsset.byteCount > 0)
    #expect(framePixels == 64 * 64)
}

@Test("imagePixelCount + decodeImage reject a real multi-pixel image over the cap")
func vlmDecodeImageRealMultiPixelRejected() async throws {
    let uri = makePNGDataURI(width: 200, height: 150)  // 30000 px, ~120 KB raster
    let data = try MediaIngest.dataFromDataURI(uri)
    #expect(MediaIngest.imagePixelCount(data) == 30_000)
    await expectMediaTooLarge {
        _ = try MediaIngest.decodeImage(uri, maxImagePixels: 1_000)
    }
}

@Test("buildUserInput rejects more videos than the per-request count cap")
func vlmBuildUserInputRejectsVideoCount() async {
    // Three tiny valid videos with a 2-video cap -> rejected on the third,
    // bounding the "many tiny MP4s" aggregate-frame amplification.
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
        _ = try await MediaIngest.buildUserInput(
            from: request, maxVideosPerRequest: 2)
    }
}

@Test("buildUserInput rejects videos whose aggregate frame pixels exceed the cap")
func vlmBuildUserInputRejectsVideoFramePixels() async {
    // One 64x64 video = 4096 frame px; a 1-px aggregate cap trips it.
    let request = OpenAIChatCompletionRequest(
        model: "vlm",
        messages: [.init(role: .user, content: .parts([.videoURL(tinyMP4DataURI)]))])
    await expectMediaTooLarge {
        _ = try await MediaIngest.buildUserInput(
            from: request, maxRequestVideoFramePixels: 1)
    }
}

// Decompression-bomb regression suite for the VLM media-decode path.
//
// This is the automated form of an on-hardware OOM repro (originally a manual
// spike). `CIImage(data:)` eagerly rasterizes a PNG (W·H·4 bytes, no lazy
// decode, no scaled decode), so a tiny highly-compressed "bomb" explodes on
// decode — measured on an M5 Max (128 GB, 0-swap, provider co-resident at
// ~63 GB) BEFORE any KV/token/load admission:
//
//   input    mode               on-wire   decoded     peak RSS
//   16000²   decode-only        757 KiB   256 Mpx     0.96 GB
//   16000²   mlxpath (real)     757 KiB   256 Mpx     1.78 GB
//   32000²   mlxpath (real)     3.0 MB    1024 Mpx    5.73 GB
//   40000²   header (the fix)   4.7 MB    40000×40000 ~0 GB
//
// CIImage(data:) is NOT lazy for PNG (decode RSS scales linearly with pixels),
// and the model's downscale does NOT help — CoreImage decodes the full-res
// source before resampling. Reading dimensions from the format header is the
// only O(header) escape, so the guard rejects from the header BEFORE the raster
// is allocated.
//
// Rather than ship a multi-MB binary fixture or a Python generator, these tests
// synthesize a real, header-readable PNG bomb in-process via streaming zlib: a
// uniform-color WxH image that is a few KB on the wire but declares a huge
// raster. The guard reads the declared dimensions and rejects it as
// `MediaError.mediaTooLarge` at ~0 RSS. A CI-safe bomb that is *rejected from
// the header* is exactly the right shape: it would OOM if the guard regressed,
// and stays flat while the guard holds.

// MARK: - In-process PNG decompression-bomb generator

/// Build a uniform mid-gray RGB PNG of `width`x`height` by streaming scanlines
/// through zlib, so the generator itself holds ~one scanline (not the full
/// raster). The output is a real, ImageIO-sizeable PNG: tiny on the wire, but
/// its IHDR declares `width`x`height` and `CIImage(data:)` WOULD allocate
/// width·height·4 bytes if it decoded.
internal enum PNGBomb {
    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes { crc = crcTable[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    private static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }

    private static func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
        let t = Array(type.utf8)
        return be32(UInt32(data.count)) + t + data + be32(crc32(t + data))
    }

    static func make(width: Int, height: Int) -> Data {
        let sig: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let ihdr = be32(UInt32(width)) + be32(UInt32(height)) + [8, 2, 0, 0, 0]  // 8-bit RGB

        // One raw scanline: filter byte 0 + uniform mid-gray RGB.
        var row = [UInt8](repeating: 0x7f, count: 1 + width * 3)
        row[0] = 0

        // Adler-32 over the uncompressed scanlines (zlib trailer).
        var a: UInt32 = 1, b: UInt32 = 0
        func adler(_ bytes: [UInt8]) {
            for byte in bytes {
                a = (a + UInt32(byte)) % 65521
                b = (b + a) % 65521
            }
        }

        // Apple's COMPRESSION_ZLIB is raw DEFLATE (no header/trailer); we add the
        // zlib wrapper (0x78 0x01 + adler32) manually for a valid PNG IDAT.
        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer(bitPattern: 1)!, dst_size: 0,
            src_ptr: UnsafeMutablePointer(bitPattern: 1)!, src_size: 0, state: nil)
        compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB)
        defer { compression_stream_destroy(&stream) }

        var deflate: [UInt8] = [0x78, 0x01]
        let outCap = 1 << 16
        var outBuf = [UInt8](repeating: 0, count: outCap)

        func drain(finalize: Bool) {
            outBuf.withUnsafeMutableBufferPointer { ob in
                stream.dst_ptr = ob.baseAddress!
                stream.dst_size = outCap
                while true {
                    let flags = finalize ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                    let status = compression_stream_process(&stream, flags)
                    let produced = outCap - stream.dst_size
                    if produced > 0 { deflate.append(contentsOf: ob[0..<produced]) }
                    stream.dst_ptr = ob.baseAddress!
                    stream.dst_size = outCap
                    if status == COMPRESSION_STATUS_END { break }
                    if status == COMPRESSION_STATUS_OK {
                        if !finalize && stream.src_size == 0 { break }
                        continue
                    }
                    break  // error — produce what we have
                }
            }
        }

        row.withUnsafeBufferPointer { rp in
            for _ in 0..<height {
                stream.src_ptr = rp.baseAddress!
                stream.src_size = row.count
                drain(finalize: false)
                adler(row)
            }
        }
        drain(finalize: true)
        deflate.append(contentsOf: be32((b << 16) | a))

        var out = sig
        out += chunk("IHDR", ihdr)
        out += chunk("IDAT", deflate)
        out += chunk("IEND", [])
        return Data(out)
    }

    static func dataURI(width: Int, height: Int) -> String {
        "data:image/png;base64,\(make(width: width, height: height).base64EncodedString())"
    }
}


// MARK: - Generator self-checks

@Test("PNGBomb produces a real PNG that is tiny on the wire but declares a huge raster")
func vlmBombGeneratorProducesHeaderReadableTinyPNG() throws {
    // 2000x2000 = 4 Mpx: would rasterize to ~16 MB, but compresses to a few KB.
    let data = PNGBomb.make(width: 2000, height: 2000)

    // Tiny on the wire (uniform color compresses hard) — well under the 32 MiB
    // WS frame cap, like a real malicious payload.
    #expect(data.count < 256 * 1024, "bomb should be small on the wire, was \(data.count) bytes")

    // PNG magic.
    #expect(Array(data.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    // ImageIO reads the declared dimensions from the header WITHOUT decoding the
    // raster — this is the exact mechanism the provider's guard relies on.
    #expect(MediaIngest.imagePixelCount(data) == 4_000_000)
}

// MARK: - The bomb is rejected before the raster is allocated

@Test("decodeImage rejects a real PNG decompression bomb from the header")
func vlmDecodeImageRejectsRealBomb() async {
    // A header-declared 4 Mpx image against a 1 Mpx cap. If the guard regressed,
    // CIImage(data:) would allocate the full raster here; because it rejects from
    // the header, RSS stays flat. (On real hardware the same branch rejects a
    // 40000² / 1.6 Gpx bomb at ~0 RSS — see the measurement table above.)
    let uri = PNGBomb.dataURI(width: 2000, height: 2000)
    await expectMediaTooLarge {
        _ = try MediaIngest.decodeImage(uri, maxImagePixels: 1_000_000)
    }
}

@Test("decodeImage accepts the same bomb when its pixels are within the cap (no regression)")
func vlmDecodeImageAcceptsBombWithinCap() throws {
    // The bomb is a genuine PNG; with a cap above its pixel count it decodes
    // normally — proving the reject is about size, not a malformed-file false
    // positive. 2000x2000 = 4 Mpx, decodes to ~16 MB (CI-affordable).
    let uri = PNGBomb.dataURI(width: 2000, height: 2000)
    let image = try MediaIngest.decodeImage(uri, maxImagePixels: 8_000_000)
    guard case .ciImage(let ci) = image else {
        Issue.record("expected a decoded .ciImage")
        return
    }
    #expect(ci.extent.width == 2000)
    #expect(ci.extent.height == 2000)
}

@Test("buildUserInput rejects an over-aggregate bomb BEFORE decoding the over-limit image")
func vlmBuildUserInputRejectsAggregateBombBeforeDecode() async {
    // Two 2000x2000 (4 Mpx each) bombs with a 5 Mpx aggregate cap. The first is
    // within cap and decodes; the second pushes the aggregate to 8 Mpx and MUST
    // be rejected from its header BEFORE CIImage(data:) allocates its raster
    // (the P2 fix: charge the header pixel count to the aggregate pre-decode).
    let uri = PNGBomb.dataURI(width: 2000, height: 2000)
    let request = OpenAIChatCompletionRequest(
        model: "vlm",
        messages: [
            .init(role: .user, content: .parts([.imageURL(uri), .imageURL(uri)]))
        ])
    await expectMediaTooLarge {
        _ = try await MediaIngest.buildUserInput(
            from: request, maxImagePixels: 8_000_000, maxRequestImagePixels: 5_000_000)
    }
}

@Test("validateMedia throws MediaError synchronously (before any stream is returned)")
func vlmValidateMediaThrowsUpFront() async {
    // The streaming HTTP path (sseResponse) returns a 200 SSE Response and only
    // surfaces a generation error mid-iteration — too late for a 4xx. So the
    // engine calls validateMedia(request) and propagates its throw BEFORE
    // returning the stream. This asserts validateMedia actually throws on an
    // oversized payload, so the engine's `try await` surfaces the MediaError to
    // the HTTP/WS layer. Uses a small (fast-to-generate) bomb + a low injected
    // cap rather than a real >100 Mpx image.
    let uri = PNGBomb.dataURI(width: 2000, height: 2000)  // 4 Mpx
    let request = OpenAIChatCompletionRequest(
        model: "vlm",
        messages: [.init(role: .user, content: .parts([.imageURL(uri)]))])
    await expectMediaTooLarge {
        try await MediaIngest.validateMedia(request, maxImagePixels: 1_000_000)
    }
}

@Test("validateMedia passes a within-cap request (no false positive)")
func vlmValidateMediaAcceptsWithinCap() async throws {
    // A normal small image must validate cleanly so genuine requests aren't
    // rejected before they ever reach generation.
    let request = OpenAIChatCompletionRequest(
        model: "vlm",
        messages: [.init(role: .user, content: .parts([
            .text("describe"), .imageURL(PNGBomb.dataURI(width: 64, height: 64)),
        ]))])
    try await MediaIngest.validateMedia(request)
}
