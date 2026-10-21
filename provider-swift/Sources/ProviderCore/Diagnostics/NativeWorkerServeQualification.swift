import Darwin
import Foundation
import ProviderAppAttest

/// Private observations for the opt-in, real serving-loop diagnostic. This does
/// not supply authorization, issue challenges or change assertion scheduling.
final class NativeWorkerServeQualification: @unchecked Sendable {
    static let environmentKey = "DARKBLOOM_NATIVE_WORKER_SERVE_QUALIFICATION"

    struct AssertionEvent: Codable, Sendable {
        let phase: String
        let processID: Int32
        let workerGeneration: UUID
        let sequence: UInt64
        let observedAtNS: UInt64
    }

    struct Snapshot: Codable, Sendable {
        var armedAtNS: UInt64?
        var events: [AssertionEvent] = []
        var timeoutReplyAtNS: UInt64?
        var retiredAtNS: UInt64?
        var successfulAssertions = 0
        var initialWorker: ProcessIdentity?
        var currentWorker: ProcessIdentity?
        var failed = false
    }

    private let lock = NSLock()
    private var state = Snapshot()

    static func selected(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> NativeWorkerServeQualification? {
        guard environment[environmentKey] == "1" else { return nil }
        guard environment[NativeServeQualification.environmentKey] == "1",
              environment[AppAttestWorkerSelection.qualificationEnvironment] == "1" else {
            throw NativeServeQualificationInputs.Failure.optInRequired
        }
        return NativeWorkerServeQualification()
    }

    var snapshot: Snapshot { lock.withLock { state } }

    func recordArmed() { lock.withLock { state.armedAtNS = Self.nowNS() } }

    func observe(_ event: AppAttestWorkerClient.QualificationAssertionEvent) {
        lock.withLock {
            guard state.events.count < 2, event.processID == state.initialWorker?.pid else {
                state.failed = true
                return
            }
            state.events.append(AssertionEvent(phase: event.phase.rawValue, processID: event.processID,
                workerGeneration: event.workerGeneration, sequence: event.sequence, observedAtNS: Self.nowNS()))
        }
    }

    func recordReply(action: String, result: String?, workerPID: Int32?) {
        lock.withLock {
            if action == "ready", result == "ok" {
                guard let workerPID, let identity = ProcessIdentity.read(pid: workerPID), workerPID != getpid() else {
                    state.failed = true
                    return
                }
                if state.initialWorker == nil { state.initialWorker = identity }
                state.currentWorker = identity
            }
            guard action == "assertion" else { return }
            if result == "ok" { state.successfulAssertions += 1 }
            if result == "operation_timeout" {
                state.timeoutReplyAtNS = Self.nowNS()
                // respond() returns an outstanding-operation reply only after
                // its process slot has terminated and reaped the old child.
                guard let initial = state.initialWorker, !initial.isCurrent() else {
                    state.failed = true
                    return
                }
                state.retiredAtNS = Self.nowNS()
            }
        }
    }

    private static func nowNS() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1_000_000_000) }
}

extension ProviderLoop {
    func armNativeWorkerQualificationIfRequested(_ inputs: NativeServeQualificationInputs) async throws {
        guard let observation = nativeWorkerQualification, inputs.workerFaultRequested(),
              observation.snapshot.armedAtNS == nil else { return }
        guard usesAppAttestWorker, !serveUsesHostServices, !isShuttingDown,
              !servingDrain.refusing, modelSlots.count == 1, appAttestShadowTask == nil,
              lastTrustStatus?.authorization?.hasCurrentAppAttestAuthorization(now: Date().timeIntervalSince1970) == true,
              let worker = appAttestWorkerClient as? AppAttestWorkerClient,
              observation.snapshot.successfulAssertions == 1 else { return }
        try await worker.armNextAssertionCallbackDiscardForQualification { event in observation.observe(event) }
        observation.recordArmed()
    }
}
