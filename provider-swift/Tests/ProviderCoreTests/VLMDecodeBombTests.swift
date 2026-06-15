import Compression
import CoreImage
import Foundation
import ImageIO
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

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
enum PNGBomb {
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

// MARK: - Test helper

/// Assert `body` threw `MediaError.mediaTooLarge` (file-local copy; the sibling
/// test file's helper is `private`). `MediaError` is not `Equatable`, so we
/// pattern-match the case rather than comparing values.
private func expectMediaTooLarge(
    _ body: () async throws -> Void
) async {
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
    #expect(VLMRequestInference.imagePixelCount(data) == 4_000_000)
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
        _ = try VLMRequestInference.decodeImage(uri, maxImagePixels: 1_000_000)
    }
}

@Test("decodeImage accepts the same bomb when its pixels are within the cap (no regression)")
func vlmDecodeImageAcceptsBombWithinCap() throws {
    // The bomb is a genuine PNG; with a cap above its pixel count it decodes
    // normally — proving the reject is about size, not a malformed-file false
    // positive. 2000x2000 = 4 Mpx, decodes to ~16 MB (CI-affordable).
    let uri = PNGBomb.dataURI(width: 2000, height: 2000)
    let image = try VLMRequestInference.decodeImage(uri, maxImagePixels: 8_000_000)
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
        _ = try await VLMRequestInference.buildUserInput(
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
        try await VLMRequestInference.validateMedia(request, maxImagePixels: 1_000_000)
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
    try await VLMRequestInference.validateMedia(request)
}
