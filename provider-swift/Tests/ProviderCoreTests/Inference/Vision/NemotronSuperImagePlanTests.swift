// Copyright © 2026 Eigen Labs.
import Foundation
import MLX
import MLXLMCommon
@testable import MLXVLM
import Testing
@testable import ProviderCore

/// What the encoded image route refuses before reserving or decoding.
struct NemotronSuperImagePlanTests {
    private typealias Binding = NemotronSuperLocalImageBinding

    /// A baseline greyscale JPEG container (frame, one empty scan, EOI): ImageIO cannot decode it.
    private static func jpeg(width: Int, height: Int) -> Data {
        Data([0xff, 0xd8, 0xff, 0xc0, 0, 11, 8, UInt8(height >> 8), UInt8(height & 0xff),
              UInt8(width >> 8), UInt8(width & 0xff), 1, 1, 0x11, 0,
              0xff, 0xda, 0, 8, 1, 1, 0, 0, 63, 0, 0xff, 0xd9])
    }

    /// An RGB PNG container whose IDAT inflates to one byte: its raster cannot decode.
    private static func png(width: Int, height: Int, before: [Data] = []) -> Data {
        SuperImageTestPNG.image(width: width, height: height, colorType: 2, depth: 8, rows: [[0]], before: before)
    }

    /// 8192 x 8192 is within the 64 Mi-pixel container limit and plans a
    /// 116 x 114 patch grid, but its resize workspace is above the SDK's
    /// 256 MiB. Neither container could decode, so the workspace refusal
    /// shows that no decode was attempted first.
    @Test func resizeWorkspaceIsRefusedFromTheContainer() throws {
        typealias Preprocessing = NemotronSuperImagePreprocessing
        for image in [Self.png(width: 8192, height: 8192), Self.jpeg(width: 8192, height: 8192)] {
            #expect(try NemotronSuperImageDecode.inspect(image, orientation: .applyEXIF).width == 8192)
            let grid = try Preprocessing.grid(width: 8192, height: 8192)
            #expect(grid.widthPatches == 116 && grid.heightPatches == 114)
            #expect(throws: Preprocessing.Failure.workspaceLimit) {
                try NemotronSuperImageDecode.plan(image, orientation: .applyEXIF, imageCount: 1)
            }
            #expect(throws: Preprocessing.Failure.workspaceLimit) {
                try Binding.encodedPlan([image], contextLength: NemotronSuperServingPolicy.contextTokens)
            }
            #expect(throws: Preprocessing.Failure.workspaceLimit) {
                try NemotronSuperImageDecode.prepare(image, orientation: .applyEXIF)
            }
        }
        // The limits quoted in the image format reference.
        let largest = try NemotronSuperImageDecode.plan(Self.png(width: 5751, height: 5751),
                                                        orientation: .applyEXIF, imageCount: 1)
        #expect(largest.grid.width == 1856 && largest.grid.height == 1824)
        for (width, height) in [(5752, 5752), (8064, 6048)] {
            #expect(throws: Preprocessing.Failure.workspaceLimit, "\(width)x\(height)") {
                try NemotronSuperImageDecode.plan(Self.jpeg(width: width, height: height),
                                                  orientation: .applyEXIF, imageCount: 1)
            }
        }
    }

    /// The grid and workspace use the size `normalizeRGB` receives: after the
    /// EXIF transpose.
    @Test func planUsesTheOrientedSize() throws {
        let exif = SuperImageTestPNG.chunk("eXIf", SuperImageTestPNG.tiff(orientation: 6))
        let plan = try NemotronSuperImageDecode.plan(Self.png(width: 4000, height: 100, before: [exif]),
                                                     orientation: .applyEXIF, imageCount: 1)
        #expect(plan.quote.width == 100 && plan.quote.height == 4000)
        #expect(plan.grid == (try NemotronSuperImagePreprocessing.grid(width: 100, height: 4000)))
        #expect(plan.grid != (try NemotronSuperImagePreprocessing.grid(width: 4000, height: 100)))
    }

    /// Through the owner's encoded route, with room for the request's ingress
    /// only: a media reservation attempt would fail (503) and arm the budget's
    /// rejection record. The refusal comes first, so neither happens.
    @Test(.timeLimit(.minutes(2))) func oversizeImageIsRefusedBeforeItsMediaReservation() async throws {
        let dimensions = NemotronRadioDimensions(width: 2, layers: 1, heads: 1,
            channels: 3, patch: 16, positionSide: 32, prefix: 1, mlpWidth: 3)
        let (installed, construction, residency) = try SuperInstalledFixture(radioDimensions: dimensions).make()
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: .max) })
        let lease = try #require(await budget.claimPendingLoad(requestID: "super-image-plan",
            weightBytes: UInt64(installed.receipt.payloadBytes), minimumKVBytes: 2 << 30))
        let owner = try await NemotronSuperLocalBridgeBuilder.make(installed: installed,
            tokenizer: TokenizerHandle(SuperSyntheticImageTokenizer()), eosTokenIDs: [31],
            sizing: .init(weightsBytes: installed.receipt.payloadBytes, fp16KVBytesPerToken: 64,
                maxContextLength: 4096, defaultMaxTokens: 2), kvBytesCapacity: 2 << 30,
            kvBudget: budget, loadLease: lease, construction: construction, environment: [:])
        let images = try owner.localImageBinding()
        let template = try #require(Data(base64Encoded: superImagePinnedTemplateBase64,
                                        options: .ignoreUnknownCharacters))
        // The largest reservation the budget admits, to 1 MiB; leave 64 MiB of it.
        var low: UInt64 = 0, high: UInt64 = 64 << 30
        while high - low > 1 << 20 {
            let mid = (low + high) / 2
            if await budget.reserveBytes(requestID: "super-image-plan-probe", bytes: mid) {
                await budget.release(requestID: "super-image-plan-probe"); low = mid
            } else { high = mid }
        }
        #expect(await budget.reserveBytes(requestID: "super-image-plan-filler", bytes: low - (64 << 20)))
        let held = await budget.reservationBytesSnapshot()
        #expect(await !budget.rejectionStreakArmedForTesting())
        for (label, image) in [("png", Self.png(width: 8192, height: 8192)),
                               ("jpeg", Self.jpeg(width: 8192, height: 8192))] {
            let body = try JSONSerialization.data(withJSONObject: [
                "model": NemotronSuperLocalBinding.modelID, "max_tokens": 2,
                "messages": [["role": "user", "content": [["type": "image_url",
                    "image_url": ["url": "data:image/\(label);base64," + image.base64EncodedString()]]]]]])
            await #expect(throws: NemotronSuperImagePreprocessing.Failure.workspaceLimit, "\(label)") {
                try await images.runEncoded(body: body, templateBytes: template) { _ in
                    Issue.record("refused image emitted an event")
                }
            }
            #expect(await !budget.rejectionStreakArmedForTesting(), "\(label)")
            #expect(await budget.reservationBytesSnapshot() == held, "\(label)")
        }
        await budget.release(requestID: "super-image-plan-filler")
        try await owner.closeAfterDrain()
        #expect(residency.snapshot.usedBytes == 0)
        #expect(await budget.finishPendingLoad(lease))
        #expect(await budget.outstandingReservedBytes() == 0)
    }
}
