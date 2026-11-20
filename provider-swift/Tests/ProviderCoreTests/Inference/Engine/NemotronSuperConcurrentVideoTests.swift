// Copyright © 2026 Eigen Labs.
@preconcurrency import AVFoundation
import Foundation
import MLX
@testable import MLXLMCommon
import Testing
@testable import MLXVLM
@testable import ProviderCore

/// A Super video request takes one of the owner's two media rows: beside
/// another video or an image, after the serial preparation lane, each with its
/// full charge until its settlement. The switches and a narrow owner keep a
/// video exclusive with other media, as before.
@Suite(.serialized)
struct NemotronSuperConcurrentVideoTests {
    private typealias Binding = NemotronSuperLocalImageBinding
    /// `NemotronSuperLocalBridgeBuilder.concurrentVideoKey`.
    private static let videoKey = "DARKBLOOM_NEMOTRON_SUPER_CONCURRENT_VIDEO"

    /// On by default: unset, empty or any value other than an off word. Both
    /// videos are charged in full while the first holds the lane, prepare one
    /// at a time, and both reach the engine before either answer ends.
    @Test(.timeLimit(.minutes(3)), arguments: [nil, "", "1", "garbage"] as [String?])
    func twoVideosShareTheOwnerAfterSerialPreparation(flag: String?) async throws {
        let session = try await VideoRowSession.make(environment: flag.map { [Self.videoKey: $0] } ?? [:])
        let latch = VideoPreparationLatch()
        await session.media.setTestPreparation { _, entering in await latch.observe(entering) }
        let engine = try #require(await session.owner.bridge.ownedEngine as? EngineV2)
        let loop = engine.loopForTesting
        loop.onEngineQueueSync { loop.suspendStepExecutionAtCountForTesting = 0 }
        let baseline = await session.budget.outstandingReservedBytes()
        let first = Task { try await session.run(.video) }
        var second: Task<Void, Error>?
        do {
            try await superHTTPEventually("first video holds the preparation lane") { await latch.started == 1 }
            second = Task { try await session.run(.video) }
            try await superHTTPEventually("both videos charged in full while the first prepares") {
                await session.budget.outstandingReservedBytes() == baseline + 2 * session.videoCharge
            }
            #expect(await latch.started == 1)
            await latch.release()
            try await superHTTPEventually("both videos reach the frozen native loop") {
                loop.onEngineQueueSync { loop.scheduler.runningCount + loop.scheduler.waitingCount == 2 }
            }
            #expect(await latch.started == 2)
            #expect(await latch.peak == 1)
            loop.onEngineQueueSync { loop.suspendStepExecutionAtCountForTesting = nil }
            try await first.value; try await second?.value
            #expect(await session.chargesReturn(to: baseline))
        } catch {
            first.cancel(); second?.cancel(); await latch.release()
            loop.onEngineQueueSync { loop.suspendStepExecutionAtCountForTesting = nil }
            _ = await first.result; _ = await second?.result
            try await session.close()
            throw error
        }
        try await session.close()
    }

    @Test(.timeLimit(.minutes(3)))
    func aVideoTakesTheSecondRowBesideAnImageAndAThirdRequestIsBusy() async throws {
        let session = try await VideoRowSession.make()
        let latch = VideoPreparationLatch()
        await session.media.setTestPreparation { _, entering in await latch.observe(entering) }
        let baseline = await session.budget.outstandingReservedBytes()
        let first = Task { try await session.run(.image) }
        var second: Task<Void, Error>?
        do {
            try await superHTTPEventually("the image holds the preparation lane") { await latch.started == 1 }
            second = Task { try await session.run(.video) }
            try await superHTTPEventually("the video charged in full beside the image") {
                await session.budget.outstandingReservedBytes()
                    == baseline + session.videoCharge + session.imageCharge
            }
            // Both rows are taken: a third media request is refused at once.
            await #expect(throws: Binding.Failure.busy) { try await session.run(.video) }
            await #expect(throws: Binding.Failure.busy) { try await session.run(.image) }
            await latch.release()
            try await first.value; try await second?.value
            #expect(await latch.started == 2)
            #expect(await latch.peak == 1)
            #expect(await session.chargesReturn(to: baseline))
        } catch {
            first.cancel(); second?.cancel(); await latch.release()
            _ = await first.result; _ = await second?.result
            try await session.close()
            throw error
        }
        try await session.close()
    }

