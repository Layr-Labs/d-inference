// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMServer
import ProviderCoreFoundation
import Testing

@testable import ProviderCore

/// The media gate's charge for a Muse Glimmer image request: every image at
/// its ceiling (4,098 prompt tokens and a full-size tower run), whatever its
/// size, before any byte of it is decoded.
@Suite("Muse Glimmer vision budget")
struct MuseGlimmerVisionBudgetTests {
    typealias Budget = MuseGlimmerVisionBudget

    static func request(images: Int, text: String = "", maxTokens: Int? = 512) throws -> OpenAIChatCompletionRequest {
        var parts: [[String: Any]] = [["type": "text", "text": text]]
        for _ in 0 ..< images {
            parts.append(["type": "image_url", "image_url": ["url": "data:image/png;base64,AAAA"]])
        }
        var body: [String: Any] = [
            "model": MuseGlimmerModelPolicy.catalogModelID,
            "messages": [["role": "user", "content": parts]],
        ]
        if let maxTokens { body["max_tokens"] = maxTokens }
        return try ProviderLoop.decodeOpenAIRequest(
            try JSONSerialization.data(withJSONObject: body), modelType: MuseGlimmerModelPolicy.modelType)
    }

    @Test("image parts are counted across messages")
    func imageCount() throws {
        #expect(Budget.imageCount(try Self.request(images: 0)) == 0)
        #expect(Budget.imageCount(try Self.request(images: 3)) == 3)
        var request = try Self.request(images: 2)
        request.messages += try Self.request(images: 1).messages
        #expect(Budget.imageCount(request) == 3)
    }

    @Test("a text request is charged nothing beyond the generic projection")
    func textRequest() throws {
        let request = try Self.request(images: 0, text: String(repeating: "a", count: 400))
        let reservation = Budget.reservation(request: request, defaultMaxTokens: 1_000, contextLength: 0)
        #expect(reservation.bytes == 0)
        #expect(reservation.kvTokens
            == MediaIngest.projectedKVTokens(request, defaultMaxTokens: 1_000, contextLength: 0))
    }

    @Test("every image is reserved at its 4,098-token ceiling")
    func imageCeiling() throws {
        for images in 1 ... 4 {
            let request = try Self.request(images: images, text: "Describe.", maxTokens: 512)
            let reservation = Budget.reservation(request: request, defaultMaxTokens: 1_000, contextLength: 0)
            let text = try Self.request(images: 0, text: "Describe.", maxTokens: 512)
            let textTokens = MediaIngest.projectedKVTokens(text, defaultMaxTokens: 1_000, contextLength: 0)
            // Never under: text + output + 4,098 per image, exactly.
            #expect(reservation.kvTokens == textTokens + images * MuseGlimmerVisionPolicy.maximumPromptTokensPerImage)
            #expect(reservation.kvTokens > MediaIngest.projectedKVTokens(
                request, defaultMaxTokens: 1_000, contextLength: 0))
        }
    }

    @Test("the reservation never exceeds the context plus the output")
    func contextClamp() throws {
        let request = try Self.request(images: 8, maxTokens: 512)
        let reservation = Budget.reservation(request: request, defaultMaxTokens: 1_000, contextLength: 16_384)
        #expect(reservation.kvTokens == 16_384 + 512)
        let roomy = Budget.reservation(request: request, defaultMaxTokens: 1_000, contextLength: 131_072)
        #expect(roomy.kvTokens == 8 * 4_098 + 512)
        // Without max_tokens, the slot's default output is charged.
        let open = try Self.request(images: 1, maxTokens: nil)
        #expect(Budget.reservation(request: open, defaultMaxTokens: 2_000, contextLength: 0).kvTokens == 4_098 + 2_000)
    }

    @Test("bytes: one full-size tower run plus every image's features")
    func bytes() throws {
        #expect(Budget.featureBytes(images: 1) == 4_096 * 6_656 * 2)
        #expect(Budget.featureBytes(images: 3) == 3 * 54_525_952)
        #expect(Budget.featureBytes(images: -1) == 0)
        // The analytic bound at 16,384 patches (each term at 4 bytes): 2.76 GiB.
        #expect(Budget.towerWorkingSetBytes() == 2_965_372_928)
        #expect(Budget.towerWorkingSetBytes(patches: 0) == 0)
        #expect(Budget.towerWorkingSetBytes(patches: 1_024) < Budget.towerWorkingSetBytes())
        for images in [1, 2, 8] {
            let reservation = Budget.reservation(
                request: try Self.request(images: images), defaultMaxTokens: 1_000, contextLength: 0)
            #expect(reservation.bytes == Budget.towerWorkingSetBytes() + Budget.featureBytes(images: images))
        }
    }

    @Test("the widths are the pinned stack's")
    func widths() {
        #expect(Budget.maximumPatches == 16_384)
        #expect(Budget.mergedWidth == Budget.visionHidden * 4)
        #expect(Budget.featureWidth == 6_656)
    }
}
