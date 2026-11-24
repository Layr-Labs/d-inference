import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import MLXLMCommon
import MLXLMServer
import MLXVLM
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
    guard case .ciImage(let ci) = image.source else {
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

@Test("decodeImageData applies EXIF orientation so the raster matches what the camera saw")
func decodeImageAppliesExifOrientation() throws {
    // 2×1: left red, right green. Orientation .right (EXIF 6) rotates 90° CW
    // → 1×2 with red on top. Without applyOrientationProperty the model sees
    // a sideways crop and hallucinates a different scene.
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    var pixels: [UInt8] = [
        255, 0, 0, 255,
        0, 255, 0, 255,
    ]
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    let cgImage = try #require(
        CGImage(
            width: 2, height: 1,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent))

    let destData = NSMutableData()
    let dest = try #require(
        CGImageDestinationCreateWithData(
            destData, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(
        dest, cgImage,
        [kCGImagePropertyOrientation: CGImagePropertyOrientation.right.rawValue] as CFDictionary)
    #expect(CGImageDestinationFinalize(dest))

    let decoded = try MediaIngest.decodeImageData(destData as Data)
    guard case .ciImage(let image) = decoded.source else {
        Issue.record("expected .ciImage, got \(decoded)")
        return
    }
    #expect(Int(image.extent.width.rounded()) == 1)
    #expect(Int(image.extent.height.rounded()) == 2)
    #expect(image.extent.origin == .zero)
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
    guard case .memoryBacked(let memoryAsset) = video.source else {
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
    guard case .memoryBacked = video.source else {
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
        attestationSigner: nil)

    #expect(fileManager.fileExists(atPath: legacy.path))
}

/// Assert `body` threw the given `MediaError` case (`MediaError` is not
/// `Equatable`; the case is matched by its kind).
private func expectVideoError(
    _ kind: String, _ body: () async throws -> Void
) async {
    do {
        try await body()
        Issue.record("expected MediaError.\(kind) but no error was thrown")
    } catch let error as MediaIngest.MediaError {
        switch (kind, error) {
        case ("malformedDataURI", .malformedDataURI), ("unsupportedMedia", .unsupportedMedia):
            return
        default:
            Issue.record("expected MediaError.\(kind), got \(error)")
        }
    } catch {
        Issue.record("expected MediaError.\(kind), got \(error)")
    }
}

@Test("decodeVideo refuses bytes that are no ISO BMFF file as unsupported media")
func vlmDecodeVideoUnreadableMetadataRejected() async {
    // Bytes that aren't an ISO BMFF/MP4 are rejected before AVFoundation sees
    // them and never trigger a disk fallback. A Mac cannot open them, which is
    // a property of the format, not a corrupt file: 415 unsupported_media.
    let uri = "data:video/mp4;base64,\(Data("not a real video".utf8).base64EncodedString())"
    await expectVideoError("unsupportedMedia") { _ = try await MediaIngest.decodeVideo(uri) }
}

// The leading bytes of each container a Mac's AVFoundation cannot open from
// memory: WebM/Matroska (EBML), an MPEG program stream pack, an MPEG
// transport stream (sync bytes 188 apart), AVI and Ogg.
private let foreignVideoContainers: [(String, String, Data)] = [
    ("WebM", "video/webm", Data([0x1a, 0x45, 0xdf, 0xa3, 0x9f, 0x42, 0x86, 0x81, 0x01]) + Data("B\u{82}\u{84}webm".utf8)),
    ("Matroska", "video/x-matroska", Data([0x1a, 0x45, 0xdf, 0xa3, 0xa3, 0x42, 0x86, 0x81, 0x01]) + Data("B\u{82}\u{88}matroska".utf8)),
    ("MPEG program stream", "video/mpeg", Data([0x00, 0x00, 0x01, 0xba, 0x44, 0x00, 0x04, 0x00, 0x04, 0x01])),
    ("MPEG transport stream", "video/mp2t", Data([0x47] + [UInt8](repeating: 0xff, count: 187) + [0x47] + [UInt8](repeating: 0xff, count: 187))),
    ("AVI", "video/x-msvideo", Data("RIFF\u{0}\u{0}\u{0}\u{0}AVI LIST".utf8)),
    ("Ogg", "video/ogg", Data("OggS\u{0}\u{2}".utf8)),
]

@Test("decodeVideo refuses every non-ISO-BMFF container as unsupported media, whatever its label")
func vlmDecodeVideoRejectsOtherContainers() async {
    for (_, label, bytes) in foreignVideoContainers {
        for header in ["data:\(label);base64,", "data:video/mp4;base64,", "data:video/quicktime;base64,"] {
            let uri = header + bytes.base64EncodedString()
            await expectVideoError("unsupportedMedia") { _ = try await MediaIngest.decodeVideo(uri) }
        }
    }
}

@Test("decodeVideo decides by the bytes: an MP4 under any other label is opened")
func vlmDecodeVideoDecidesByTheBytes() async throws {
    // Labels clients send for MP4/QuickTime bytes (OpenRouter documents
    // video/mov); every Mac refused them with 400 invalid_media before.
    for header in [
        "data:video/mov;base64,", "data:video/x-m4v;base64,", "data:application/octet-stream;base64,",
        "data:video/mp4;codecs=avc1.64000b;base64,", "data:video/webm;base64,", "data:video/mpeg;base64,",
        "data:;base64,", "data:VIDEO/MP4;base64,",
    ] {
        let (video, framePixels) = try await MediaIngest.decodeVideo(header + tinyMP4Base64)
        guard case .memoryBacked = video.source else {
            Issue.record("expected .memoryBacked for \(header), got \(video)")
            continue
        }
        #expect(framePixels == 64 * 64, "\(header)")
    }
}

@Test("decodeVideo keeps a damaged ISO BMFF file a malformed-media fault")
func vlmDecodeVideoDamagedMP4IsMalformed() async {
    let mp4 = Data(base64Encoded: tinyMP4Base64)!
    for damaged in [mp4.prefix(mp4.count - 7), mp4.prefix(30)] {
        let uri = "data:video/mp4;base64,\(Data(damaged).base64EncodedString())"
        await expectVideoError("malformedDataURI") { _ = try await MediaIngest.decodeVideo(uri) }
    }
    await expectVideoError("malformedDataURI") { _ = try await MediaIngest.decodeVideo("data:video/mp4;base64,") }
}

@Test("decodeVideo requires a base64 payload: a URI without ;base64 is malformed, not a foreign container")
func vlmDecodeVideoRequiresBase64() async {
    // An MP4's base64 text sent without the parameter (or with it in upper
    // case, which `dataFromDataURI` reads as percent-encoded text, as the pair
    // leaders do), and percent-encoded text: the URI, not the container, is wrong.
    for uri in [
        "data:video/mp4,\(tinyMP4Base64)",
        "data:video/mp4;charset=binary,\(tinyMP4Base64)",
        "data:video/mov;BASE64,\(tinyMP4Base64)",
        "data:video/mp4,not%20a%20real%20video",
    ] {
        await expectVideoError("malformedDataURI") { _ = try await MediaIngest.decodeVideo(uri) }
    }
}

@Test("startsWithISOBMFFAtom separates a damaged MP4 or QuickTime file from another container")
func vlmStartsWithISOBMFFAtom() {
    func atom(_ type: String) -> Data { Data([0, 0, 0, 8]) + Data(type.utf8) }
    for type in ["ftyp", "moov", "mdat", "free", "skip", "wide", "pnot", "uuid", "styp", "moof"] {
        #expect(MediaIngest.startsWithISOBMFFAtom(atom(type)), "\(type)")
    }
    for bytes in [
        Data([0, 0, 0, 8]) + Data("sidx".utf8), Data([0, 0, 0, 8, 0x66, 0x74, 0x79]),
        Data([0x1a, 0x45, 0xdf, 0xa3, 0x9f, 0x42, 0x86, 0x81]), Data("RIFF\u{0}\u{0}\u{0}\u{0}AVI ".utf8), Data(),
    ] {
        #expect(!MediaIngest.startsWithISOBMFFAtom(bytes), "\(Array(bytes))")
    }
}

@Test("decodeVideo calls a legacy QuickTime file without mdat malformed, not foreign")
func vlmDecodeVideoLegacyQuickTimeWithoutMdat() async {
    // No ftyp: the asset needs both moov and mdat; this one is damaged.
    let movie = Data([0, 0, 0, 8]) + Data("wide".utf8) + Data([0, 0, 0, 9]) + Data("moov".utf8) + Data([0])
    await expectVideoError("malformedDataURI") {
        _ = try await MediaIngest.decodeVideo("data:video/quicktime;base64,\(movie.base64EncodedString())")
    }
}

@Test("a non-ISO-BMFF inline video reaches the coordinator as unsupported_media")
func vlmDecodeVideoForeignContainerFailureCode() async {
    let uri = "data:video/webm;base64,\(foreignVideoContainers[0].2.base64EncodedString())"
    do {
        _ = try await MediaIngest.decodeVideo(uri)
        Issue.record("expected a MediaError")
    } catch {
        let failure = ProviderLoop.sanitizedInferenceFailure(from: error, phase: .request)
        #expect(failure.code == .unsupportedMedia)
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
        .unsupportedMedia("a request carries at most 16 images"),
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
    guard case .ciImage = image.source else {
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

/// The Qwen3VL-family builds that take 64 images under a per-request image budget.
private let qwenImageBudgetModels = [
    "Qwen3.5-9B", "qwen3.5-35b-a3b", "qwen3.6-35b-a3b-vl-mtp-mxfp8", "EigenLabs/Qwen3.8-27B-4bit-mtp",
]

/// The image cap is per model (`imageCap(forModel:)`): 64 for the Qwen3VL-family
/// builds (their per-request image budget keeps the visual tokens of 16 full-size
/// images), 24 for Gemma 4 26B, 16 for every other model; the operator's override
/// applies to every model.
@Test("the image cap is per model: 64 for the Qwen builds, 24 for Gemma, 16 for the others")
func vlmImageCapPerModel() {
    #expect(
        Set(MediaIngest.modelMaxImagesPerRequest.keys)
            == Set(qwenImageBudgetModels + ["gemma-4-26b-qat-4bit"]).union(Inkling2ModelIdentity.servedModelIDs))
    #expect(Set(MediaIngest.modelImageBudget.keys) == Set(qwenImageBudgetModels))
    for model in qwenImageBudgetModels {
        #expect(MediaIngest.imageCap(forModel: model, environment: [:]) == 64)
        #expect(MediaIngest.imageBudget(forModel: model) == .init(images: 16, pixels: 16 * 1_048_576))
    }
    #expect(MediaIngest.imageCap(forModel: "gemma-4-26b-qat-4bit", environment: [:]) == 24)
    #expect(MediaIngest.imageBudget(forModel: "gemma-4-26b-qat-4bit") == nil)
    // Exact ids only: a differently-cased id, Super and others keep 16.
    for model in ["qwen3.5-9b", "nvidia-nemotron-3.5-super", "gemma-4-26b", "vlm", nil] as [String?] {
        #expect(MediaIngest.imageCap(forModel: model, environment: [:]) == 16)
        #expect(MediaIngest.imageBudget(forModel: model) == nil)
    }
    let key = "DARKBLOOM_MAX_IMAGES_PER_REQUEST"
    #expect(MediaIngest.imageCap(forModel: "Qwen3.5-9B", environment: [key: "8"]) == 8)
    #expect(MediaIngest.imageCap(forModel: "vlm", environment: [key: "32"]) == 32)
    // An unusable override keeps each model's own default.
    #expect(MediaIngest.imageCap(forModel: "Qwen3.5-9B", environment: [key: "0"]) == 64)
    #expect(MediaIngest.imageCap(forModel: "vlm", environment: [key: "many"]) == 16)
}

/// Inkling 2 Mini takes 64 images without an image budget: it does not pool,
/// and the per-request pixel cap bounds its visual tokens. Only its exact served
/// ids; the operator's override still wins, and the 65th image is refused as an
/// oversized-media client fault (400, not retried).
@Test("Inkling 2 Mini takes 64 images and refuses the 65th")
func inkling2ImageCap() async throws {
    let key = "DARKBLOOM_MAX_IMAGES_PER_REQUEST"
    #expect(!Inkling2ModelIdentity.servedModelIDs.isEmpty)
    for model in Inkling2ModelIdentity.servedModelIDs {
        #expect(MediaIngest.imageCap(forModel: model, environment: [:]) == 64)
        #expect(MediaIngest.imageBudget(forModel: model) == nil)
        #expect(MediaIngest.imageCap(forModel: model, environment: [key: "8"]) == 8)
        #expect(MediaIngest.imageCap(forModel: model, environment: [key: "0"]) == 64)
    }
    for model in ["thinkingmachines/inkling-2-mini", "Inkling-2-Mini", "inkling2_loop"] {
        #expect(MediaIngest.imageCap(forModel: model, environment: [:]) == 16)
    }
    func request(images: Int) -> OpenAIChatCompletionRequest {
        OpenAIChatCompletionRequest(
            model: Inkling2ModelIdentity.upstreamModelID,
            messages: [
                .init(role: .user, content: .parts(
                    [.text("Describe each page.")]
                        + (0 ..< images).map { _ in OpenAIContentPart.imageURL(tinyPNGDataURI) }))
            ])
    }
    let input = try await MediaIngest.buildUserInput(from: request(images: 64))
    #expect(input.images.count == 64)
    do {
        _ = try await MediaIngest.buildUserInput(from: request(images: 65))
        Issue.record("expected the 65th image to be refused")
    } catch let error as MediaIngest.MediaError {
        guard case .mediaTooLarge(let detail) = error else {
            Issue.record("expected .mediaTooLarge, got \(error)")
            return
        }
        #expect(detail == "request has 65 images; cap is 64")
        #expect(ProviderLoop.mapInferenceErrorToStatus(error) == 400)
    }
}

/// The vision prefill builds its input without an explicit cap
/// (`EngineV2VisionPrefill.prepare`), so the request's model decides it.
@Test("a Qwen build takes 64 images and refuses the 65th; Gemma 24; another model refuses its 17th")
func vlmBuildUserInputUsesTheModelsImageCap() async throws {
    func request(model: String, images: Int) -> OpenAIChatCompletionRequest {
        OpenAIChatCompletionRequest(
            model: model,
            messages: [
                .init(role: .user, content: .parts(
                    [.text("Describe each page.")]
                        + (0 ..< images).map { _ in OpenAIContentPart.imageURL(tinyPNGDataURI) }))
            ])
    }
    for model in qwenImageBudgetModels {
        let input = try await MediaIngest.buildUserInput(from: request(model: model, images: 64))
        #expect(input.images.count == 64)
        do {
            _ = try await MediaIngest.buildUserInput(from: request(model: model, images: 65))
            Issue.record("expected the 65th image to be refused")
        } catch let MediaIngest.MediaError.mediaTooLarge(detail) {
            #expect(detail == "request has 65 images; cap is 64")
        }
    }
    // Gemma 4 26B: 24 served, the 25th refused; another model's 17th refused.
    let gemma = try await MediaIngest.buildUserInput(from: request(model: "gemma-4-26b-qat-4bit", images: 24))
    #expect(gemma.images.count == 24)
    await expectMediaTooLarge {
        _ = try await MediaIngest.buildUserInput(from: request(model: "gemma-4-26b-qat-4bit", images: 25))
    }
    await expectMediaTooLarge {
        _ = try await MediaIngest.buildUserInput(from: request(model: "nvidia-nemotron-3.5-super", images: 17))
    }
    // An explicit cap still wins (the pair's Qwen media path passes its own).
    await expectMediaTooLarge {
        _ = try await MediaIngest.buildUserInput(
            from: request(model: "Qwen3.5-9B", images: 17), maxImagesPerRequest: 16)
    }
}

/// Past 16 images a Qwen build's request shares 16 full-size images' pixels: the
/// processor sizes every image to at most its share (`processing.maxPixels`, one
/// resize to its own grid). Images are passed as decoded; 16 or fewer images
/// (all counted, across messages), and other models, keep the processor's own
/// per-image ceiling (`maxPixels` nil).
@Test("past 16 images a Qwen request's images share 16 full-size images' pixels")
func qwenImageBudgetSharesTheProcessorsPixels() async throws {
    let page = makePNGDataURI(width: 1280, height: 1024)  // 1,310,720 px: the processor's own per-image ceiling
    func message(_ pages: Int) -> OpenAIChatMessage {
        .init(role: .user, content: .parts(
            [.text("frames of one video, in order")] + (0 ..< pages).map { _ in OpenAIContentPart.imageURL(page) }))
    }
    func input(_ model: String, _ pages: [Int], preserveTemplateFields: Bool = false) async throws -> UserInput {
        try await MediaIngest.buildUserInput(
            from: OpenAIChatCompletionRequest(model: model, messages: pages.map(message)),
            preserveTemplateFields: preserveTemplateFields)
    }
    let budget = 16 * 1_048_576
    // 16 full-size pages: the processor's own ceiling.
    let sixteen = try await input("Qwen3.5-9B", [16])
    #expect(sixteen.processing.maxPixels == nil)
    // 17, 32 and 64: each image's share; 9 + 9 over two user messages counts 18.
    for (model, pages) in [("Qwen3.5-9B", [17]), ("EigenLabs/Qwen3.8-27B-4bit-mtp", [32]),
                           ("qwen3.6-35b-a3b-vl-mtp-mxfp8", [64]), ("qwen3.5-35b-a3b", [9, 9])] {
        let built = try await input(model, pages)
        let count = pages.reduce(0, +)
        #expect(built.processing.maxPixels == budget / count)
        #expect(built.images.count == count)
        for image in built.images {
            guard case .ciImage(let ci) = image.source else { Issue.record("not a CIImage"); continue }
            #expect(ci.extent.size == CGSize(width: 1280, height: 1024))
        }
    }
    // The template-fields return path applies it too.
    let native = try await input("Qwen3.5-9B", [20], preserveTemplateFields: true)
    #expect(native.processing.maxPixels == budget / 20)
    // A model without a budget keeps the processor's ceiling (Gemma takes 24).
    let gemma = try await input("gemma-4-26b-qat-4bit", [20])
    #expect(gemma.processing.maxPixels == nil)
}

/// The media gate's KV reservation for a request past its model's image budget
/// is the visual tokens its images may hold plus a quarter, never more than
/// the 1,024-per-image charge. Past 64 images (an operator's override) each
/// image keeps at least the 262,144-px floor, so the reservation grows with the
/// count again: 128 images may hold 32,768 visual tokens, not 16,384.
@Test("the projected image tokens follow the image budget")
func projectedImageTokensFollowTheBudget() {
    for (model, images, tokens) in [
        ("Qwen3.5-9B", 16, 16 * 1_024), ("Qwen3.5-9B", 17, 17 * 1_024),
        ("Qwen3.5-9B", 21, 20_480), ("Qwen3.5-9B", 64, 20_480), ("EigenLabs/Qwen3.8-27B-4bit-mtp", 32, 20_480),
        ("Qwen3.5-9B", 65, 20_800), ("Qwen3.5-9B", 80, 25_600), ("Qwen3.5-9B", 128, 40_960),
        ("gemma-4-26b-qat-4bit", 24, 24 * 1_024), ("vlm", 64, 64 * 1_024),
    ] as [(String, Int, Int)] {
        #expect(MediaIngest.projectedImageTokens(images, model: model) == tokens)
    }
}

/// Each image of a budgeted request holds at most its share (never below the
/// floor) in visual tokens plus two delimiters; the reservation covers that at
/// any count, the floored counts past 64 included.
@Test("the projected image tokens cover what the shared images may hold")
func projectedImageTokensCoverTheShares() {
    let budget = MediaIngest.qwenImageBudget
    for images in (budget.images + 1)...512 {
        let share = max(budget.pixels / images, MediaIngest.minImageShare)
        let held = images * (share / 1_024 + 2)
        #expect(MediaIngest.projectedImageTokens(images, model: "Qwen3.5-9B") >= held)
    }
}

/// `DARKBLOOM_MAX_IMAGES_PER_REQUEST` is the image caps' kill switch (`16`
/// restores 0.10.13's one cap): an installed service must receive it.
@Test("the image-cap switch reaches the installed provider job")
func imageCapSwitchIsForwardedToTheService() {
    #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(MediaIngest.maxImagesEnvironmentKey))
    let forwarded = LaunchAgent.passthroughEnvironment(from: [MediaIngest.maxImagesEnvironmentKey: "16"])
    #expect(forwarded[MediaIngest.maxImagesEnvironmentKey] == "16")
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
    guard case .memoryBacked(let memoryAsset) = video.source else {
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

/// What the processor emits under the budget: the visual tokens of the images
/// `buildUserInput` hands it, through `Qwen3VLMediaProcessor.imageGrid` with the
/// input's own `processing` (a production-shaped processor config, CPU only).
/// 16 full-size pages keep their 1,280 tokens each; past 16, the whole request
/// stays within 16,384 visual tokens however many pages.
@Test("past 16 images the processor emits at most 16,384 visual tokens")
func qwenImageBudgetBoundsTheProcessorsTokens() async throws {
    let configuration = try JSONSerialization.data(withJSONObject: [
        "model_type": "qwen3_5", "image_token_id": 60, "video_token_id": 61,
        "vision_start_token_id": 57, "vision_end_token_id": 58,
        "text_config": ["model_type": "qwen3_5_text", "hidden_size": 8,
            "num_hidden_layers": 1, "intermediate_size": 16, "num_attention_heads": 1,
            "num_key_value_heads": 1, "head_dim": 8, "linear_num_key_heads": 1,
            "linear_num_value_heads": 1, "linear_key_head_dim": 8,
            "linear_value_head_dim": 8, "linear_conv_kernel_dim": 2,
            "vocab_size": 64, "full_attention_interval": 1],
        "vision_config": ["model_type": "qwen3_5_vision", "depth": 1,
            "hidden_size": 8, "intermediate_size": 16, "out_hidden_size": 8,
            "num_heads": 2, "patch_size": 16, "spatial_merge_size": 2,
            "temporal_patch_size": 2, "num_position_embeddings": 16,
            "in_channels": 3, "hidden_act": "gelu_pytorch_tanh", "deepstack_visual_indexes": []],
    ], options: [.sortedKeys])
    // The four builds' preprocessor_config.json (Qwen2VLImageProcessorFast, size bounds).
    let processorConfiguration = Data(#"{"image_processor_type":"Qwen2VLImageProcessorFast","patch_size":16,"merge_size":2,"temporal_patch_size":2,"image_mean":[0.5,0.5,0.5],"image_std":[0.5,0.5,0.5],"size":{"longest_edge":16777216,"shortest_edge":65536}}"#.utf8)
    let processor = try Qwen3VLMediaProcessor(
        modelConfiguration: configuration, processorConfiguration: processorConfiguration)
    let page = makePNGDataURI(width: 1280, height: 1024)
    func visualTokens(_ pages: Int) async throws -> Int {
        let input = try await MediaIngest.buildUserInput(from: OpenAIChatCompletionRequest(
            model: "EigenLabs/Qwen3.8-27B-4bit-mtp",
            messages: [.init(role: .user, content: .parts(
                [.text("pages")] + (0 ..< pages).map { _ in OpenAIContentPart.imageURL(page) }))]))
        var tokens = 0
        for image in input.images {
            guard case .ciImage(let ci) = image.source else { Issue.record("not a CIImage"); return -1 }
            let grid = try processor.imageGrid(
                height: Int(ci.extent.height), width: Int(ci.extent.width), processing: input.processing)
            tokens += grid.t * grid.h * grid.w / 4
        }
        return tokens
    }
    #expect(try await visualTokens(16) == 16 * 1_280)
    for pages in [17, 24, 32, 64] {
        let tokens = try await visualTokens(pages)
        #expect(tokens <= 16_384, "\(pages) pages: \(tokens) visual tokens")
        #expect(tokens >= 16_384 * 8 / 10, "\(pages) pages: \(tokens) visual tokens")
    }
}

/// The media gate's whole-request KV projection for a request past the budget.
@Test("the media gate projects a 64-image Qwen request from the budget")
func projectedKVTokensUseTheImageBudget() {
    func request(_ model: String, _ images: Int) -> OpenAIChatCompletionRequest {
        OpenAIChatCompletionRequest(model: model, messages: [.init(role: .user, content: .parts(
            [.text("")] + (0 ..< images).map { _ in OpenAIContentPart.imageURL(tinyPNGDataURI) }))])
    }
    #expect(MediaIngest.projectedKVTokens(request("Qwen3.5-9B", 64), defaultMaxTokens: 100, contextLength: 0)
        == 20_480 + 100)
    #expect(MediaIngest.projectedKVTokens(request("vlm", 64), defaultMaxTokens: 100, contextLength: 0)
        == 64 * 1_024 + 100)
}
