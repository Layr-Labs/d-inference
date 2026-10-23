// Copyright © 2026 Eigen Labs.
import Foundation
import MLX
import MLXLMCommon
import Testing
@testable import MLXVLM
@testable import ProviderCore

/// The Super owner's one-video path: request admission, the tubelet prompt
/// layout, the media charge and its quote, error mapping, and a synthesized
/// MP4 served end to end on the tiny installed fixture.
struct NemotronSuperVideoBindingTests {
    private typealias Binding = NemotronSuperLocalImageBinding
    private typealias Policy = NemotronSuperServingPolicy
    private typealias VideoPrompt = NemotronSuperPromptContract.VideoPrompt

    private static let mp4 = "data:video/mp4;base64,AAAAGGZ0eXA="
    private static let png = "data:image/png;base64,iVBORw0KGgo="

    private static func video(_ uri: String = mp4) -> [String: Any] {
        ["type": "video_url", "video_url": ["url": uri]]
    }
    private static func image(_ uri: String = png) -> [String: Any] {
        ["type": "image_url", "image_url": ["url": uri]]
    }
    private static func text(_ text: String) -> [String: Any] { ["type": "text", "text": text] }

    private static func body(_ messages: [[String: Any]], extras: [String: Any] = [:]) throws -> Data {
        var value: [String: Any] = ["model": NemotronSuperLocalBinding.modelID, "messages": messages]
        for (key, item) in extras { value[key] = item }
        return try JSONSerialization.data(withJSONObject: value)
    }
    private static func user(_ parts: [[String: Any]]) -> [String: Any] { ["role": "user", "content": parts] }

    private static func template() throws -> Data {
        try #require(Data(base64Encoded: superImagePinnedTemplateBase64, options: .ignoreUnknownCharacters))
    }