    /// The video admitted to the second row and waiting for the lane is
    /// cancelled: only its charges return; the first is unaffected.
    @Test(.timeLimit(.minutes(3)))
    func cancellingTheVideoWaitingForTheLaneRefundsOnlyIt() async throws {
        let session = try await VideoRowSession.make()
        let latch = VideoPreparationLatch()
        await session.media.setTestPreparation { _, entering in await latch.observe(entering) }
        let baseline = await session.budget.outstandingReservedBytes()
        let first = Task { try await session.run(.video) }
        var second: Task<Void, Error>?
        do {
            try await superHTTPEventually("first video holds the preparation lane") { await latch.started == 1 }
            second = Task { try await session.run(.video) }
            try await superHTTPEventually("both videos charged") {
                await session.budget.outstandingReservedBytes() == baseline + 2 * session.videoCharge
            }
            second?.cancel()
            await #expect(throws: CancellationError.self) { try await second?.value }
            #expect(await latch.started == 1)
            #expect(await session.budget.outstandingReservedBytes() == baseline + session.videoCharge)
            await latch.release()
            try await first.value
            #expect(await session.chargesReturn(to: baseline))
        } catch {
            first.cancel(); second?.cancel(); await latch.release()
            _ = await first.result; _ = await second?.result
            try await session.close()
            throw error
        }
        try await session.close()
    }

    /// Draining cancels both video rows, the one preparing and the one waiting
    /// for the lane, and returns both charges.
    @Test(.timeLimit(.minutes(3)))
    func drainCancelsBothVideoRows() async throws {
        let session = try await VideoRowSession.make()
        let latch = VideoPreparationLatch()
        await session.media.setTestPreparation { _, entering in await latch.observe(entering) }
        let baseline = await session.budget.outstandingReservedBytes()
        let first = Task { try await session.media.runEncoded(body: session.videoBody,
            plan: NemotronSuperRequestPlan(body: session.videoBody), templateBytes: VideoRowSession.template()) { _ in } }
        var second: Task<Void, Error>?
        var drain: Task<Void, Error>?
        do {
            try await superHTTPEventually("first video holds the preparation lane") { await latch.started == 1 }
            second = Task { try await session.media.runEncoded(body: session.videoBody,
                plan: NemotronSuperRequestPlan(body: session.videoBody), templateBytes: VideoRowSession.template()) { _ in } }
            try await superHTTPEventually("both videos charged") {
                await session.budget.outstandingReservedBytes() == baseline + 2 * session.videoCharge
            }
            drain = Task { try await session.media.drain() }
            // The waiting video unwinds without touching the native tower.
            try await superHTTPEventually("the waiting video refunded during drain") {
                await session.budget.outstandingReservedBytes() == baseline + session.videoCharge
            }
            await latch.release()
            try await drain?.value
            _ = await first.result; _ = await second?.result
            #expect(await session.chargesReturn(to: baseline))
        } catch {
            first.cancel(); second?.cancel(); await latch.release()
            _ = await first.result; _ = await second?.result; _ = await drain?.result
            try await session.close()
            throw error
        }
        try await session.close()
    }

    /// A cancelled video's pull gives up at once, but its frame read still
    /// decodes on the reader's queue: the lane stays with it until that read
    /// returns, so the video waiting on the second row starts no reader beside
    /// it; then the second video prepares and is served.
    @Test(.timeLimit(.minutes(3)))
    func aCancelledVideoKeepsTheLaneUntilItsFrameReadReturns() async throws {
        let session = try await VideoRowSession.make()
        let latch = VideoPreparationLatch(holdsFirst: false)
        await session.media.setTestPreparation { _, entering in await latch.observe(entering) }
        let baseline = await session.budget.outstandingReservedBytes()
        let hold = VideoReadHold()
        let first = hold.reading {
            Task { try await session.media.runEncoded(body: session.videoBody,
                plan: NemotronSuperRequestPlan(body: session.videoBody), templateBytes: VideoRowSession.template()) { _ in } }
        }
        var second: Task<Void, Error>?
        do {
            try #require(await hold.started(), "the first video's frame reader never read")
            #expect(await latch.started == 1)
            second = Task { try await session.run(.video) }
            try await superHTTPEventually("both videos charged") {
                await session.budget.outstandingReservedBytes() == baseline + 2 * session.videoCharge
            }
            first.cancel()
            // Time for the cancelled pull, and the request around it, to unwind.
            try await Task.sleep(for: .milliseconds(300))
            #expect(await latch.started == 1, "a preparation started beside a frame read still decoding")
            hold.release()
            await #expect(throws: CancellationError.self) { try await first.value }
            try await second?.value
            #expect(await latch.started == 2)
            #expect(await session.chargesReturn(to: baseline))
        } catch {
            first.cancel(); second?.cancel(); hold.release()
            _ = await first.result; _ = await second?.result
            try await session.close()
            throw error
        }
        try await session.close()
    }

