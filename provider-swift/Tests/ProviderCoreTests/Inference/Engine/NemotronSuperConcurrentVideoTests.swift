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

    /// A row that finds the lane held reports the wait as it begins, once, so
    /// a row cancelled in the wait is no evidence of the owner's pace alone.
    @Test(.timeLimit(.minutes(3)))
    func aLaneWaitIsReportedAsItBeginsEvenIfCancelled() async throws {
        let session = try await VideoRowSession.make()
        let latch = VideoPreparationLatch()
        await session.media.setTestPreparation { _, entering in await latch.observe(entering) }
        let waits = LaneWaitCount()
        let first = Task { try await session.run(.video) }
        var second: Task<Void, Error>?
        do {
            try await superHTTPEventually("first video holds the preparation lane") { await latch.started == 1 }
            second = Task { try await session.media.runEncoded(body: session.videoBody,
                plan: NemotronSuperRequestPlan(body: session.videoBody), templateBytes: VideoRowSession.template(),
                laneWaited: { waits.increment() }) { _ in } }
            try await superHTTPEventually("the waiting row reports its wait") { waits.value == 1 }
            second?.cancel()
            await #expect(throws: CancellationError.self) { try await second?.value }
            #expect(waits.value == 1)
            await latch.release()
            try await first.value
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
        let first = hold.reading { Task { try await session.runQuietly(.video) } }
        var second: Task<Void, Error>?
        do {
            try #require(await hold.started(), "the first video's frame reader never read")
            let holder = try #require(await session.media.preparingRequestForTesting)
            second = Task { try await session.run(.video) }
            try await heldReadEventually("both videos charged") {
                await session.budget.outstandingReservedBytes() == baseline + 2 * session.videoCharge
            }
            first.cancel()
            // The cancelled preparation has unwound, and only the held read
            // keeps the lane: the second has not entered preparation.
            try await superHTTPEventually("the first's preparation unwound; its read keeps the lane") {
                await session.media.laneDrainingForTesting
            }
            #expect(await session.media.preparingRequestForTesting == holder)
            #expect(await latch.started == 1)
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

    /// A row waiting behind a lane that only a stuck frame read keeps is
    /// refused (`busy`) after `videoReaderDrainWait`, with its charges back;
    /// the lane stays with the read until it returns.
    @Test(.timeLimit(.minutes(3)))
    func aWaitBehindAStuckFrameReadIsRefusedAndRefunded() async throws {
        let session = try await VideoRowSession.make()
        let baseline = await session.budget.outstandingReservedBytes()
        let hold = VideoReadHold()
        let first = hold.reading { Task { try await session.runQuietly(.video) } }
        do {
            try #require(await hold.started(), "the first video's frame reader never read")
            let holder = try #require(await session.media.preparingRequestForTesting)
            first.cancel()
            await #expect(throws: CancellationError.self) { try await first.value }
            await #expect(throws: Binding.Failure.busy) { try await session.runQuietly(.video) }
            #expect(await session.media.preparingRequestForTesting == holder)
            // Only the stuck read's own two charges (ingress and media) remain.
            #expect(await session.budget.outstandingReservedBytes() == baseline + session.videoCharge)
            hold.release()
            #expect(await session.chargesReturn(to: baseline))
            try await session.run(.video)
        } catch {
            first.cancel(); hold.release()
            _ = await first.result
            try await session.close()
            throw error
        }
        try await session.close()
    }

    /// Closing the owner while a frame read is stuck and a second row waits:
    /// the close returns with only the stuck read's two charges left, and
    /// those return once the read does.
    @Test(.timeLimit(.minutes(3)))
    func closeWithAStuckFrameReadKeepsOnlyItsCharges() async throws {
        let session = try await VideoRowSession.make()
        let baseline = await session.budget.outstandingReservedBytes()
        let hold = VideoReadHold()
        let first = hold.reading { Task { try await session.runQuietly(.video) } }
        var second: Task<Void, Error>?
        do {
            try #require(await hold.started(), "the first video's frame reader never read")
            second = Task { try await session.runQuietly(.video) }
            try await heldReadEventually("both videos charged") {
                await session.budget.outstandingReservedBytes() == baseline + 2 * session.videoCharge
            }
            try await session.owner.closeAfterDrain()
            _ = await first.result; _ = await second?.result
            let held = await session.budget.reservationBytesSnapshot()
            #expect(held.keys.filter { $0.hasPrefix("super-local-encoded-") }.count == 2)
            hold.release()
            let end = ContinuousClock.now + .seconds(10)
            while !(await session.budget.reservationBytesSnapshot().keys
                .filter { $0.hasPrefix("super-local-encoded-") }.isEmpty), ContinuousClock.now < end {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await session.budget.reservationBytesSnapshot().keys
                .filter { $0.hasPrefix("super-local-encoded-") }.isEmpty)
            #expect(session.fixture.residency.snapshot.usedBytes == 0)
            #expect(await session.budget.finishPendingLoad(session.lease))
            #expect(await session.budget.outstandingReservedBytes() == 0)
        } catch {
            first.cancel(); second?.cancel(); hold.release()
            _ = await first.result; _ = await second?.result
            try? await session.owner.closeAfterDrain()
            throw error
        }
    }

    /// A retained fault in one row's preparation (synthetic: the test seam
    /// treats its failure as a failed fence) quarantines the owner: the video
    /// already in the engine is cancelled before the engine takes another
    /// step, its charges stay with the quarantine, and the owner refuses new
    /// work.
    @Test(.timeLimit(.minutes(3)))
    func aRetainedFaultStopsTheSubmittedRowAndKeepsItsCharges() async throws {
        let session = try await VideoRowSession.make()
        let latch = VideoPreparationLatch(holdsSecond: true)
        await session.media.setTestPreparation { _, entering in await latch.observe(entering) }
        let terminals = VideoNativeTerminals()
        await session.owner.bridge._testInstallPersistentTerminalGate { await terminals.record($0) }
        let engine = try #require(await session.owner.bridge.ownedEngine as? EngineV2)
        let loop = engine.loopForTesting
        loop.onEngineQueueSync { loop.suspendStepExecutionAtCountForTesting = 0 }
        let baseline = await session.budget.outstandingReservedBytes()
        let submitted = Task { try await session.runQuietly(.video) }
        var faulting: Task<Void, Error>?
        do {
            try await superHTTPEventually("the first video reaches the frozen native loop") {
                loop.onEngineQueueSync { loop.scheduler.runningCount + loop.scheduler.waitingCount == 1 }
            }
            faulting = Task { try await session.runQuietly(.video) }
            try await superHTTPEventually("the second video is preparing") { await latch.started == 2 }
            await session.media.setTestRetainedFault(true)
            faulting?.cancel()
            await latch.release()
            await #expect(throws: Binding.Failure.retainedFault) { try await faulting?.value }
            #expect(session.owner.hasRetainedImageFault)
            #expect(session.owner.bridge.retainedFaultFence.isClosed)
            loop.onEngineQueueSync { loop.suspendStepExecutionAtCountForTesting = nil }
            _ = await submitted.result
            try await superHTTPEventually("the submitted row left the engine") {
                loop.onEngineQueueSync { loop.scheduler.runningCount + loop.scheduler.waitingCount == 0 }
            }
            // Cancelled before the thaw: the row ended at its first step
            // boundary with no token, where a running one would have made two.
            try await superHTTPEventually("the submitted row's native terminal") { await terminals.count == 1 }
            #expect(await terminals.completionTokens == [0])
        } catch {
            submitted.cancel(); faulting?.cancel(); await latch.release()
            loop.onEngineQueueSync { loop.suspendStepExecutionAtCountForTesting = nil }
            _ = await submitted.result; _ = await faulting?.result
            throw error
        }
        // Both requests' native work started: their charges stay quarantined.
        #expect(await session.budget.outstandingReservedBytes() == baseline + 2 * session.videoCharge)
        #expect(throws: NemotronSuperLocalBridgeBuilder.Failure.retirementIncomplete) {
            _ = try session.owner.localImageBinding()
        }
    }

    /// A peer whose preparation has finished is inside the bridge's
    /// submission when the other row's retained fault is published, and goes
    /// on before the bridge cancels its committed rows: the submission fence
    /// the quarantine closed refuses it before the engine sees it.
    @Test(.timeLimit(.minutes(3)))
    func aRetainedFaultRefusesAPreparedPeerBeforeTheEngine() async throws {
        let session = try await VideoRowSession.make()
        let latch = VideoPreparationLatch(holdsSecond: true)
        await session.media.setTestPreparation { _, entering in await latch.observe(entering) }
        let bridge = session.owner.bridge
        let engine = try #require(await bridge.ownedEngine as? EngineV2)
        let loop = engine.loopForTesting
        loop.onEngineQueueSync { loop.suspendStepExecutionAtCountForTesting = 0 }
        let submission = SuperHTTPTerminalGate(), quarantine = SuperHTTPTerminalGate()
        await bridge._testInstallPreSubmitGate { await submission.hold() }
        await session.media.setTestQuarantine { await quarantine.hold() }
        let baseline = await session.budget.outstandingReservedBytes()
        let events = SuperVideoEvents()
        let peer = Task { try await session.run(.video, recordingInto: events) }
        var faulting: Task<Void, Error>?
        do {
            try await superHTTPEventually("the prepared peer is held in the bridge's submission") {
                await submission.entered
            }
            faulting = Task { try await session.runQuietly(.video) }
            try await superHTTPEventually("the second video is preparing") { await latch.started == 2 }
            await session.media.setTestRetainedFault(true)
            faulting?.cancel()
            await latch.release()
            try await superHTTPEventually("the fault is published, its rows not yet cancelled") {
                await quarantine.entered
            }
            #expect(bridge.retainedFaultFence.isClosed)
            await submission.release()
            try await superHTTPEventually("the peer is refused or reaches the engine") {
                let refused = await !events.errors.isEmpty
                return refused
                    || loop.onEngineQueueSync { loop.scheduler.runningCount + loop.scheduler.waitingCount > 0 }
            }
            let engineRows = loop.onEngineQueueSync { loop.scheduler.runningCount + loop.scheduler.waitingCount }
            try #require(engineRows == 0, "the engine took the peer after the fault was published")
            #expect(await bridge._testMappedRequestCount() == 0)
            try await peer.value
            #expect(await events.errors == ["request queue full: engine is shutting down"])
            #expect(await events.completions.isEmpty)
            await quarantine.release()
            await #expect(throws: Binding.Failure.retainedFault) { try await faulting?.value }
        } catch {
            peer.cancel(); faulting?.cancel(); await latch.release()
            await submission.release(); await quarantine.release()
            loop.onEngineQueueSync { loop.suspendStepExecutionAtCountForTesting = nil }
            _ = await peer.result; _ = await faulting?.result
            throw error
        }
        loop.onEngineQueueSync { loop.suspendStepExecutionAtCountForTesting = nil }
        // Both requests prepared: their charges stay with the quarantine.
        #expect(await session.budget.outstandingReservedBytes() == baseline + 2 * session.videoCharge)
    }

    /// The same fault while a charged row only waits for the lane: the waiter
    /// is stopped and, having started no native work, gets its charges back.
    @Test(.timeLimit(.minutes(3)))
    func aRetainedFaultRefundsTheRowWaitingForTheLane() async throws {
        let session = try await VideoRowSession.make()
        let latch = VideoPreparationLatch()
        await session.media.setTestPreparation { _, entering in await latch.observe(entering) }
        let baseline = await session.budget.outstandingReservedBytes()
        let faulting = Task { try await session.runQuietly(.video) }
        var waiting: Task<Void, Error>?
        do {
            try await superHTTPEventually("the first video holds the preparation lane") { await latch.started == 1 }
            waiting = Task { try await session.runQuietly(.video) }
            try await superHTTPEventually("both videos charged") {
                await session.budget.outstandingReservedBytes() == baseline + 2 * session.videoCharge
            }
            await session.media.setTestRetainedFault(true)
            faulting.cancel()
            await latch.release()
            await #expect(throws: Binding.Failure.retainedFault) { try await faulting.value }
            _ = await waiting?.result
            #expect(await latch.started == 1)
        } catch {
            faulting.cancel(); waiting?.cancel(); await latch.release()
            _ = await faulting.result; _ = await waiting?.result
            throw error
        }
        // Only the faulting request's charges stay.
        #expect(await session.chargesReturn(to: baseline + session.videoCharge))
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

    /// One request whose outcome the caller judges (it may be cancelled or refused).
    func runQuietly(_ kind: Media) async throws {
        let body = kind == .video ? videoBody : imageBody
        try await media.runEncoded(body: body, plan: NemotronSuperRequestPlan(body: body),
                                   templateBytes: Self.template()) { _ in }
    }

    func run(_ kind: Media) async throws {
        let events = SuperVideoEvents()
        try await run(kind, recordingInto: events)
        #expect(await events.errors.isEmpty)
        #expect(await events.completions == [2])
    }

    /// One request whose events the caller judges.
    func run(_ kind: Media, recordingInto events: SuperVideoEvents) async throws {
        let body = kind == .video ? videoBody : imageBody
        try await media.runEncoded(body: body, plan: NemotronSuperRequestPlan(body: body),
                                   templateBytes: Self.template()) { await events.record($0) }
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

    /// Which preparation the latch holds (1-based), if any.
    private let held: Int?

    init(holdsFirst: Bool = true, holdsSecond: Bool = false) {
        held = holdsSecond ? 2 : holdsFirst ? 1 : nil
        released = held == nil
    }

    func observe(_ entering: Bool) async {
        guard entering else {
            inside -= 1
            return
        }
        started += 1
        inside += 1
        peak = max(peak, inside)
        if started == held && !released {
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

/// The native terminals' usage, in order.
private actor VideoNativeTerminals {
    private var usages: [CBv2Usage] = []
    var count: Int { usages.count }
    var completionTokens: [Int] { usages.map(\.completionTokens) }
    func record(_ usage: CBv2Usage) { usages.append(usage) }
}

/// `superHTTPEventually` within two seconds, for the preconditions taken
/// while a frame read is held: well inside the fixture's decode allowance,
/// so a slow runner fails them instead of turning the case into a decoder
/// timeout.
private func heldReadEventually(_ description: String,
                                _ predicate: @escaping @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !(await predicate()), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(await predicate(), "Timed out waiting for \(description)")
}

private final class LaneWaitCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
