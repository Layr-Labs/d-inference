// Copyright © 2026 Eigen Labs.
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import MLX
import MLXLMCommon
@testable import MLXVLM
import NIOCore
import Testing
@testable import ProviderCore

/// Live loopback HTTP through the opt-in image hook with the real decoder and
/// the tiny synthetic owner. Every fixture here maps to the 32x32 patch grid
/// that the tiny RADIO fixture's position table covers. MLX's peak counter is
/// process-wide: run filtered when calibrating the peak measurement.
@Suite(.serialized)
struct NemotronSuperImageFormatHTTPTests {
    @Test(.timeLimit(.minutes(3))) func inlineImageFormatsServeAndInvalidMediaIsRejected() async throws {
        let dimensions = NemotronRadioDimensions(width: 2, layers: 1, heads: 1,
            channels: 3, patch: 16, positionSide: 32, prefix: 1, mlpWidth: 3)
        let (installed, construction, residency) = try SuperInstalledFixture(radioDimensions: dimensions).make()
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: .max) })
        let lease = try #require(await budget.claimPendingLoad(requestID: "super-image-formats-http",
            weightBytes: UInt64(installed.receipt.payloadBytes), minimumKVBytes: 2 << 30))
        let tokenizer = TokenizerHandle(SuperSyntheticImageTokenizer())
        let owner = try await NemotronSuperLocalBridgeBuilder.make(installed: installed,
            tokenizer: tokenizer, eosTokenIDs: [31],
            sizing: .init(weightsBytes: installed.receipt.payloadBytes, fp16KVBytesPerToken: 64,
                maxContextLength: 1024, defaultMaxTokens: 2), kvBytesCapacity: 2 << 30,
            kvBudget: budget, loadLease: lease, construction: construction, environment: [:])
        let template = try #require(Data(base64Encoded: superImagePinnedTemplateBase64,
                                        options: .ignoreUnknownCharacters))
        let hook = try NemotronSuperLocalImageHTTP(owner: owner, templateBytes: template)
        let model = NemotronSuperLocalBinding.modelID
        // The decoder sniffs content, so every accepted fixture is sent under
        // both admitted labels: each format also arrives under the other's.
        let admittedLabels = ["png", "jpeg"]
        @Sendable func uri(_ data: Data, _ label: String) -> String {
            "data:image/\(label);base64," + data.base64EncodedString()
        }
        @Sendable func body(_ images: [Data], label: String) throws -> ByteBuffer {
            let parts: [[String: Any]] = [["type": "text", "text": "fixture"]]
                + images.map { ["type": "image_url", "image_url": ["url": uri($0, label)]] }
            let value: [String: Any] = ["model": model, "stream": false, "temperature": 0, "max_tokens": 2,
                                        "enable_thinking": false,
                                        "messages": [["role": "user", "content": parts]]]
            return ByteBuffer(bytes: try JSONSerialization.data(withJSONObject: value))
        }
        let accepted = try ["png-palette8-trns.png", "png-rgba16-adam7.png", "png-graya16.png",
                            "png-gray1-adam7.png", "png-exif6.png", "png-xmp6-itxt.png", "png-apng.png",
                            "jpeg-exif6.jpeg", "jpeg-gray.jpeg", "jpeg-cmyk.jpeg"].map(NemotronSuperImageFixtures.data)
        let oversize = SuperImageTestPNG.image(width: 20_000, height: 20_000, colorType: 0, depth: 1, rows: [[0]])
        var twelveBit = try NemotronSuperImageFixtures.data("jpeg-420.jpeg")
        twelveBit[try #require(SuperImageTestJPEG.segment(0xc0, in: twelveBit)) + 4] = 12
        var corrupt = accepted[0]
        corrupt[40] ^= 0x10
        let rejected = [oversize, twelveBit, corrupt, Data("GIF89a".utf8) + Data(count: 16)]
        let app = makeLocalInferenceApplication(
            config: .init(host: "127.0.0.1", port: 0, authToken: "synthetic-super-formats"),
            defaultMaxTokens: 2, acquire: { requested in
                throw MultiModelBatchSchedulerEngineError.modelNotLoaded(requested)
            }, tokenizerProvider: { _ in .init(tokenizer: tokenizer, modelType: "nemotron_h_omni") },
            availableModels: { [] }, mtpSlots: { [] },
            modelTypeProvider: { _ in "nemotron_h_omni" }, nemotronSuperImageHTTP: hook)
        let headers: HTTPFields = [.contentType: "application/json",
                                  .authorization: "Bearer synthetic-super-formats"]
        let baseline = await budget.outstandingReservedBytes()
        try await app.test(.live) { client in
            // The synthetic tokenizer renders one image placeholder, so each
            // request carries one image; mixed plans are covered below.
            for label in admittedLabels {
                for (index, image) in accepted.enumerated() {
                    try await client.execute(uri: "/v1/chat/completions", method: .post,
                        headers: headers, body: try body([image], label: label)) { response in
                        let output = String(buffer: response.body)
                        #expect(response.status == .ok, "\(label) request \(index): \(output)")
                        #expect(output.contains("chat.completion") && !output.contains("\"error\""),
                                "\(label) request \(index)")
                    }
                    #expect(await budget.outstandingReservedBytes() == baseline)
                }
            }
            // Content decides the format; a label outside the decoder's formats
            // is refused even when the content would decode.
            let refusals = rejected.flatMap { image in admittedLabels.map { (image, $0) } }
                + [(accepted[0], "gif"), (accepted[0], "jpg")]
            for (image, label) in refusals {
                try await client.execute(uri: "/v1/chat/completions", method: .post,
                    headers: headers, body: try body([image], label: label)) { response in
                    #expect(response.status == .badRequest, "label \(label)")
                    #expect(String(buffer: response.body).contains("error"))
                }
                #expect(await budget.outstandingReservedBytes() == baseline)
            }
        }
        try await owner.closeAfterDrain()
        #expect(residency.snapshot.usedBytes == 0)
        #expect(await budget.finishPendingLoad(lease))
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    @Test func encodedPlanQuotesMixedFormatsFromContainers() throws {
        let images = try ["png-rgba16-adam7.png", "jpeg-exif6.jpeg", "png-palette8-trns.png"]
            .map(NemotronSuperImageFixtures.data)
        let plan = try NemotronSuperLocalImageBinding.encodedPlan(images, contextLength: 1024)
        #expect(plan.grids.map(\.tokens) == [256, 256, 256])
        let quotes = try images.map { try NemotronSuperImageDecode.inspect($0, orientation: .applyEXIF) }
        #expect(quotes.map(\.format) == [.png, .jpeg, .png])
        #expect(plan.totalBytes >= quotes.reduce(UInt64(0)) { $0 + UInt64($1.normalizationWorkspaceBytes) })
        let oversize = SuperImageTestPNG.image(width: 20_000, height: 20_000, colorType: 0, depth: 1, rows: [[0]])
        #expect(throws: NemotronSuperImageDecode.Failure.sizeLimit) {
            try NemotronSuperLocalImageBinding.encodedPlan(images + [oversize], contextLength: 1024)
        }
    }

    /// MLX peak growth for the largest admitted grid (2048x1664, 13312 patches)
    /// through live HTTP must stay within the request's media reservation. The
    /// fixture tower's unfused attention materializes a 13313x13313 score matrix.
    @Test(.timeLimit(.minutes(3))) func largestAdmittedImagePeakStaysWithinMediaReservation() async throws {
        let dimensions = NemotronRadioDimensions(width: 2, layers: 1, heads: 1,
            channels: 3, patch: 16, positionSide: 32, prefix: 1, mlpWidth: 3)
        let (installed, construction, residency) = try SuperInstalledFixture(radioDimensions: dimensions).make()
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 16 << 30, active: 0, cache: 0, systemAvailable: .max) })
        let lease = try #require(await budget.claimPendingLoad(requestID: "super-image-largest-http",
            weightBytes: UInt64(installed.receipt.payloadBytes), minimumKVBytes: 2 << 30))
        let tokenizer = TokenizerHandle(SuperSyntheticImageTokenizer())
        let owner = try await NemotronSuperLocalBridgeBuilder.make(installed: installed,
            tokenizer: tokenizer, eosTokenIDs: [31],
            sizing: .init(weightsBytes: installed.receipt.payloadBytes, fp16KVBytesPerToken: 64,
                maxContextLength: 4096, defaultMaxTokens: 2), kvBytesCapacity: 2 << 30,
            kvBudget: budget, loadLease: lease, construction: construction, environment: [:])
        let template = try #require(Data(base64Encoded: superImagePinnedTemplateBase64,
                                        options: .ignoreUnknownCharacters))
        let hook = try NemotronSuperLocalImageHTTP(owner: owner, templateBytes: template)
        // A Sub-filtered gradient keeps the 2048x1664 PNG small on the wire.
        let row = [UInt8(1)] + [UInt8](repeating: 1, count: 2048 * 3)
        let image = SuperImageTestPNG.image(width: 2048, height: 1664, colorType: 2, depth: 8,
                                            rows: [[UInt8]](repeating: row, count: 1664))
        let plan = try NemotronSuperLocalImageBinding.encodedPlan([image], contextLength: 4096)
        #expect(plan.grids.map(\.tokens) == [3328])
        #expect(plan.totalBytes >= (try NemotronSuperLocalImageBinding.towerActivationBytes([(104, 128)])))
        let value: [String: Any] = ["model": NemotronSuperLocalBinding.modelID, "stream": false,
            "temperature": 0, "max_tokens": 2, "enable_thinking": false,
            "messages": [["role": "user", "content": [["type": "text", "text": "fixture"],
                ["type": "image_url", "image_url": ["url": "data:image/png;base64," + image.base64EncodedString()]]]]]]
        let body = ByteBuffer(bytes: try JSONSerialization.data(withJSONObject: value))
        let app = makeLocalInferenceApplication(
            config: .init(host: "127.0.0.1", port: 0, authToken: "synthetic-super-largest"),
            defaultMaxTokens: 2, acquire: { requested in
                throw MultiModelBatchSchedulerEngineError.modelNotLoaded(requested)
            }, tokenizerProvider: { _ in .init(tokenizer: tokenizer, modelType: "nemotron_h_omni") },
            availableModels: { [] }, mtpSlots: { [] },
            modelTypeProvider: { _ in "nemotron_h_omni" }, nemotronSuperImageHTTP: hook)
        let headers: HTTPFields = [.contentType: "application/json",
                                  .authorization: "Bearer synthetic-super-largest"]
        try await app.test(.live) { client in
            Memory.clearCache()
            Memory.peakMemory = 0
            let base = Memory.activeMemory
            try await client.execute(uri: "/v1/chat/completions", method: .post,
                headers: headers, body: body) { response in
                #expect(response.status == .ok, "\(String(buffer: response.body))")
            }
            let peak = UInt64(max(0, Memory.peakMemory - base))
            // The unfused fixture attention alone needs one 13313^2 float32 matrix.
            #expect(peak >= 13313 * 13313 * 4)
            #expect(peak <= plan.totalBytes, "MLX peak growth \(peak) above media reservation \(plan.totalBytes)")
        }
        try await owner.closeAfterDrain()
        #expect(residency.snapshot.usedBytes == 0)
        #expect(await budget.finishPendingLoad(lease))
        #expect(await budget.outstandingReservedBytes() == 0)
    }
}
