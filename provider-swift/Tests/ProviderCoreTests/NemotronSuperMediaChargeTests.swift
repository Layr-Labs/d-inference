// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation
import MLXVLM
import Testing
@testable import ProviderCore

/// The serving policy's media charge against the image binding's own quotes:
/// CPU-only, container headers only (no raster is decoded).
struct NemotronSuperMediaChargeTests {
    private typealias Policy = NemotronSuperServingPolicy
    private typealias Binding = NemotronSuperLocalImageBinding

    /// A baseline greyscale JPEG container: frame, one empty scan, EOI.
    private static func jpeg(width: Int, height: Int) -> Data {
        Data([0xff, 0xd8, 0xff, 0xc0, 0, 11, 8, UInt8(height >> 8), UInt8(height & 0xff),
              UInt8(width >> 8), UInt8(width & 0xff), 1, 1, 0x11, 0,
              0xff, 0xda, 0, 8, 1, 1, 0, 0, 63, 0, 0xff, 0xd9])
    }

    private static func body(_ images: [Data]) throws -> Data {
        let parts = images.map {
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + $0.base64EncodedString()]]
        }
        return try JSONSerialization.data(withJSONObject: [
            "model": Policy.modelID, "messages": [["role": "user", "content": parts]]])
    }

    @Test func largestGridAndLimitsAreTheBindingsOwn() throws {
        let grid = try #require(Policy.largestImageGrid)
        #expect(grid.heightPatches * grid.widthPatches == 13_312 && grid.tokens == 3_328)
        // Preprocessing admits no larger grid, whatever the shape; extreme
        // aspect ratios are refused outright.
        var admitted = 0
        for (width, height) in [(4_000, 3_000), (65_500, 1_024), (512, 131_072), (16_384, 16_384), (2_049, 1_665)] {
            guard let other = try? NemotronSuperImagePreprocessing.grid(width: width, height: height) else { continue }
            admitted += 1
            #expect(other.heightPatches * other.widthPatches <= 13_312, "\(width)x\(height)")
        }
        #expect(admitted >= 3)
        #expect(throws: Binding.Failure.capacity) {
            try Binding.encodedHeaderQuote(bodyBytes: Policy.maximumEncodedBodyBytes + 1,
                                           templateBytes: Policy.pinnedTemplateBytes)
        }
        #expect(throws: Binding.Failure.invalidInput) {
            try Binding.encodedPlan(Array(repeating: Data([0]), count: Policy.maximumImages + 1),
                                    contextLength: Policy.contextTokens)
        }
        let template = try #require(Data(base64Encoded: superImagePinnedTemplateBase64,
                                        options: .ignoreUnknownCharacters))
        #expect(template.count == Policy.pinnedTemplateBytes)
        #expect(SHA256.hash(data: template).map { String(format: "%02x", $0) }.joined()
            == NemotronSuperPromptContract.templateSHA256)
    }

    @Test func decodeBoundCoversTheLargestAdmittedRasters() throws {
        // Workspace above the two encoded copies, which are charged per request.
        func workspace(_ data: Data) throws -> UInt64 {
            let quote = try NemotronSuperImageDecode.inspect(data, orientation: .applyEXIF, maxPixels: .max)
            return UInt64(quote.normalizationWorkspaceBytes - 2 * data.count)
        }
        let png = SuperImageTestPNG.image(width: 512, height: 131_072, colorType: 2, depth: 8)
        let candidates = [Self.jpeg(width: 8_192, height: 8_192), Self.jpeg(width: 1_024, height: 65_500),
                          Self.jpeg(width: 1_032, height: 65_000), png]
        let largest = try candidates.map(workspace).max() ?? 0
        #expect(largest <= Policy.maximumImageDecodeBytes)
        // Exact up to the unattainable pairing of the pixel and axis ceilings.
        #expect(Policy.maximumImageDecodeBytes - largest < 1 << 20)
        #expect(Policy.maximumImageDecodeBytes == 1_358_949_888)
        // The ceilings themselves: pixels, JPEG and PNG axes.
        for refused in [Self.jpeg(width: 8_193, height: 8_192), Self.jpeg(width: 1_024, height: 65_501),
                        SuperImageTestPNG.image(width: 1, height: 131_073, colorType: 2, depth: 8)] {
            #expect(throws: NemotronSuperImageDecode.Failure.sizeLimit) {
                try NemotronSuperImageDecode.inspect(refused, orientation: .applyEXIF, maxPixels: .max)
            }
        }
    }

    @Test func gridChargesMatchTheBindingsPlanExactly() throws {
        let image = Self.jpeg(width: 2_048, height: 1_664)
        let plan = try Binding.encodedPlan([image], contextLength: Policy.contextTokens)
        let grid = try #require(Policy.largestImageGrid)
        #expect(plan.grids == [grid])
        let decode = UInt64(try NemotronSuperImageDecode.inspect(image, orientation: .applyEXIF)
            .normalizationWorkspaceBytes)
        let activation = try Binding.towerActivationBytes([(grid.heightPatches, grid.widthPatches)])
        #expect(plan.totalBytes == decode + UInt64(grid.tokens) * Policy.mediaBytesPerVisualToken + activation)
        #expect(activation == 2_095_272_960 && Policy.mediaBytesPerVisualToken == 40_960)
    }

    @Test func chargeBoundsEveryAdmittedRequest() throws {
        #expect(Policy.mediaChargeBytes(imageCount: 0) == nil)
        #expect(Policy.mediaChargeBytes(imageCount: Policy.maximumImages + 1) == nil)
        #expect(Policy.mediaChargeBytes(imageCount: 1) == 3_888_385_020)
        #expect(Policy.mediaChargeBytes(imageCount: 16) == 26_317_356_540)
        // Sixteen largest grids (53,248 visual tokens) fit the served context,
        // so every image adds its workspace and all 3,328 of its tokens.
        #expect(16 * 3_328 < Policy.contextTokens)
        let four = try #require(Policy.mediaChargeBytes(imageCount: 4))
        let five = try #require(Policy.mediaChargeBytes(imageCount: 5))
        #expect(five - four == Policy.maximumImageDecodeBytes + 3_328 * Policy.mediaBytesPerVisualToken)
        // Both of the binding's reservations for real bodies stay inside it.
        for count in [1, 4] {
            let images = Array(repeating: Self.jpeg(width: 2_048, height: 1_664), count: count)
            let body = try Self.body(images)
            let ingress = try Binding.encodedHeaderQuote(bodyBytes: body.count, templateBytes: Policy.pinnedTemplateBytes)
            let parsed = try Binding.parseEncodedBody(body, modelID: Policy.modelID)
            let plan = try Binding.encodedPlan(parsed.images, contextLength: Policy.contextTokens)
            #expect(ingress + plan.totalBytes <= (Policy.mediaChargeBytes(imageCount: count) ?? 0), "\(count)")
        }
    }
}
