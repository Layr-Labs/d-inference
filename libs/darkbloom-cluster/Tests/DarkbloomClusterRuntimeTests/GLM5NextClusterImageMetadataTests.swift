import Foundation
import CoreGraphics
import ImageIO
import DarkbloomClusterProtocol
import MLXLLM
import MLXVLM
import Testing
@testable import DarkbloomClusterRuntime

/// CPU metadata only: no MLXArray, model, tensor payload or device query.
@Suite("GLM cluster bounded still-image metadata")
struct GLM5NextClusterImageMetadataTests {
    private func png(width: Int = 28, height: Int = 28) throws -> Data {
        let bytes = [UInt8](repeating: 127, count: width * height * 4)
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
    @Test func pngGeometryIsBoundedAndDecodedWithIdenticalResizePlan() throws {
        let fixture = try GLM5NextMetadataTestFixture(layers: 8)
        let bytes = try png()
        let i = try GLM5NextClusterImagePlan.inspectPNG(bytes, configuration: fixture.configuration)
        #expect(i.width == 28 && i.height == 28)
        #expect(try i.resize.grid.featureCount() <= ClusterStillImages.maximumFeatures)
        #expect(i.patchBytes > 0 && i.hostWorkingBytes >= i.patchBytes)
        let rgb = try GLM5NextClusterImagePlan.decodePNG(bytes, inspection: i, configuration: fixture.configuration)
        #expect(rgb.width == 28 && rgb.height == 28 && rgb.pixels.count == 28 * 28 * 3)
        #expect(rgb.pixels.allSatisfy { $0 == 127 })
        #expect(throws: (any Error).self) {
            _ = try GLM5NextClusterImagePlan.inspectPNG(Data(bytes.dropLast()), configuration: fixture.configuration)
        }
        #expect(throws: (any Error).self) {
            _ = try GLM5NextClusterImagePlan.inspectPNG(bytes + Data([0]), configuration: fixture.configuration)
        }
        #expect(throws: (any Error).self) {
            _ = try GLM5NextClusterImagePlan.inspectPNG(Data(repeating: 0, count: 96 * 1024 + 1), configuration: fixture.configuration)
        }
    }
    @Test func animationChunkAndSourcePixelOverflowRefuseBeforeRasterDecode() throws {
        let c = try GLM5NextMetadataTestFixture(layers: 8).configuration
        let bytes = try png()
        // Inject an APNG control chunk after IHDR. Even when ImageIO reports
        // one image, the explicit animation marker must refuse.
        var animated = Data(bytes.prefix(33))
        animated.append(contentsOf: [0,0,0,8,97,99,84,76,0,0,0,1,0,0,0,0,0,0,0,0])
        animated.append(bytes.dropFirst(33))
        #expect(throws: (any Error).self) { _ = try GLM5NextClusterImagePlan.inspectPNG(animated, configuration: c) }
        let large = try png(width: 1025, height: 1024)
        #expect(throws: (any Error).self) { _ = try GLM5NextClusterImagePlan.inspectPNG(large, configuration: c) }
    }
    @Test func towerOwnershipAndConstructionCopiesAreRankZeroOnly() throws {
        let f = try GLM5NextMetadataTestFixture(layers: 8)
        func quote(_ rank: Int, _ vision: Bool) throws -> GLM5NextStageLoadResources {
            try .init(inventory: f.inventory, stageIndex: rank, cut: 3, includeMTP: false,
                executionPolicy: .reference, metadataAllowanceBytes: 1024,
                maximumBufferBytes: Int.max, allocationBound: { $0 }, includeVision: vision)
        }
        let text = try quote(0, false), first = try quote(0, true), last = try quote(1, true)
        let vision = f.inventory.bytes(in: .vision)
        #expect(first.summary.selectedStoredBytes == text.summary.selectedStoredBytes + vision)
        #expect(first.summary.sourceAllocationBoundBytes == text.summary.sourceAllocationBoundBytes + vision)
        #expect(first.summary.nativeConstructionAllowanceBytes == text.summary.nativeConstructionAllowanceBytes + 3 * vision)
        #expect(first.summary.deferredVisionStoredBytes == 0)
        #expect(last.selected.keys.allSatisfy { f.inventory.entries[$0]!.part != .vision })
        #expect(first.selected.keys.contains { f.inventory.entries[$0]!.part == .vision })
        #expect(first.summary.selectedStoredBytes + last.summary.selectedStoredBytes == f.inventory.bytes(in: .text) + vision)
    }
    @Test func mediaWorkspaceQuotesHostOnBothRanksAndNativeOnlyOnProducer() throws {
        let c = try GLM5NextMetadataTestFixture(layers: 8).configuration
        let first = try GLM5NextImageBudget.bytes(configuration: c, rank: 0, chunk: 8, native: { $0 }, host: { $0 })
        let last = try GLM5NextImageBudget.bytes(configuration: c, rank: 1, chunk: 8, native: { $0 }, host: { $0 })
        #expect(first.native > GLM5NextImageBudget.conservativeNativeScratchBytes)
        #expect(last.native == 0 && last.host > 0 && first.host > last.host)
        #expect(throws: (any Error).self) {
            _ = try GLM5NextImageBudget.bytes(configuration: c, rank: 0, chunk: Int.max, native: { $0 }, host: { $0 })
        }
        #expect(throws: (any Error).self) {
            _ = try GLM5NextImageBudget.bytes(configuration: c, rank: 0, chunk: 8, native: { _ in Int.max }, host: { $0 })
        }
        #expect(throws: (any Error).self) {
            _ = try GLM5NextImageBudget.bytes(configuration: c, rank: 0, chunk: 8, native: { $0 - 1 }, host: { $0 })
        }
    }
}
