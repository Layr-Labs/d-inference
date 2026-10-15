import Foundation

/// At most one genuine snapshot for entry→owner→entry, or a standalone check.
/// Created inside a synchronous check and invalidated in its defer. Never held
/// by a model, wire, session, resource owner, timer, or async closure.
final class Gemma4BenchmarkGuardObservation {
    private var invocation: Gemma4BenchmarkGuardInvocation
    private var observation: QwenDenseStageLoadOSObservation?

    init(mode: Gemma4BenchmarkGuardInvocation.Mode, deadline: UInt64) {
        invocation = .init(mode: mode, deadline: deadline,
            created: DispatchTime.now().uptimeNanoseconds,
            maximumAge: QwenDenseStageLoadPolicy.maximumObservationAgeNanoseconds)
    }
    func read(for consumer: Gemma4BenchmarkGuardInvocation.Consumer, deadline: UInt64,
              observationTiming: ((UInt64) -> Void)?) throws -> QwenDenseStageLoadOSObservation {
        do {
            try invocation.preflight(consumer, expectedDeadline: deadline,
                                     now: DispatchTime.now().uptimeNanoseconds)
            // The first reader is the existing native environment/OS reader.
            // No externally supplied observation or reader callback is accepted.
            let value: QwenDenseStageLoadOSObservation
            if let observation { value = observation }
            else { value = try QwenResidentResourceEnvironment.observe(observationTiming: observationTiming) }
            let now = DispatchTime.now().uptimeNanoseconds
            try QwenDenseStageLoadPolicy.requireInitial(value, now: now)
            try invocation.accept(consumer, started: value.startedNanoseconds,
                completed: value.completedNanoseconds, expectedDeadline: deadline, now: now)
            observation = value
            return value
        } catch { close(); throw error }
    }
    func finish(deadline: UInt64) throws {
        do {
            try invocation.finish(expectedDeadline: deadline, now: DispatchTime.now().uptimeNanoseconds)
            observation = nil
        } catch { close(); throw error }
    }
    func close() { invocation.close(); observation = nil }
    deinit { close() }
}
