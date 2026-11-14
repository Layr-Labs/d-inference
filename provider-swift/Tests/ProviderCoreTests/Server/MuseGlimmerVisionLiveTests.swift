// Copyright © 2026 Eigen Labs.

import CoreGraphics
import CoreImage
import CoreText
import Foundation
import MLXLMServer
import MLXVLM
import ProviderCoreFoundation
import Testing

@testable import ProviderCore

/// Opt-in real weights: Muse Glimmer image input through a production slot
/// and loopback HTTP, as `MuseGlimmerLiveTests` serves text. Run it only
/// while holding this Mac's GPU lane; nothing here takes the lane itself.
///
///   DARKBLOOM_MUSE_GLIMMER_VISION_LIVE=1
///   DARKBLOOM_MUSE_GLIMMER_HUB, DARKBLOOM_MUSE_GLIMMER_METALLIB,
///   DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL=1, DARKBLOOM_PREFIX_CACHE_TEST_ROOT
///                                            (as `MuseGlimmerLiveTests`)
///   DARKBLOOM_MUSE_GLIMMER_VISION=1          (optional: the provider's image switch)
///   DARKBLOOM_MUSE_GLIMMER_RECEIPTS=<file>   (optional: one JSON line per request)
///   DARKBLOOM_MUSE_GLIMMER_DRAFTER=<dir>     (optional: the pinned drafter)
///   DARKBLOOM_MUSE_GLIMMER_REFERENCE=<receipts of an earlier run>   (optional)
///   DARKBLOOM_MUSE_GLIMMER_ZEBRA=<photo of a zebra>                  (optional)
///   DARKBLOOM_MUSE_GLIMMER_RECEIPT_MAX_CER=<fraction>                (default 0.05)
///
/// Three runs make the proofs:
/// 1. switch off: the text cases, and every image refused with its reason;
/// 2. switch on, reference = run 1: the image cases, and the text cases
///    unchanged with vision on;
/// 3. switch on with the drafter, reference = run 2: every case, images and
///    a text row batched beside an image row included, equal drafter on and off.
///
/// The image cases are the SDK's image proofs (`MuseGlimmerImageProofTests`):
/// the same drawn receipt, swatch card and circle, the same questions and
/// greedy decoding, sent as PNG data URLs.
@Suite("Muse Glimmer image input over loopback HTTP", .serialized)
struct MuseGlimmerVisionLiveTests {
    static let modelID = MuseGlimmerModelPolicy.localModelID
    static let environment = ProcessInfo.processInfo.environment

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_MUSE_GLIMMER_VISION_LIVE"] == "1"))
    func imagesThroughLoopback() async throws {
        let env = Self.environment
        let vision = MuseGlimmerVisionPolicy.isSwitchedOn(environment: env)
        _ = try #require(bindRuntimeMetallibForMLX(
            from: env["DARKBLOOM_MUSE_GLIMMER_METALLIB"].map { URL(fileURLWithPath: $0) }),
            "set DARKBLOOM_MUSE_GLIMMER_METALLIB to the staged mlx.metallib")
        let root = try #require(env["DARKBLOOM_MUSE_GLIMMER_HUB"])
        let previous = ModelScanner.configuredCacheDirectory
        ModelScanner.configureCacheDirectory(root)
        defer { ModelScanner.configureCacheDirectory(previous) }
        try #require(SSDPrefixCacheFactory.isolatedTestRoot(environment: env) != nil,
            "set DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL=1 and DARKBLOOM_PREFIX_CACHE_TEST_ROOT")
        try #require(SSDPrefixCacheFactory.forceEphemeralKey(environment: env),
            "this run must not load a persistent cache key")

        let id = Self.modelID
        let directory = try #require(ModelScanner.resolveLocalPath(modelID: id))
        let model = try #require(ModelScanner.parseModelInfo(snapshotDir: directory, modelName: id))
        try #require(model.modelType == MuseGlimmerModelPolicy.modelType)
        // Advertised exactly when the switch is on and the artifact is the pinned one.
        #expect(model.isVision == (vision ? true : nil))

        let port = UInt16(env["DARKBLOOM_MUSE_GLIMMER_PORT"] ?? "19132") ?? 19132
        let token = UUID().uuidString + UUID().uuidString
        let drafter = env["DARKBLOOM_MUSE_GLIMMER_DRAFTER"].flatMap { $0.isEmpty ? nil : $0 }
        let reference = try env["DARKBLOOM_MUSE_GLIMMER_REFERENCE"].map {
            try MuseGlimmerLiveClient.receipts(URL(fileURLWithPath: $0))
        }
        let server = StandaloneServer(config: .init(port: port, host: "127.0.0.1", authToken: token,
            mtpMode: drafter == nil ? .off : .auto, mtpDrafterPath: drafter,
            coordinatorURL: "http://127.0.0.1:1"), models: [model])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1800
        configuration.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let receipt = env["DARKBLOOM_MUSE_GLIMMER_RECEIPTS"].map { URL(fileURLWithPath: $0) }
        if let receipt { try Data().write(to: receipt) }
        let client = MuseGlimmerLiveClient(port: port, token: token, session: session, receipt: receipt)

        try await server.start()
        do {
            try #require(await server.waitUntilBound(timeoutSeconds: 10))
            try client.record(MuseGlimmerLiveClient.memory("before-load"))
            try await server.ensureModelLoaded(id)
            try client.record(MuseGlimmerLiveClient.memory("after-load"))
            let bridge = try #require(await server.slots[id]?.bridge)
            let mtp = await bridge.mtpStatusSnapshot()
            try client.record(["case": "slot", "vision_switch": vision, "is_vision": model.isVision ?? false,
                               "drafter_directory": drafter ?? "none", "mtp_active": mtp.active])
            if drafter != nil { try #require(mtp.active, "the drafter did not activate") }

            try await Self.text(client)
            try await Self.refusals(client, vision: vision)
            if vision {
                try await Self.images(client)
                try await Self.batched(client)
                try await Self.cacheScope(client)
            }
            if let reference, let receipt {
                try MuseGlimmerLiveTests.compare(receipt: receipt, reference: reference, client: client)
            }
        } catch {
            await server.stopAndWait()
            throw error
        }
        await server.stopAndWait()
    }

    // MARK: - Requests

    static func chat(_ content: Any, maxTokens: Int = 512) -> [String: Any] {
        ["model": modelID, "messages": [["role": "user", "content": content]], "max_tokens": maxTokens,
         "temperature": 0]
    }

    static func imagePart(_ image: CIImage) throws -> [String: Any] {
        let context = CIContext()
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let png = try #require(context.pngRepresentation(of: image, format: .RGBA8, colorSpace: space))
        return ["type": "image_url", "image_url": ["url": "data:image/png;base64," + png.base64EncodedString()]]
    }

    static func parts(_ images: [CIImage], _ question: String) throws -> [[String: Any]] {
        try images.map(imagePart) + [["type": "text", "text": question]]
    }

    static let textCases: [(String, String)] = [
        ("text-arithmetic", "What is 17 times 23? Answer with the number."),
        ("text-capital", "Name the capital of Australia. One word."),
    ]

    /// Run 1 and run 2 compare these: vision on leaves text unchanged.
    static func text(_ client: MuseGlimmerLiveClient) async throws {
        for (name, question) in textCases {
            let result = try await client.stream(chat(question, maxTokens: 1024), name: name)
            #expect(result.status == 200, "\(name): \(result.body.prefix(400))")
            #expect(result.cachedTokens >= 0)
        }
    }

    /// A typed 400. The wire carries the closed code and its fixed message,
    /// never the refusal's reason text (that stays in this Mac's log), so the
    /// code is what a client can tell apart.
    static func expectRefused(
        _ client: MuseGlimmerLiveClient, _ body: [String: Any], name: String, code: String? = nil
    ) async throws {
        let (status, data) = try await client.post(body, name: name)
        let text = String(decoding: data, as: UTF8.self)
        #expect(status == 400, "\(name): \(status) \(text.prefix(400))")
        let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
        #expect(error?["message"] is String, "\(name): \(text.prefix(400))")
        if let code { #expect(error?["code"] as? String == code, "\(name): \(text.prefix(400))") }
    }

    /// Typed 400s, never a 5xx: every one is decided before any tower work.
    static func refusals(_ client: MuseGlimmerLiveClient, vision: Bool) async throws {
        let receipt = try imagePart(MuseGlimmerVisionProofImages.receipt())
        if !vision {
            try await expectRefused(client, chat([receipt, ["type": "text", "text": "Read it."]]),
                name: "refused-switched-off", code: "unsupported_media")
        }
        let video: [String: Any] = ["type": "video_url", "video_url": ["url": "data:video/mp4;base64,AAAA"]]
        try await expectRefused(client, chat([video, ["type": "text", "text": "Describe it."]]),
            name: "refused-video", code: "unsupported_media")
        // Remote URLs are never fetched.
        let remote: [String: Any] = ["type": "image_url", "image_url": ["url": "https://example.com/zebra.png"]]
        try await expectRefused(client, chat([remote, ["type": "text", "text": "Describe it."]]),
            name: "refused-remote-url")
        if vision {
            let assistant: [String: Any] = [
                "model": modelID, "max_tokens": 32,
                "messages": [
                    ["role": "user", "content": "Show me."],
                    ["role": "assistant", "content": [receipt]],
                    ["role": "user", "content": "What was that?"],
                ],
            ]
            try await expectRefused(client, assistant, name: "refused-assistant-image")
            try await expectRefused(
                client, chat(try parts(Array(repeating: MuseGlimmerVisionProofImages.circle(), count: 9), "Count them.")),
                name: "refused-too-many-images")
        }
    }

    /// The SDK proofs' cases, through the provider.
    static func images(_ client: MuseGlimmerLiveClient) async throws {
        let receipt = MuseGlimmerVisionProofImages.receipt()
        let swatches = MuseGlimmerVisionProofImages.swatchCard()
        var third = MuseGlimmerVisionProofImages.circle()
        if let path = environment["DARKBLOOM_MUSE_GLIMMER_ZEBRA"] {
            let photo = try #require(CIImage(contentsOf: URL(fileURLWithPath: path)))
            for (name, width, height) in [("zebra-448", 448, 448), ("zebra-1920x1080", 1920, 1080)] {
                let result = try await client.stream(
                    chat(try parts([MuseGlimmerVisionProofImages.fill(photo, width, height)], "What animal is this? One word.")),
                    name: name)
                #expect(result.status == 200, "\(name): \(result.body.prefix(400))")
                #expect(result.content.lowercased().contains("zebra"), "\(name): \(result.content)")
            }
            third = MuseGlimmerVisionProofImages.fill(photo, 448, 448)
        } else {
            try client.record(["case": "zebra", "skipped": "DARKBLOOM_MUSE_GLIMMER_ZEBRA is not set"])
        }

        let transcription = try await client.stream(chat(try parts([receipt],
            "Transcribe this receipt exactly, one printed line per line, top to bottom. "
                + "Put each item and its price on one line separated by a single space. "
                + "Output only the transcription."), maxTokens: 2048), name: "receipt")
        #expect(transcription.status == 200, "receipt: \(transcription.body.prefix(400))")
        // 640 x 900 is a 32 x 23 grid: 736 patches and two framing tokens.
        #expect(transcription.promptTokens > 738)
        let report = MuseGlimmerVisionProofImages.receiptReport(transcription.content)
        let maximum = Double(environment["DARKBLOOM_MUSE_GLIMMER_RECEIPT_MAX_CER"] ?? "") ?? 0.05
        try client.record(["case": "receipt-report", "cer": report.cer, "exact_lines": report.exact,
                           "of": MuseGlimmerVisionProofImages.receiptLines.count, "missing": report.missing,
                           "max_cer": maximum])
        #expect(report.cer <= maximum, "receipt CER \(report.cer): missing \(report.missing)")
        #expect(!report.missing.contains("Total 36.71"))

        let question = "Answer in three lines. 1. Which image (first, second or third) shows a receipt? "
            + "2. What is the receipt's total? 3. On the card of four numbered colour swatches, "
            + "what colour is swatch 3?"
        for (name, images, position) in [("multi-a", [third, receipt, swatches], "second"),
                                         ("multi-b", [receipt, swatches, third], "first")] {
            let result = try await client.stream(chat(try parts(images, question)), name: name)
            #expect(result.status == 200, "\(name): \(result.body.prefix(400))")
            let answer = result.content.lowercased()
            #expect(answer.contains(position), "\(name): \(result.content)")
            #expect(answer.contains("36.71"), "\(name): \(result.content)")
            #expect(answer.contains("blue"), "\(name): \(result.content)")
        }
    }

    /// A text row and an image row in one batch: with the drafter on, the
    /// text row may draft and the image row may not; both must match run 2.
    static func batched(_ client: MuseGlimmerLiveClient) async throws {
        let image = chat(try parts([MuseGlimmerVisionProofImages.swatchCard()], "List the four swatch colours in order."))
        let text = chat("Write the first ten prime numbers, comma separated.", maxTokens: 256)
        async let imageRow = client.stream(image, name: "batch-image")
        async let textRow = client.stream(text, name: "batch-text")
        let (imageResult, textResult) = try await (imageRow, textRow)
        #expect(imageResult.status == 200 && textResult.status == 200)
        #expect(textResult.content.contains("29"), "batch-text: \(textResult.content)")
    }

    /// Image prompts never reuse or publish the prefix cache.
    static func cacheScope(_ client: MuseGlimmerLiveClient) async throws {
        let body = chat(try parts([MuseGlimmerVisionProofImages.circle()], "What shape is this? One word."), maxTokens: 256)
        let first = try await client.stream(body, name: "cache-image-first")
        let second = try await client.stream(body, name: "cache-image-repeat")
        #expect(first.status == 200 && second.status == 200)
        #expect(first.cachedTokens == 0 && second.cachedTokens == 0)
    }
}