    @Test func encodedBodyAdmitsOneVideoAsTheOnlyMedia() throws {
        for uri in [Self.mp4, "data:video/quicktime;base64,AAAA"] {
            let parsed = try Binding.parseEncodedBody(Self.body([Self.user([Self.text("what happens?"), Self.video(uri)])]))
            #expect(parsed.video == uri && parsed.images.isEmpty)
        }
        let refused: [[[String: Any]]] = [
            [Self.user([Self.video(), Self.video()])],
            [Self.user([Self.video()]), Self.user([Self.video()])],
            [Self.user([Self.video(), Self.image()])],
            [Self.user([Self.image(), Self.video()])],
            [Self.user([Self.video("data:video/webm;base64,AAAA")])],
            [Self.user([Self.video("data:video/MP4;base64,AAAA")])],
            [Self.user([Self.video("data:video/mp4,AAAA")])],
            [Self.user([Self.video("https://example.invalid/clip.mp4")])],
            [Self.user([Self.video("file:///tmp/clip.mp4")])],
        ]
        for messages in refused {
            #expect(throws: Binding.Failure.unsupportedCapability) {
                try Binding.parseEncodedBody(Self.body(messages))
            }
        }
        #expect(throws: Binding.Failure.invalidInput) {
            try Binding.parseEncodedBody(Self.body([Self.user([Self.text("no media")])]))
        }
    }

    /// Labels, `<img>` and `</img>` stay for every tubelet, including an odd
    /// single-frame last tubelet and one whose rows were all pruned.
    @Test func tubeletLayoutKeepsEveryLabelAndWrapper() throws {
        let odd = VideoPrompt(prefix: [1, 2], labels: [[5, 6], [21, 5, 7], [21, 5, 8]], suffix: [3])
        #expect(try odd.tokens(keptCounts: [2, 0, 1], contextLength: 64)
            == [1, 2, 5, 6, 19, 18, 18, 20, 21, 5, 7, 19, 20, 21, 5, 8, 19, 18, 20, 3])
        let even = VideoPrompt(prefix: [], labels: [[5], [21, 6]], suffix: [])
        #expect(try even.tokens(keptCounts: [1, 2], contextLength: 64) == [5, 19, 18, 20, 21, 6, 19, 18, 18, 20])
        // Any split of the kept rows has the same length, which is admitted
        // before pruning chooses the split.
        #expect(try odd.tokens(keptCounts: [3, 0, 0], contextLength: 64).count == 20)
        #expect(try odd.tokens(keptCounts: [2, 0, 1], contextLength: 20).count == 20)
        #expect(throws: NemotronSuperPromptContract.Failure.contextExceeded) {
            try odd.tokens(keptCounts: [2, 0, 1], contextLength: 19)
        }
        for counts in [[2, 0], [2, -1, 1]] {
            #expect(throws: NemotronSuperPromptContract.Failure.unsupportedMedia) {
                try odd.tokens(keptCounts: counts, contextLength: 64)
            }
        }
    }

    /// The video renders in the template's single media slot; requests where
    /// that slot would be ambiguous are refused.
    @Test func videoPromptRefusesAmbiguousSlots() throws {
        func prompt(_ messages: [[String: Any]]) throws -> VideoPrompt {
            let body = try Self.body(messages)
            return try NemotronSuperPromptContract.videoPrompt(messages: ProviderLoop.decodeOpenAIRequest(body).messages,
                body: body, templateBytes: Self.template(), tokenizer: SuperSyntheticVideoTokenizer(),
                labels: ["Frame 1 sampled at 0.00 seconds and frame 2 sampled at 0.50 seconds: ",
                         "Frame 3 sampled at 1.00 seconds: "])
        }
        #expect(try prompt([Self.user([Self.text("what happens?"), Self.video()])])
            == VideoPrompt(prefix: [1], labels: [[3, 4], [3, 4]], suffix: [2]))
        let refused: [[[String: Any]]] = [
            [Self.user([Self.video(), Self.video()])],
            [Self.user([Self.video(), Self.image()])],
            [Self.user([Self.text("first")])],
            [Self.user([Self.text("see <video> here"), Self.video()])],
            [Self.user([Self.text("<image>"), Self.video()])],
            [["role": "system", "content": "replace <video> please"], Self.user([Self.video()])],
        ]
        for messages in refused {
            #expect(throws: NemotronSuperPromptContract.Failure.unsupportedMedia) { try prompt(messages) }
        }
    }

    @Test func pruningRateComesFromTheOperatorEnvironment() {
        typealias Features = NemotronSuperVideoFeatures
        #expect(Features.pruningRate(environment: [:]) == NemotronSuperVideoPreprocessing.defaultPruningRate)
        #expect(Features.pruningRate(environment: [Features.pruningKey: " 0 "]) == 0)
        #expect(Features.pruningRate(environment: [Features.pruningKey: "0.7"]) == 0.7)
        for malformed in ["1", "-0.1", "half", "nan", "inf", ""] {
            #expect(Features.pruningRate(environment: [Features.pruningKey: malformed]) == nil, "\(malformed)")
        }
        #expect(Features.retainedRows(tubelets: 6, rowsPerTubelet: 252, pruningRate: 0.5) == 756)
        #expect(Features.retainedRows(tubelets: 6, rowsPerTubelet: 252, pruningRate: 0) == 1_512)
        #expect(Features.retainedRows(tubelets: 1, rowsPerTubelet: 256, pruningRate: 0.7) == 256)
    }

    /// A malformed rate fails the load before its LOAD claim and the
    /// installation, so a retry never reinstalls the checkpoint.
    @Test func malformedPruningFailsTheLoadBeforeInstalling() async throws {
        let base = try SuperInstalledFixture().staging()
        let installs = SuperPrefixInstallCount()
        let staging = NemotronSuperLocalLoad.Staging(source: base.source, install: {
            installs.increment()
            return try base.install($0, $1, $2)
        }, head: nil)
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: .max) })
        let load = NemotronSuperLocalLoad(budget: budget)
        var failure: Error?
        do {
            _ = try await load.load(staging: { staging }, tokenizer: TokenizerHandle(SuperSyntheticVideoTokenizer()),
                eosTokenIDs: [31], sizing: .init(weightsBytes: 1 << 20, fp16KVBytesPerToken: 64,
                    maxContextLength: 1024, defaultMaxTokens: 2),
                kvBytesCapacity: 2 << 30, backendAllowanceBytes: 1 << 20, modelID: NemotronSuperLocalBinding.modelID,
                environment: [NemotronSuperVideoFeatures.pruningKey: "half"])
        } catch {
            failure = error
        }
        #expect(failure as? NemotronSuperLocalBridgeBuilder.Failure == .invalidVideoPruning, "\(String(describing: failure))")
        #expect(installs.count == 0)
        #expect(await load.fitAttempts.isEmpty)
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    /// The policy's bound is the binding's own charge at every maximum, and
    /// stays within one largest image, so the footprint and quotes hold it.
    @Test func videoChargeStaysWithinOneLargestImage() throws {
        let video = try #require(Policy.videoMediaChargeBytes)
        let image = try #require(Policy.mediaChargeBytes(imageCount: 1))
        #expect(video <= image)
        let ingress = try Binding.encodedHeaderQuote(bodyBytes: Policy.maximumEncodedBodyBytes,
                                                     templateBytes: Policy.pinnedTemplateBytes)
        let maxima = try Binding.videoChargeBytes(encodedBytes: Policy.maximumEncodedBodyBytes / 4 * 3,
            codedPixels: Policy.maximumVideoFramePixels, patchRows: 32, patchColumns: 34, tubelets: 128)
        #expect(video == ingress + maxima)
        // 128 tubelets of 272 rows at 49,152 bytes, four tubelets' frames and
        // activation, a five-tubelet scoring window at 73,728 bytes a row,
        // the 4K decoder working set and two encoded copies.
        #expect(Policy.videoScoringBytesPerRow == 73_728)
        #expect(video == 4_875_295_228)
        let colors = try Binding.videoChargeBytes(encodedBytes: 19_714, codedPixels: 640 * 360,
                                                  patchRows: 24, patchColumns: 42, tubelets: 6)
        #expect(colors < maxima)
        #expect(try Binding.videoChargeBytes(encodedBytes: 19_714, codedPixels: 640 * 360,
            patchRows: 24, patchColumns: 42, tubelets: 7) == colors + 252 * Policy.videoBytesPerFeatureRow)
        // The scoring window grows with the first batch and its predecessor, then stays.
        let four = try Binding.videoChargeBytes(encodedBytes: 19_714, codedPixels: 640 * 360,
                                                patchRows: 24, patchColumns: 42, tubelets: 4)
        #expect(try Binding.videoChargeBytes(encodedBytes: 19_714, codedPixels: 640 * 360,
            patchRows: 24, patchColumns: 42, tubelets: 5)
            == four + 252 * (Policy.videoBytesPerFeatureRow + Policy.videoScoringBytesPerRow))
        for (rows, columns, tubelets) in [(34, 34, 1), (32, 33, 1), (24, 42, 129), (24, 42, 0)] {
            #expect(throws: Binding.Failure.invalidInput) {
                try Binding.videoChargeBytes(encodedBytes: 1, codedPixels: 1, patchRows: rows, patchColumns: columns,
                                             tubelets: tubelets)
            }
        }
        // A one-part probe may carry the one video: the larger charge applies.
        let probe = CoordinatorMessage.CapacityProbe(quoteId: "q", model: Policy.modelID, promptTokensBucket: 512,
            maxOutputTokens: 512, requiresVision: true, visionImageCount: 1, deadlineRemainingMs: 9000)
        let model = ModelInfo(id: Policy.modelID, modelType: "nemotron_h_omni", sizeBytes: 1, estimatedMemoryGb: 1,
                              isVision: true, templateRenderOK: true)
        #expect(CapacityQuoteEngine.nemotronSuperMediaCharge(probe: probe, model: model)
            == .charged(bytes: max(image, video)))
    }

    /// A real clip's plan admits its prompt at the pruned length and reserves
    /// within the policy bound.
    @Test func encodedPlanAdmitsThePrunedPromptWithinTheBound() async throws {
        let golden = try NemotronSuperVideoFixtures.golden()
        let clip = try #require(golden.clips.first { $0.file == "colors_16x9.mp4" })
        let video = try await NemotronSuperVideoDecode.inspect(try NemotronSuperVideoFixtures.uri(clip.file))
        let prompt = VideoPrompt(prefix: Array(repeating: 1, count: 8), labels: clip.labelTokenIds,
                                 suffix: Array(repeating: 2, count: 13))
        let length = 8 + 13 + clip.labelTokenIds.reduce(0) { $0 + $1.count + 2 } + 756
        let plan = try Binding.encodedVideoPlan(video, prompt: prompt, pruningRate: 0.5, contextLength: length)
        #expect(plan.featureBytes == 756 * 4096 * 4)
        let ingress = try Binding.encodedHeaderQuote(bodyBytes: Policy.maximumEncodedBodyBytes,
                                                     templateBytes: Policy.pinnedTemplateBytes)
        #expect(ingress + plan.totalBytes <= (Policy.videoMediaChargeBytes ?? 0))
        // A prompt beyond the context is the request's own fault: 400, not a retryable 503.
        #expect(throws: Binding.Failure.invalidInput) {
            try Binding.encodedVideoPlan(video, prompt: prompt, pruningRate: 0.5, contextLength: length - 1)
        }
        // Unpruned, every one of the 1,512 rows needs room.
        #expect(throws: Binding.Failure.invalidInput) {
            try Binding.encodedVideoPlan(video, prompt: prompt, pruningRate: 0, contextLength: length)
        }
    }

    @Test func invalidVideosTakeTheInvalidMediaPath() {
        let errors: [any Error] = [NemotronSuperVideoDecode.Failure.limit, NemotronSuperVideoDecode.Failure.invalidVideo,
            NemotronSuperVideoDecode.Failure.unsupportedRepresentation,
            NemotronSuperVideoPreprocessing.Failure.emptyVideo, MediaIngest.MediaError.mediaTooLarge("video"),
            Binding.Failure.unsupportedCapability, Binding.Failure.invalidInput]
        for error in errors {
            let mapped = SuperHTTPErrors.map(error, media: true)
            guard case .multimodalRejected? = mapped as? MultiModelBatchSchedulerEngineError else {
                Issue.record("\(error) mapped to \(mapped)")
                continue
            }
        }
    }

    /// A body above the ingress bound leaves as `media_too_large` (413 at the
    /// coordinator); the binding's other refusals stay `invalid_media`.
    @Test func oversizeBodyIsMediaTooLarge() {
        let tooLarge = ProviderLoop.sanitizedInferenceFailure(
            from: SuperHTTPErrors.map(Binding.Failure.bodyTooLarge, media: true), phase: .request)
        #expect(tooLarge.code == .mediaTooLarge && tooLarge.statusCode == 400, "\(tooLarge)")
        let invalid = ProviderLoop.sanitizedInferenceFailure(
            from: SuperHTTPErrors.map(Binding.Failure.invalidInput, media: true), phase: .request)
        #expect(invalid.code == .invalidMedia && invalid.statusCode == 400, "\(invalid)")
    }

    /// Native feature failures name what went wrong, for video as for images.
    @Test func featureFailuresNameTheirCause() {
        let failures: [(Binding.Failure, String)] = [
            (.invalidFeatures, "native media features were not finite"),
            (.inconsistentVideoFeatures, "native video features did not match the admitted layout"),
        ]
        for (failure, message) in failures {
            let mapped = SuperHTTPErrors.map(failure, media: true)
            guard case .generationFailed(let description)? = mapped as? MultiModelBatchSchedulerEngineError else {
                Issue.record("\(failure) mapped to \(mapped)")
                continue
            }
            #expect(description == message)
        }
    }

    /// Ten tubelets run as batches of four, four and two, each later batch
    /// scored behind the previous batch's last tubelet. The kept rows equal
    /// EVS over the whole video's rows (the SDK's whole-video reference):
    /// the same count per tubelet and the same rows.
    @Test(.timeLimit(.minutes(3))) func windowedPruningKeepsTheWholeVideoSelection() async throws {
        // The fixture's weights come from module initializers; a fixed random
        // state keeps them, and so the cross-batch check below, independent of
        // the tests that ran before.
        let (installed, _, residency) = try withRandomState(MLXRandom.RandomState(seed: 1)) {
            try SuperInstalledFixture(radioDimensions: Self.squareTower).make()
        }
        // Every frame of a 2 fps clip is sampled: 20 frames, 10 tubelets.
        let plan = try await NemotronSuperVideoDecode.inspect(
            NemotronSuperVideoClips.uri(try await NemotronSuperVideoClips.movie(frames: 20, fps: 2)))
        try #require(plan.tubelets == 10 && plan.grid.tokens == 256)
        #expect(plan.tubelets > 2 * NemotronSuperVideoFeatures.tubeletBatch)
        let prompt = VideoPrompt(prefix: [1], labels: Array(repeating: [3, 4], count: plan.tubelets), suffix: [2])
        func prepared(pruningRate: Double) async throws -> EngineV2VisionPrefill.PreparedSubmission {
            let frames = try await NemotronSuperVideoDecode.Frames(plan)
            var live: [MLXArray] = []
            return try NemotronSuperVideoFeatures.prepare(installed: installed, frames: frames, prompt: prompt,
                pruningRate: pruningRate, contextLength: 16_384,
                maximumFeatureBytes: plan.tubelets * plan.grid.tokens * 4096 * 4,
                construction: NativeConstructionScope(), live: &live)
        }
        // Unpruned, the submission carries every tubelet's rows in order.
        let whole = try await prepared(pruningRate: 0)
        try #require(whole.embeddings.count == plan.tubelets)
        let rows = concatenated(whole.embeddings, axis: 0)
        let reference = NemotronSuperEVS.keptPositions(features: rows, pruningRate: 0.5)
        try #require(reference.count == plan.tubelets)
        // Scoring a later batch's first tubelet against the previous batch's
        // first tubelet instead of its last would keep other rows, so the
        // comparison below covers the cross-batch overlap.
        let batch = NemotronSuperVideoFeatures.tubeletBatch, tokens = plan.grid.tokens
        var misaligned = NemotronSuperEVS.dissimilarity(rows).asArray(Float.self)
        for first in stride(from: batch, to: plan.tubelets, by: batch) {
            let pair = concatenated([rows[(first - batch) ..< (first - batch + 1)], rows[first ..< (first + 1)]], axis: 0)
            misaligned.replaceSubrange((first - 1) * tokens ..< first * tokens,
                                       with: NemotronSuperEVS.dissimilarity(pair).asArray(Float.self))
        }
        #expect(NemotronSuperEVS.keptPositions(dissimilarity: misaligned, tubelets: plan.tubelets, tokens: tokens,
                                               pruningRate: 0.5) != reference)
        let pruned = try await prepared(pruningRate: 0.5)
        var kept: [Int] = []
        for token in pruned.promptTokens {
            if token == 19 { kept.append(0) }
            if token == 18, !kept.isEmpty { kept[kept.count - 1] += 1 }
        }
        #expect(kept == reference.map(\.count))
        let spans = reference.indices.filter { !reference[$0].isEmpty }
        try #require(pruned.embeddings.count == spans.count)
        for (embedding, tubelet) in zip(pruned.embeddings, spans) {
            let expected = rows[tubelet].take(MLXArray(reference[tubelet]), axis: 0).expandedDimensions(axis: 0)
            #expect(embedding.shape == expected.shape, "tubelet \(tubelet)")
            #expect(arrayEqual(embedding, expected).item(Bool.self), "tubelet \(tubelet)")
        }
        installed.closeAfterRetirement()
        #expect(residency.snapshot.usedBytes == 0)
    }

    /// Cancelling a request while its frames decode returns the ingress and
    /// media charges and leaves the owner without a fault.
    @Test(.timeLimit(.minutes(3))) func cancellingAVideoMidDecodeReleasesItsCharge() async throws {
        let fixture = try await Self.videoOwner(contextLength: 4_096)
        let media = try fixture.owner.localImageBinding()
        let body = try await Self.longVideoBody()
        let template = try Self.template()
        let baseline = await fixture.budget.outstandingReservedBytes()
        let hold = SuperDecodeHold()
        let request = hold.decoding {
            Task { try await media.runEncoded(body: body, templateBytes: template) { _ in } }
        }
        try await Self.decodeStarted(hold, fixture.budget)
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(await fixture.budget.outstandingReservedBytes() == baseline)
        #expect(!fixture.owner.hasRetainedImageFault)
        try await fixture.close()
    }

    /// Retiring the owner while a video decodes cancels it instead of
    /// waiting on the decoder.
    @Test(.timeLimit(.minutes(3))) func drainStopsAnActiveVideo() async throws {
        let fixture = try await Self.videoOwner(contextLength: 4_096)
        let media = try fixture.owner.localImageBinding()
        let body = try await Self.longVideoBody()
        let template = try Self.template()
        let hold = SuperDecodeHold()
        let request = hold.decoding {
            Task { try await media.runEncoded(body: body, templateBytes: template) { _ in } }
        }
        try await Self.decodeStarted(hold, fixture.budget)
        try await fixture.close()
        await #expect(throws: CancellationError.self) { try await request.value }
    }

    /// The fixture tower's 32 x 32 position table: square clips map to it.
    private static let squareTower = NemotronRadioDimensions(width: 2, layers: 1, heads: 1,
        channels: 3, patch: 16, positionSide: 32, prefix: 1, mlpWidth: 3)

    private struct VideoOwner {
        let owner: NemotronSuperLocalBridgeBuilder.Owner
        let budget: GlobalKVCacheBudget
        let lease: PendingModelLoadLease
        let residency: NemotronSuperResidency

        /// Drains and retires the owner; every charge but the load's returns.
        func close() async throws {
            try await owner.closeAfterDrain()
            #expect(residency.snapshot.usedBytes == 0)
            #expect(await budget.finishPendingLoad(lease))
            #expect(await budget.outstandingReservedBytes() == 0)
        }
    }

    private static func videoOwner(contextLength: Int) async throws -> VideoOwner {
        let (installed, construction, residency) = try SuperInstalledFixture(radioDimensions: squareTower).make()
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 16 << 30, active: 0, cache: 0, systemAvailable: .max) })
        let lease = try #require(await budget.claimPendingLoad(requestID: "super-video-" + UUID().uuidString,
            weightBytes: UInt64(installed.receipt.payloadBytes), minimumKVBytes: 2 << 30))
        let owner = try await NemotronSuperLocalBridgeBuilder.make(installed: installed,
            tokenizer: TokenizerHandle(SuperSyntheticVideoTokenizer()), eosTokenIDs: [31],
            sizing: .init(weightsBytes: installed.receipt.payloadBytes, fp16KVBytesPerToken: 64,
                maxContextLength: contextLength, defaultMaxTokens: 2), kvBytesCapacity: 2 << 30,
            kvBudget: budget, loadLease: lease, construction: construction, environment: [:])
        return VideoOwner(owner: owner, budget: budget, lease: lease, residency: residency)
    }

    /// 600 frames at 30 fps: 40 sampled frames (20 tubelets) to decode and
    /// normalize.
    private static func longVideoBody() async throws -> Data {
        let uri = NemotronSuperVideoClips.uri(try await NemotronSuperVideoClips.movie(frames: 600, fps: 30))
        return try body([user([text("fixture"), video(uri)])], extras: ["max_tokens": 2, "temperature": 0])
    }

    /// Returns once `hold` holds the video's decode after its first frame,
    /// under the media charge taken before any frame decodes.
    private static func decodeStarted(_ hold: SuperDecodeHold, _ budget: GlobalKVCacheBudget) async throws {
        try #require(await hold.started(), "the video never started decoding")
        #expect(await budget.reservationBytesSnapshot().keys.contains(where: { $0.hasSuffix("-media") }))
    }

    @Test(.timeLimit(.minutes(3))) func encodedVideoServesAndReleasesItsCharge() async throws {
        let dimensions = NemotronRadioDimensions(width: 2, layers: 1, heads: 1,
            channels: 3, patch: 16, positionSide: 32, prefix: 1, mlpWidth: 3)
        let (installed, construction, residency) = try SuperInstalledFixture(radioDimensions: dimensions).make()
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 16 << 30, active: 0, cache: 0, systemAvailable: .max) })
        let lease = try #require(await budget.claimPendingLoad(requestID: "super-encoded-video",
            weightBytes: UInt64(installed.receipt.payloadBytes), minimumKVBytes: 2 << 30))
        let owner = try await NemotronSuperLocalBridgeBuilder.make(installed: installed,
            tokenizer: TokenizerHandle(SuperSyntheticVideoTokenizer()), eosTokenIDs: [31],
            sizing: .init(weightsBytes: installed.receipt.payloadBytes, fp16KVBytesPerToken: 64,
                maxContextLength: 1024, defaultMaxTokens: 2), kvBytesCapacity: 2 << 30,
            kvBudget: budget, loadLease: lease, construction: construction, environment: [:])
        #expect(owner.videoPruningRate == NemotronSuperVideoPreprocessing.defaultPruningRate)
        let media = try owner.localImageBinding()
        let template = try Self.template()
        // A square clip maps to the 32 x 32 patch grid the fixture tower's
        // position table covers; an odd sampled count repeats its last frame.
        let clip = try await MiMoEncodedMediaFixtures.video(frames: 10, fps: 4, width: 64, height: 64)
        let uri = "data:video/mp4;base64," + clip.base64EncodedString()
        let body = try Self.body([Self.user([Self.text("fixture"), Self.video(uri)])],
            extras: ["max_tokens": 2, "temperature": 0])
        // The layout's length: every tubelet's label and wrappers, and the
        // rows EVS keeps, however they split.
        let plan = try await NemotronSuperVideoDecode.inspect(uri)
        let prompt = try owner.localVideoPrompt(body: body, templateBytes: template, labels: plan.labels)
        let retained = NemotronSuperVideoFeatures.retainedRows(tubelets: plan.tubelets,
            rowsPerTubelet: plan.grid.tokens, pruningRate: owner.videoPruningRate)
        #expect(plan.tubelets > 1 && retained < plan.tubelets * plan.grid.tokens)
        let length = try prompt.tokens(keptCounts: [retained] + Array(repeating: 0, count: plan.tubelets - 1),
                                       contextLength: 1024).count
        let baseline = await budget.outstandingReservedBytes()
        let events = SuperVideoEvents()
        try await media.runEncoded(body: body, templateBytes: template) { event in await events.record(event) }
        #expect(await events.errors.isEmpty)
        #expect(await events.completions == [2])
        #expect(await events.prompts == [length])
        #expect(await budget.outstandingReservedBytes() == baseline)
        // The submission: one span per tubelet that kept rows, exactly over
        // its `<image>` run, in a prompt laid out from the kept counts.
        let frames = try await NemotronSuperVideoDecode.Frames(plan)
        let prepared = try owner.prepareLocalVideo(frames, prompt: prompt,
            maximumFeatureBytes: retained * 4096 * 4, construction: NativeConstructionScope())
        var kept: [Int] = []
        for token in prepared.promptTokens {
            if token == 19 { kept.append(0) }
            if token == 18, !kept.isEmpty { kept[kept.count - 1] += 1 }
        }
        #expect(kept.count == plan.tubelets && kept.reduce(0, +) == retained, "\(kept)")
        #expect(try prepared.promptTokens == prompt.tokens(keptCounts: kept, contextLength: 1024))
        #expect(prepared.promptTokens.count == length)
        #expect(prepared.spans.count == kept.filter { $0 > 0 }.count)
        #expect(prepared.spans.map(\.length) == kept.filter { $0 > 0 })
        #expect(prepared.spans.allSatisfy { span in
            span.tokenOffset > 0 && span.tokenOffset + span.length < prepared.promptTokens.count
                && prepared.promptTokens[span.tokenOffset - 1] == 19
                && prepared.promptTokens[span.tokenOffset ..< span.tokenOffset + span.length].allSatisfy { $0 == 18 }
                && prepared.promptTokens[span.tokenOffset + span.length] == 20
        })
        #expect(prepared.embeddings.count == prepared.spans.count && prepared.mediaKind == .video)
        // An undecodable movie is refused by the shared ingest before any
        // frame decodes; its ingress charge is returned.
        let broken = try Self.body([Self.user([Self.video(
            "data:video/mp4;base64," + Data("not a movie".utf8).base64EncodedString())])])
        await #expect(throws: MediaIngest.MediaError.self) {
            try await media.runEncoded(body: broken, templateBytes: template) { _ in
                Issue.record("refused video emitted an event")
            }
        }
        #expect(await budget.outstandingReservedBytes() == baseline)
        try await owner.closeAfterDrain()
        #expect(residency.snapshot.usedBytes == 0)
        #expect(await budget.finishPendingLoad(lease))
        #expect(await budget.outstandingReservedBytes() == 0)
    }
}

