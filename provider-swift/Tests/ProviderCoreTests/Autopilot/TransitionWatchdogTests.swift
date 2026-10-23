import Foundation
import Testing
@testable import ProviderCore

@Suite("Transition watchdog")
struct TransitionWatchdogTests {
    private typealias Occurrence = TransitionWatchdog.Occurrence
    private let start = ContinuousClock.now

    @Test func boundsExceedTheSlowestHealthyTransition() {
        for transition in [ModelAutopilotTransition.autopilotOperation, .startupPreload, .preload,
                           .modelLoading, .modelAdvertisement, .modelSwitch] {
            #expect(transition.stallBound == .seconds(600))
        }
        for transition in [ModelAutopilotTransition.reslice, .reconnectAfterRetirement] {
            #expect(transition.stallBound == .seconds(300))
        }
    }

    @Test func anOccurrenceStallsOnceWhenItReachesItsBound() {
        var watchdog = TransitionWatchdog()
        let preload = Occurrence(.preload, subject: "model", generation: "task")
        #expect(watchdog.observe([preload], now: start).isEmpty)
        #expect(watchdog.observe([preload], now: start + .seconds(599)).isEmpty)
        #expect(watchdog.report == nil)
        #expect(watchdog.observe([preload], now: start + .seconds(600))
            == [.init(occurrence: preload, age: .seconds(600))])
        #expect(watchdog.observe([preload], now: start + .seconds(900)).isEmpty)
        #expect(watchdog.report == [.init(transition: "preload", count: 1, lastAgeMs: 600_000)])
    }

    @Test func aGapOrANewGenerationStartsAFreshOccurrence() {
        var watchdog = TransitionWatchdog()
        let first = Occurrence(.reslice, generation: "1")
        _ = watchdog.observe([first], now: start)
        // Not observed at one tick: the transition completed in between.
        _ = watchdog.observe([], now: start + .seconds(200))
        #expect(watchdog.observe([first], now: start + .seconds(400)).isEmpty)
        let second = Occurrence(.reslice, generation: "2")
        #expect(watchdog.observe([first, second], now: start + .seconds(650)).isEmpty)
        #expect(watchdog.observe([first, second], now: start + .seconds(700)).map(\.occurrence) == [first])
        #expect(watchdog.observe([second], now: start + .seconds(950)).map(\.occurrence) == [second])
        #expect(watchdog.report == [.init(transition: "reslice", count: 2, lastAgeMs: 300_000)])
    }

    @Test func stallsArriveInTransitionOrderAndCountsSurviveForgetting() {
        var watchdog = TransitionWatchdog()
        let active: Set<Occurrence> = [Occurrence(.modelLoading, subject: "b"), Occurrence(.startupPreload, subject: "a"),
                                       Occurrence(.modelLoading, subject: "a")]
        _ = watchdog.observe(active, now: start)
        let stalls = watchdog.observe(active, now: start + .seconds(600)).map(\.occurrence)
        #expect(stalls == [Occurrence(.startupPreload, subject: "a"), Occurrence(.modelLoading, subject: "a"),
                           Occurrence(.modelLoading, subject: "b")])
        watchdog.forgetOccurrences()
        #expect(watchdog.observe(active, now: start + .seconds(1_200)).isEmpty)
        #expect(watchdog.report?.map(\.transition) == ["startup_preload", "model_loading"])
        #expect(watchdog.report?.map(\.count) == [1, 2])
    }

    @Test func continuityRestartsAfterAMissingObservation() {
        var clock = ContinuityClock<String, Int>()
        clock.observe(["a", "b"], at: 1)
        clock.observe(["a"], at: 2)
        #expect(clock.since("a") == 1)
        #expect(clock.since("b") == nil)
        clock.observe(["a", "b"], at: 3)
        #expect(clock.since("b") == 3)
    }

    @Test func millisecondsClampAndSaturate() {
        #expect(Duration.seconds(-5).autopilotMilliseconds == 0)
        #expect(Duration.milliseconds(-500).autopilotMilliseconds == 0)
        #expect(Duration.milliseconds(1_234).autopilotMilliseconds == 1_234)
        #expect(Duration.seconds(Int64.max).autopilotMilliseconds == .max)
    }
}

@Suite("Transition watchdog supervision", .serialized)
struct TransitionWatchdogSupervisionTests {
    private typealias Fixture = AutopilotPlacementFixture