/// The SDK image proofs' drawn inputs (`MuseGlimmerImageRealTests` in the SDK).
enum MuseGlimmerVisionProofImages {
    static let receiptLines = [
        "FERN & FOUNDRY MARKET", "2026-11-14", "Oat milk 1L 3.49", "Sourdough loaf 5.25",
        "Free-range eggs x12 6.80", "Green apples 1kg 4.10", "Dark chocolate 2.95",
        "Coffee beans 250g 11.40", "Subtotal 33.99", "Tax 8% 2.72", "Total 36.71",
    ]
    /// Swatches 1 to 4, left to right.
    static let swatches: [(red: CGFloat, green: CGFloat, blue: CGFloat)] = [
        (0.86, 0.1, 0.1), (0.1, 0.62, 0.2), (0.1, 0.25, 0.86), (0.96, 0.84, 0.1),
    ]

    static func canvas(width: Int, height: Int, _ draw: (CGContext) -> Void) -> CIImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(context)
        return CIImage(cgImage: context.makeImage()!)
    }

    static func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat, in context: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes)), context)
    }

    /// 640 x 900: item name left, price right, one line each.
    static func receipt() -> CIImage {
        canvas(width: 640, height: 900) { context in
            var y: CGFloat = 830
            for (index, line) in receiptLines.enumerated() {
                let size: CGFloat = index == 0 ? 34 : 28
                if let split = line.lastIndex(of: " "), index >= 2 {
                    text(String(line[..<split]), x: 40, y: y, size: size, in: context)
                    text(String(line[line.index(after: split)...]), x: 500, y: y, size: size, in: context)
                } else {
                    text(line, x: 40, y: y, size: size, in: context)
                }
                y -= index == 1 || index == 7 ? 90 : 62
            }
        }
    }

    /// 800 x 300: four squares, each numbered 1 to 4 below it.
    static func swatchCard() -> CIImage {
        canvas(width: 800, height: 300) { context in
            for (index, swatch) in swatches.enumerated() {
                let x = CGFloat(40 + index * 190)
                context.setFillColor(CGColor(red: swatch.red, green: swatch.green, blue: swatch.blue, alpha: 1))
                context.fill(CGRect(x: x, y: 90, width: 150, height: 170))
                text("\(index + 1)", x: x + 64, y: 30, size: 40, in: context)
            }
        }
    }

    /// 600 x 600: one black circle.
    static func circle() -> CIImage {
        canvas(width: 600, height: 600) { context in
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fillEllipse(in: CGRect(x: 100, y: 100, width: 400, height: 400))
        }
    }

    /// `image` centre-cropped to the aspect of `width x height`, then scaled to it.
    static func fill(_ image: CIImage, _ width: Int, _ height: Int) -> CIImage {
        let extent = image.extent
        let aspect = CGFloat(width) / CGFloat(height)
        var crop = extent
        if extent.width / extent.height > aspect {
            crop.size.width = extent.height * aspect
            crop.origin.x += (extent.width - crop.width) / 2
        } else {
            crop.size.height = extent.width / aspect
            crop.origin.y += (extent.height - crop.height) / 2
        }
        let cropped = image.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        return MediaProcessing.resampleLanczos(cropped, to: CGSize(width: width, height: height))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// Character error rate of a transcription against the receipt, over
    /// whitespace-normalized lines (the SDK proofs' `compare_proofs.py`).
    static func receiptReport(_ answer: String) -> (cer: Double, exact: Int, missing: [String]) {
        let lines = answer.replacingOccurrences(of: "\r", with: "").split(separator: "\n").compactMap { raw -> String? in
            var line = raw.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") || line.hasPrefix("* ") { line.removeFirst(2) }
            return line.isEmpty ? nil : line
        }
        let truth = Array(receiptLines.joined(separator: "\n"))
        let got = Array(lines.joined(separator: "\n"))
        var previous = Array(0 ... got.count)
        for (i, x) in truth.enumerated() {
            var current = [i + 1]
            for (j, y) in got.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (x == y ? 0 : 1)))
            }
            previous = current
        }
        let missing = receiptLines.filter { !lines.contains($0) }
        return (Double(previous[got.count]) / Double(truth.count), receiptLines.count - missing.count, missing)
    }
}