    /// The video switch's off word, the image switch's off word, or an owner
    /// serving fewer than three requests keeps a video exclusive: a second
    /// media request is refused while it runs.
    @Test(.timeLimit(.minutes(3)), arguments: [
        ([videoKey: "off"], 4), ([videoKey: " NO "], 4),
        (["DARKBLOOM_NEMOTRON_SUPER_CONCURRENT_IMAGES": "0"], 4), ([:], 2),
    ] as [([String: String], Int)])
    func switchesOrANarrowOwnerKeepAVideoExclusive(environment: [String: String], width: Int) async throws {
        let session = try await VideoRowSession.make(environment: environment, width: width)
        let latch = VideoPreparationLatch()
        await session.media.setTestPreparation { _, entering in await latch.observe(entering) }
        let first = Task { try await session.run(.video) }
        do {
            try await superHTTPEventually("the video is preparing") { await latch.started == 1 }
            await #expect(throws: Binding.Failure.busy) { try await session.run(.video) }
            await #expect(throws: Binding.Failure.busy) { try await session.run(.image) }
            await latch.release()
            try await first.value
            #expect(await latch.started == 1)
        } catch {
            first.cancel(); await latch.release()
            _ = await first.result
            try await session.close()
            throw error
        }
        try await session.close()
    }

    /// With the video switch off, an active image still refuses a video, as
    /// before.
    @Test(.timeLimit(.minutes(3)))
    func videoSwitchOffRefusesAVideoBesideAnImage() async throws {
        let session = try await VideoRowSession.make(environment: [Self.videoKey: "0"])
        let latch = VideoPreparationLatch()
        await session.media.setTestPreparation { _, entering in await latch.observe(entering) }
        let first = Task { try await session.run(.image) }
        do {
            try await superHTTPEventually("the image is preparing") { await latch.started == 1 }
            await #expect(throws: Binding.Failure.busy) { try await session.run(.video) }
            await latch.release()
            try await first.value
        } catch {
            first.cancel(); await latch.release()
            _ = await first.result
            try await session.close()
            throw error
        }
        try await session.close()
    }

    /// The switch reaches launchd providers.
    @Test func videoSwitchIsForwardedToTheService() {
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(Self.videoKey))
    }
}

/// The tiny batched-decode Super installation (`SuperMTPInstalledFixture`) with
/// the encoded three-channel 16-pixel tower, so one owner serving several
/// requests prepares an image and a square clip; real shared budget.
private struct VideoRowSession: @unchecked Sendable {
    enum Media { case image, video }

    let owner: NemotronSuperLocalBridgeBuilder.Owner
    let media: NemotronSuperLocalImageBinding
    let budget: GlobalKVCacheBudget
    let lease: PendingModelLoadLease
    let fixture: SuperMTPInstalledFixture.Installation
    let videoBody: Data
    let imageBody: Data
    /// Each request's full charge, ingress and media, held until its settlement.
    let videoCharge: UInt64
    let imageCharge: UInt64

    private static let contextLength = 1024

