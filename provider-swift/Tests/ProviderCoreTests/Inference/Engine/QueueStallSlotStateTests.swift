import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

/// An engine whose queue holds a request it never steps on, nothing running:
/// what a native MiMo slot reported for 52 minutes while it accepted and never
/// started every request routed to it. Its heartbeat read idle the whole time,
/// so the coordinator kept routing to it. The clock is passed in; nothing sleeps.
///
/// The same frozen queue is common and harmless on other models (vision
/// encoding counts as waiting, a plan with nothing to assign takes no step):
/// in 7 days of production it held a minute or more about 360 times on 11
/// models and only once on MiMo, the incident. So only a native MiMo slot reads
/// a stalled queue as stopped; a sealed native fault reads stopped on any slot.
@Suite("Queue stall slot state")
struct QueueStallSlotStateTests {
    private static func bridge(_ engine: QueueStallEngine, nativeMiMo: Bool) async -> EngineV2Bridge {
        let bridge = EngineV2Bridge(engine: engine, modelId: "mimo-v2.6-flash-mopd",
            tokenizer: TokenizerHandle(QueueStallTokenizer()), eosTokenIds: [], maxConcurrentRequests: 4)
        if nativeMiMo { await bridge.markNativeMiMoForTesting() }
        return bridge
    }

    @Test("a native MiMo queue the engine never steps on reads crashed after the stall threshold")
    func stalledQueueReadsCrashed() async {
        let engine = QueueStallEngine(waiting: 1, running: 0, steps: 135_944)
        let bridge = await Self.bridge(engine, nativeMiMo: true)
        let start = ContinuousClock.now
        #expect(await bridge.backendSlotCapacity(now: start).state == "idle")
        let early = start + .seconds(WedgeMonitor.suspectQueueStallSeconds - 1)
        #expect(await bridge.backendSlotCapacity(now: early).state == "idle", "a short wait is not a stall")
        let late = start + .seconds(WedgeMonitor.suspectQueueStallSeconds + 1)
        #expect(await bridge.backendSlotCapacity(now: late).state == "crashed",
            "the coordinator must stop routing to a queue that does not move")
        await bridge.shutdown()
    }

    @Test("a native MiMo stall that lasts the recovery threshold is a confirmed wedge")
    func stalledQueueIsAConfirmedWedge() async {
        let engine = QueueStallEngine(waiting: 1, running: 0, steps: 7)
        let bridge = await Self.bridge(engine, nativeMiMo: true)
        let start = ContinuousClock.now
        _ = await bridge.backendSlotCapacity(now: start)
        #expect(!(await bridge.confirmedWedgeForRecovery(
            now: start + .seconds(EngineV2Bridge.recoveryStallSeconds - 1))))
        #expect(await bridge.confirmedWedgeForRecovery(
            now: start + .seconds(EngineV2Bridge.recoveryStallSeconds + 1)),
            "a native MiMo slot retires instead of holding requests")
        await bridge.shutdown()
    }

    @Test("the same frozen queue on a slot that is not native MiMo never reads crashed or recovers")
    func ordinarySlotIgnoresTheQueue() async {
        let engine = QueueStallEngine(waiting: 1, running: 0, steps: 42)
        let bridge = await Self.bridge(engine, nativeMiMo: false)
        let start = ContinuousClock.now
        _ = await bridge.backendSlotCapacity(now: start)
        let late = start + .seconds(EngineV2Bridge.recoveryStallSeconds * 10)
        #expect(await bridge.backendSlotCapacity(now: late).state == "idle",
            "vision encoding or an empty plan holds this queue on healthy slots")
        #expect(!(await bridge.confirmedWedgeForRecovery(now: late)),
            "a rebuild, unload or retirement would cancel healthy work")
        await bridge.shutdown()
    }

    @Test("a sealed native fault reads crashed at once and is a confirmed wedge, on any slot",
        arguments: [false, true])
    func sealedNativeFaultStopsTheSlot(nativeMiMo: Bool) async {
        let engine = QueueStallEngine(waiting: 1, running: 0, steps: 9)
        let bridge = await Self.bridge(engine, nativeMiMo: nativeMiMo)
        let start = ContinuousClock.now
        #expect(await bridge.backendSlotCapacity(now: start).state == "idle")
        engine.sealNativeFault()
        #expect(await bridge.backendSlotCapacity(now: start).state == "crashed",
            "an engine whose native work failed never steps again")
        #expect(await bridge.confirmedWedgeForRecovery(now: start))
        await bridge.shutdown()
    }

    @Test("a step, a running row or an empty queue restarts the stall clock", arguments: [0, 1, 2])
    func progressClearsTheStall(change: Int) async {
        let engine = QueueStallEngine(waiting: 1, running: 0, steps: 10)
        let bridge = await Self.bridge(engine, nativeMiMo: true)
        let start = ContinuousClock.now
        _ = await bridge.backendSlotCapacity(now: start)
        let middle = start + .seconds(WedgeMonitor.suspectQueueStallSeconds - 1)
        switch change {
        case 0: engine.set(waiting: 1, running: 0, steps: 11)
        case 1: engine.set(waiting: 1, running: 1, steps: 10)
        default: engine.set(waiting: 0, running: 0, steps: 10)
        }
        _ = await bridge.backendSlotCapacity(now: middle)
        engine.set(waiting: 1, running: 0, steps: change == 0 ? 11 : 10)
        let late = start + .seconds(WedgeMonitor.suspectQueueStallSeconds + 1)
        #expect(await bridge.backendSlotCapacity(now: late).state != "crashed",
            "the stall is measured from the last sign of progress")
        await bridge.shutdown()
    }
}

private extension EngineV2Bridge {
    /// The marker a native MiMo load transaction sets on its bridge.
    func markNativeMiMoForTesting() { nativeTransactionID = UUID() }
}

/// Reports the queue it is told to, and a sealed native fault once told to;
/// submissions are held and never answered.
private final class QueueStallEngine: CBv2Engine, SealedNativeFaultReporting, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: Int
    private var running: Int
    private var steps: Int
    private var faulted = false

    init(waiting: Int, running: Int, steps: Int) {
        self.waiting = waiting; self.running = running; self.steps = steps
    }

    func set(waiting: Int, running: Int, steps: Int) {
        lock.withLock { self.waiting = waiting; self.running = running; self.steps = steps }
    }

    func sealNativeFault() { lock.withLock { faulted = true } }
    var hasSealedNativeFault: Bool { lock.withLock { faulted } }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        AsyncStream<CBv2Event>.makeStream().stream
    }
    func cancel(_ id: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot {
        lock.withLock {
            .init(activeRequests: running, waitingRequests: waiting, kvBytesInUse: 0, kvBytesCapacity: 0,
                  activeTokens: 0, stepsExecuted: steps)
        }
    }
    func shutdown() async {}
}

private struct QueueStallTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [1] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }; var eosToken: String? { nil }; var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?) throws -> [Int] { [1] }
}