/// Once a video's first sampled frame has decoded, holds the decode of the
/// next until the task decoding it is cancelled (a minute at most).
private final class SuperDecodeHold: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private let holding = DispatchSemaphore(value: 0)

    /// Runs `body`; the tasks it creates decode under this hold.
    func decoding<Result>(_ body: () -> Result) -> Result {
        NemotronSuperVideoDecode.Frames.$beforeFrameDecodeForTesting.withValue({ self.frameStarts() }, operation: body)
    }

    /// Whether a decode is held, waiting off the cooperative pool at most a minute.
    func started() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: self.holding.wait(timeout: .now() + 60) == .success)
            }
        }
    }

    private func frameStarts() {
        let index = lock.withLock { () -> Int in
            defer { frames += 1 }
            return frames
        }
        guard index == 1 else { return }
        holding.signal()
        let deadline = ContinuousClock.now + .seconds(60)
        while !Task.isCancelled, ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.001) }
    }
}

private actor SuperVideoEvents {
    var errors: [String] = []
    var prompts: [Int] = []
    var completions: [Int] = []
    func record(_ event: GenerationEvent) {
        switch event {
        case .chunk: break
        case .info(let prompt, let count, _, _):
            prompts.append(prompt)
            completions.append(count)
        case .error(let message): errors.append(message)
        case .terminal(_, let message, _, _): errors.append(message)
        }
    }
}

/// Scripted tokenizer: the template renders one media slot, and every label
/// encodes to two plain tokens inside the fixture's 32-token vocabulary.
struct SuperSyntheticVideoTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [3, 4] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { String(repeating: "x", count: tokenIds.count) }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { "x" }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] { [1, 18, 2] }
    func applyChatTemplate(messages: [[String: any Sendable]], chatTemplate: String) throws -> [Int] { [1, 18, 2] }
    func applyChatTemplate(messages: [[String: any Sendable]], chatTemplate: String,
                           tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?) throws -> [Int] {
        [1, 18, 2]
    }
}
