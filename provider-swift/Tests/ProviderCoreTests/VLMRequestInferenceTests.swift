import CoreImage
import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

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
func vlmDecodeVideoDataURIWritesTempFile() throws {
    var tempFiles: [URL] = []
    let payload = Data("fake mp4 bytes".utf8).base64EncodedString()
    let uri = "data:video/mp4;base64,\(payload)"
    let video = try VLMRequestInference.decodeVideo(uri, tempFiles: &tempFiles)
    guard case .url(let url) = video else {
        Issue.record("expected .url, got \(video)")
        return
    }
    #expect(tempFiles == [url])
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(url.pathExtension == "mp4")
    let written = try Data(contentsOf: url)
    #expect(String(data: written, encoding: .utf8) == "fake mp4 bytes")
    // cleanup (production code removes these when the stream ends)
    try? FileManager.default.removeItem(at: url)
}

@Test("decodeVideo rejects an http:// URI with invalidURL (no SSRF)")
func vlmDecodeVideoHTTPRejected() {
    var tempFiles: [URL] = []
    expectInvalidURL("https://example.com/clip.mp4") {
        _ = try VLMRequestInference.decodeVideo(
            "https://example.com/clip.mp4", tempFiles: &tempFiles)
    }
    // A rejected URI must not have spawned a temp file.
    #expect(tempFiles.isEmpty)
}

@Test("decodeVideo rejects a file:// URI with invalidURL (no local-file read)")
func vlmDecodeVideoFileRejected() {
    var tempFiles: [URL] = []
    expectInvalidURL("file:///etc/passwd") {
        _ = try VLMRequestInference.decodeVideo(
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
func vlmBuildUserInputTextAndImage() throws {
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

    let userInput = try VLMRequestInference.buildUserInput(from: request)

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
func vlmBuildUserInputTextOnly() throws {
    let request = OpenAIChatCompletionRequest(
        model: "vlm",
        messages: [.init(role: .user, content: .text("just text"))])

    let userInput = try VLMRequestInference.buildUserInput(from: request)
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