    static func make(environment: [String: String] = [:], width: Int = 4) async throws -> Self {
        let fixture = try SuperMTPInstalledFixture(radioDimensions: SuperMTPInstalledFixture.encodedImageTower).make()
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 16 << 30, active: 0, cache: 0, systemAvailable: .max) })
        let lease = try #require(await budget.claimPendingLoad(requestID: "super-video-rows-" + UUID().uuidString,
            weightBytes: UInt64(fixture.installed.receipt.payloadBytes), minimumKVBytes: 4 << 30))
        var settings = environment
        settings[NemotronSuperLocalBridgeBuilder.maxConcurrentKey] = String(width)
        let owner = try await NemotronSuperLocalBridgeBuilder.make(installed: fixture.installed,
            tokenizer: TokenizerHandle(SuperSyntheticVideoTokenizer()), eosTokenIDs: [],
            sizing: .init(weightsBytes: fixture.installed.receipt.payloadBytes, fp16KVBytesPerToken: 64,
                maxContextLength: contextLength, defaultMaxTokens: 2), kvBytesCapacity: 4 << 30,
            kvBudget: budget, loadLease: lease, construction: fixture.construction, environment: settings)
        let clip = try await MiMoEncodedMediaFixtures.video(frames: 10, fps: 4, width: 64, height: 64)
        let uri = "data:video/mp4;base64," + clip.base64EncodedString()
        let videoBody = try body(["type": "video_url", "video_url": ["url": uri]])
        let imageBody = try body(["type": "image_url", "image_url": ["url":
            "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAF0lEQVR4nGP4z8BAEiJN9aiGUQ1DSgMAkPn/Afnh+ngAAAAASUVORK5CYII=",
        ]])
        let template = try template()
        let video = try await NemotronSuperVideoDecode.inspect(uri)
        let prompt = try owner.localVideoPrompt(plan: NemotronSuperRequestPlan(body: videoBody), body: videoBody,
            templateBytes: template, labels: video.labels)
        let videoPlan = try Binding.encodedVideoPlan(video, prompt: prompt, pruningRate: owner.videoPruningRate,
                                                     contextLength: contextLength)
        let images = try Binding.encodedBody(NemotronSuperRequestPlan(body: imageBody)).images
        let imagePlan = try Binding.encodedPlan(images, contextLength: contextLength)
        let videoCharge = try videoPlan.totalBytes
            + Binding.encodedHeaderQuote(bodyBytes: videoBody.count, templateBytes: template.count)
        let imageCharge = try imagePlan.totalBytes
            + Binding.encodedHeaderQuote(bodyBytes: imageBody.count, templateBytes: template.count)
        return Self(owner: owner, media: try owner.localImageBinding(), budget: budget, lease: lease,
            fixture: fixture, videoBody: videoBody, imageBody: imageBody,
            videoCharge: videoCharge, imageCharge: imageCharge)
    }

    private typealias Binding = NemotronSuperLocalImageBinding

    private static func body(_ part: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "model": NemotronSuperLocalBinding.modelID, "max_tokens": 2, "temperature": 0,
            "messages": [["role": "user", "content": [["type": "text", "text": "fixture"], part]]],
        ], options: [.sortedKeys])
    }

    static func template() throws -> Data {
        try #require(Data(base64Encoded: superImagePinnedTemplateBase64, options: .ignoreUnknownCharacters))
    }

    func run(_ kind: Media) async throws {
        let body = kind == .video ? videoBody : imageBody
        let events = SuperVideoEvents()
        try await media.runEncoded(body: body, plan: NemotronSuperRequestPlan(body: body),
                                   templateBytes: Self.template()) { await events.record($0) }
        #expect(await events.errors.isEmpty)
        #expect(await events.completions == [2])
    }

    /// Whether every request charge returns within ten seconds: a video's
    /// may follow its request, once its reader's queue drains.
    func chargesReturn(to baseline: UInt64) async -> Bool {
        let end = ContinuousClock.now + .seconds(10)
        while await budget.outstandingReservedBytes() != baseline {
            guard ContinuousClock.now < end else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    func close() async throws {
        try await owner.closeAfterDrain()
        #expect(fixture.residency.snapshot.usedBytes == 0)
        #expect(await budget.finishPendingLoad(lease))
        #expect(await budget.outstandingReservedBytes() == 0)
    }
}

/// Observes the preparations entering the lane, how many were inside at once,
/// and (by default) holds the first until released.
private actor VideoPreparationLatch {
    private(set) var started = 0
    private(set) var peak = 0
    private var inside = 0
    private var released: Bool
    private var continuation: CheckedContinuation<Void, Never>?

    init(holdsFirst: Bool = true) { released = !holdsFirst }

    func observe(_ entering: Bool) async {
        guard entering else {
            inside -= 1
            return
        }
        started += 1
        inside += 1
        peak = max(peak, inside)
        if started == 1 && !released {
            await withCheckedContinuation { continuation = $0 }
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

/// Holds the first frame read of the first video's frame reader on its queue
/// (the second reader to read; the first is the compressed-sample pass) until
/// `release()` (a minute at most), as a decoder that has not returned does.
private final class VideoReadHold: @unchecked Sendable {
    private let lock = NSLock()
    private var order = ReaderOrder()
    private let holding = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    /// Runs `body`; the tasks it creates read under this hold.
    func reading<Result>(_ body: () -> Result) -> Result {
        VideoReaderRetry.$beforeReadForTesting.withValue({ self.beforeRead($0) }, operation: body)
    }

    /// Whether a read is held, waiting off the cooperative pool at most a minute.
    func started() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: self.holding.wait(timeout: .now() + 60) == .success)
            }
        }
    }

    func release() { released.signal() }

    private func beforeRead(_ reader: AVAssetReader) {
        let held = lock.withLock { () -> Bool in
            let (ordinal, reads) = order.count(readBy: reader)
            return ordinal == 2 && reads == 1
        }
        guard held else { return }
        holding.signal()
        _ = released.wait(timeout: .now() + 60)
    }
}