    @Test func stalledStartupPreloadStopsBeforeItsNextModelWithoutInterruptingIt() async throws {
        let fixture = try await Fixture.make(resident: []) {
            $0.preloadModels = [Fixture.ordinary, "second-ordinary"]
            $0.startupPreloadTimeoutSecs = 1
            $0.startupSelftest = false
        }
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        await loop.advertiseOrdinaryForWatchdogTesting("second-ordinary")
        await loop.setStartupPreloadFreeMemoryOverrideForTesting { 1_000 }
        let loads = StartupLoadLog()
        let (release, releaseNow) = AsyncStream<Void>.makeStream()
        // The first load outlives the bound but is healthy: it finishes when released.
        await loop.setStartupPreloadLoadOverrideForTesting { model in
            loads.started(model)
            if model == Fixture.ordinary { for await _ in release { break } }
            loads.finished(cancelled: Task.isCancelled)
        }
        #expect(await loop.runStartupPreloadGateForTesting() == .timedOut)
        #expect(await loop.autopilotBusyReasons() == [.startupPreload])

        let start = ContinuousClock.now
        await loop.superviseTransitions(now: start)
        await loop.superviseTransitions(now: start + .seconds(599))
        #expect(await loop.startupPreloadTaskRunningForTesting())
        await loop.superviseTransitions(now: start + .seconds(601))
        releaseNow.yield(())
        #expect(await modelLoadingWaitUntil { await !loop.startupPreloadTaskRunningForTesting() })
        #expect(loads.models == [Fixture.ordinary])
        #expect(loads.cancellations == [false])
        #expect(await loop.autopilotBusyReasons().isEmpty)
        await loop.publishModelAutopilotSnapshot()
        #expect(await loop.state.modelAutopilot?.transitionStalls
            == [.init(transition: "startup_preload", count: 1, lastAgeMs: 601_000)])
    }

    @Test func stalledPreloadIsAnsweredButNeverInterrupted() async throws {
        let fixture = try await Fixture.make(resident: [])
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        // Another owner's load of the same model outlives the bound.
        await loop.modelLoadingMarkLoading(Fixture.ordinary)
        let replies = AutopilotRecorder()
        await loop.handleLoadModelRequest(modelId: Fixture.ordinary, send: SendHandle(replies.append))
        #expect(await modelLoadingWaitUntil { await loop.modelLoadingLoadingWaiterCount(Fixture.ordinary) == 1 })

        let start = ContinuousClock.now
        await loop.superviseTransitions(now: start)
        await loop.superviseTransitions(now: start + .seconds(600))
        #expect(replies.legacyStatuses == [.started, .failed])
        #expect(replies.legacyErrors.last == "transition_stalled")
        // Only the coordinator's tracking ended; the load keeps its fence.
        #expect(await loop.autopilotBusyReasons() == [.modelLoading])
        #expect(await loop.modelLoadingInFlightIDs() == [Fixture.ordinary])

        // A new request starts a fresh preload. When the load finally
        // installs its slot, both preloads finish normally, and only the new
        // one reports.
        await loop.handleLoadModelRequest(modelId: Fixture.ordinary, send: SendHandle(replies.append))
        #expect(await modelLoadingWaitUntil { await loop.modelLoadingLoadingWaiterCount(Fixture.ordinary) == 2 })
        await loop.modelLoadingInstallSlot(Fixture.ordinary, bridge: EngineV2Bridge(engine: InertStubEngine(),
            modelId: Fixture.ordinary, tokenizer: TokenizerHandle(StubBridgeTokenizer()), eosTokenIds: []))
        await loop.modelLoadingClearLoading(Fixture.ordinary)
        await loop.modelLoadingResumeLoadingWaiters(Fixture.ordinary)
        #expect(await modelLoadingWaitUntil { await loop.autopilotBusyReasons().isEmpty })
        #expect(replies.legacyStatuses == [.started, .failed, .started, .succeeded])
    }

    @Test(arguments: [ModelAutopilotTransition.modelLoading, .modelAdvertisement, .modelSwitch, .reslice,
                      .reconnectAfterRetirement])
    func otherTransitionsAreCountedButNeverInterrupted(transition: ModelAutopilotTransition) async throws {
        let fixture = try await Fixture.make(resident: [])
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        let reason: ModelAutopilotBusyReason = switch transition {
        case .modelLoading: .loadGate
        case .modelAdvertisement: .pendingAdvertisement
        case .modelSwitch: .modelSwitch
        case .reslice: .reslice
        default: .reconnectAfterRetirement
        }
        await loop.raiseBusyFlagForTesting(reason)
        let start = ContinuousClock.now
        await loop.superviseTransitions(now: start)
        await loop.superviseTransitions(now: start + transition.stallBound)
        await loop.publishModelAutopilotSnapshot()
        #expect(await loop.state.modelAutopilot?.transitionStalls?.map(\.transition) == [transition.rawValue])
        #expect(await loop.autopilotBusyReasons() == [reason])
        await loop.lowerBusyFlagForTesting(reason)
    }

    @Test func withoutConsentTheWatchdogNeitherActsNorReports() async throws {
        let fixture = try await Fixture.make(consent: false, resident: [])
        defer { Task { await fixture.remove() } }
        let loop = fixture.loop
        let driver = Task { _ = try? await Task.sleep(for: .seconds(3_600)) }
        await loop.installStartupDriverForTesting(driver)
        let start = ContinuousClock.now
        await loop.superviseTransitions(now: start)
        await loop.superviseTransitions(now: start + .seconds(3_600))
        #expect(driver.isCancelled == false)
        await loop.publishModelAutopilotSnapshot()
        #expect(await loop.state.modelAutopilot?.transitionStalls == nil)
        driver.cancel()
        await loop.installStartupDriverForTesting(nil)
    }
}

/// The startup loads a scripted driver began, and whether each saw cancellation.
private final class StartupLoadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var startedModels: [String] = []
    private var cancellationFlags: [Bool] = []
    func started(_ model: String) { lock.withLock { startedModels.append(model) } }
    func finished(cancelled: Bool) { lock.withLock { cancellationFlags.append(cancelled) } }
    var models: [String] { lock.withLock { startedModels } }
    var cancellations: [Bool] { lock.withLock { cancellationFlags } }
}

private extension ProviderLoop {
    func installStartupDriverForTesting(_ task: Task<Void, Never>?) { startupPreloadTask = task }
    func advertiseOrdinaryForWatchdogTesting(_ id: String) {
        ordinaryServingModelIDs.insert(id)
        advertisedModels[id] = AutopilotPlacementFixture.model(id)
    }
}
