import Darwin
import Dispatch
import Foundation

struct ResidentLifecycleOverlapResult: Encodable {
    let joinedThreads: Int
    let requestContenderRefusedWhileActive: Bool
    let releaseContenderRefusedWhileActive: Bool
}

private enum OverlapFailure: Error {
    case assertion(String), posix(Int32), waitExpired
}

private final class OverlapContext {
    enum Contender { case request, release }
    let gate: QwenLayerStageResidentLifecycle
    let contender: Contender
    let entered = DispatchSemaphore(value: 0)
    let allowReturn = DispatchSemaphore(value: 0)
    let firstDone = DispatchSemaphore(value: 0)
    let contenderDone = DispatchSemaphore(value: 0)
    private let resultLock = NSLock()
    private var firstSucceeded = false
    private var contenderSucceeded = false
    private var contenderBodyRan = false

    init(_ contender: Contender) throws {
        self.contender = contender
        gate = try .init(maximumRequests: 2)
    }

    private func identity() -> QwenLayerStageResidentRequestIdentity {
        .init(requestID: UUID(), epoch: UUID(), recordedRequestFingerprint: String(repeating: "a", count: 64))
    }

    func runFirst() {
        do {
            try gate.withRequest(identity: identity()) {
                entered.signal()
                guard allowReturn.wait(timeout: .now() + .seconds(5)) == .success else {
                    throw OverlapFailure.waitExpired
                }
            }
            resultLock.lock(); firstSucceeded = true; resultLock.unlock()
        } catch {}
        // Nothing that waits for the other thread follows this signal.
        firstDone.signal()
    }

    func runContender() {
        do {
            func body() {
                resultLock.lock(); contenderBodyRan = true; resultLock.unlock()
            }
            switch contender {
            case .request: try gate.withRequest(identity: identity(), body)
            case .release: try gate.withModelRelease(body)
            }
            resultLock.lock(); contenderSucceeded = true; resultLock.unlock()
        } catch {}
        contenderDone.signal()
    }

    func bothRefused() -> Bool {
        resultLock.lock(); defer { resultLock.unlock() }
        return !firstSucceeded && !contenderSucceeded && !contenderBodyRan
    }
}

private final class OverlapThreadPayload {
    let context: OverlapContext
    let first: Bool
    init(_ context: OverlapContext, first: Bool) { self.context = context; self.first = first }
}

private func overlapThreadMain(_ pointer: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    guard let pointer else { return nil }
    let payload = Unmanaged<OverlapThreadPayload>.fromOpaque(pointer).takeRetainedValue()
    if payload.first { payload.context.runFirst() } else { payload.context.runContender() }
    return nil
}

private func startOverlapThread(_ context: OverlapContext, first: Bool) throws -> pthread_t {
    let retained = Unmanaged.passRetained(OverlapThreadPayload(context, first: first))
    var thread: pthread_t?
    let status = pthread_create(&thread, nil, overlapThreadMain, retained.toOpaque())
    guard status == 0 else { retained.release(); throw OverlapFailure.posix(status) }
    guard let thread else { throw OverlapFailure.assertion("pthread_create returned no handle") }
    return thread
}

private func joinCompletedThread(_ thread: pthread_t) throws {
    // Called only after the thread's final completion signal. pthread_join is
    // an actual join, not inference from a sleep or a Foundation isFinished flag.
    let status = pthread_join(thread, nil)
    guard status == 0 else { throw OverlapFailure.posix(status) }
}

private func checkOverlap(_ contender: OverlapContext.Contender) throws -> Int {
    let context = try OverlapContext(contender)
    let first = try startOverlapThread(context, first: true)
    guard context.entered.wait(timeout: .now() + .seconds(5)) == .success else {
        context.allowReturn.signal()
        if context.firstDone.wait(timeout: .now() + .seconds(5)) == .success { try joinCompletedThread(first) }
        throw OverlapFailure.assertion("First request did not enter its controlled body")
    }
    let second: pthread_t
    do { second = try startOverlapThread(context, first: false) }
    catch {
        context.allowReturn.signal()
        if context.firstDone.wait(timeout: .now() + .seconds(5)) == .success { try joinCompletedThread(first) }
        throw error
    }
    // The controller can always release the first body even if a broken gate
    // queues the contender. Do not call the contender synchronously here.
    let refusedBeforeRelease = context.contenderDone.wait(timeout: .now() + .seconds(2)) == .success
    let activeWhenContenderReturned = refusedBeforeRelease && context.gate.snapshot.requestScopeActive
    context.allowReturn.signal()
    let firstFinished = context.firstDone.wait(timeout: .now() + .seconds(5)) == .success
    let secondFinished = refusedBeforeRelease || context.contenderDone.wait(timeout: .now() + .seconds(5)) == .success
    var joined = 0
    var joinError: Error?
    if firstFinished {
        do { try joinCompletedThread(first); joined += 1 } catch { joinError = error }
    }
    if secondFinished {
        do { try joinCompletedThread(second); joined += 1 } catch { if joinError == nil { joinError = error } }
    }
    if let joinError { throw joinError }
    guard firstFinished, secondFinished, joined == 2 else { throw OverlapFailure.waitExpired }
    guard refusedBeforeRelease, activeWhenContenderReturned, context.bothRefused(), context.gate.snapshot.failed,
          context.gate.snapshot.admittedRequests == 1, context.gate.snapshot.completedRequestScopes == 0,
          !context.gate.snapshot.requestScopeActive else {
        throw OverlapFailure.assertion("Overlap did not refuse and poison the active request")
    }
    try context.gate.withModelRelease {}
    guard context.gate.snapshot.releaseCallbackCompleted, context.gate.snapshot.failed else {
        throw OverlapFailure.assertion("Cleanup erased the overlap failure")
    }
    return joined
}

/// Standalone CPU fixture only. pthread boundaries avoid asserting Sendable for
/// a real private model owner. Mutable fixture results and gate fields use locks.
func checkResidentLifecycleOverlap() throws -> ResidentLifecycleOverlapResult {
    let requestJoins = try checkOverlap(.request)
    let releaseJoins = try checkOverlap(.release)
    return .init(joinedThreads: requestJoins + releaseJoins,
        requestContenderRefusedWhileActive: true, releaseContenderRefusedWhileActive: true)
}
