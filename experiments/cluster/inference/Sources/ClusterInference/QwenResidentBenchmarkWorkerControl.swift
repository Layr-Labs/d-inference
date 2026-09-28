import Foundation

/// Synchronous control only. Native ownership stays inside the solo/rank owner.
/// Decode, permission and publication failures poison this controller forever.
final class QwenResidentBenchmarkWorkerControl {
    private var sequence: QwenResidentBenchmarkWorkerSequence
    private let steps: [QwenLongPrefillResidentRequestStep]
    private let read: () throws -> Data?
    private let output: QwenResidentBenchmarkWorkerOutput
    private let check: () throws -> Void
    private let role: String
    private var rank: Int?
    private var ready = false
    private var released = false
    private var pending: QwenResidentBenchmarkWorkerRun?
    private var busy = false

    init(open: QwenResidentBenchmarkWorkerOpen, steps: [QwenLongPrefillResidentRequestStep],
         role: String, read: @escaping () throws -> Data?, output: QwenResidentBenchmarkWorkerOutput,
         check: @escaping () throws -> Void) throws {
        try QwenLongPrefillResidentRequestStep.validate(steps)
        guard steps.count == QwenResidentBenchmarkWorkerCommand.requestCount,
              steps.enumerated().allSatisfy({ $0.element.excludedWarmup == ($0.offset == 0) }),
              ["solo", "rank"].contains(role) else {
            throw ProbeError("Resident worker controller requires its exact four-request cohort")
        }
        sequence = try .init(open: open)
        guard zip(steps, open.requests).allSatisfy({ step, request in
            step.requestID.uuidString.lowercased().replacingOccurrences(of: "-", with: "") == request.epoch
        }) else { throw ProbeError("Resident worker native UUID differs from its predeclared epoch") }
        self.steps = steps; self.role = role; self.read = read; self.output = output; self.check = check
    }

    func modelReady<T: Encodable>(_ record: T, rank: Int?) throws {
        try guarded {
            guard !ready, !released, pending == nil,
                  role == "solo" ? rank == nil : rank == 0 || rank == 1 else {
                throw ProbeError("Resident worker loaded-ready order or rank differs")
            }
            self.rank = rank
            try publish("ready", record)
            ready = true
        }
    }

    func permit(_ step: QwenLongPrefillResidentRequestStep) throws {
        try guarded {
            guard ready, !released, pending == nil, sequence.completedRequests < steps.count,
                  steps[sequence.completedRequests] == step else {
                throw ProbeError("Resident worker requested an unexpected native step")
            }
            guard let command = try sequence.accept(command: next()),
                  command.sequence == step.ordinal + 1 else {
                throw ProbeError("Resident worker expected one matching run permission")
            }
            pending = command
        }
    }

    func result<T: Encodable>(_ step: QwenLongPrefillResidentRequestStep,
                             record: (QwenResidentBenchmarkWorkerRun) throws -> T) throws {
        try guarded {
            guard ready, !released, let command = pending,
                  sequence.completedRequests < steps.count,
                  steps[sequence.completedRequests] == step else {
                throw ProbeError("Resident worker result lacks a matching permitted step")
            }
            // The caller must already have exited native request/lifecycle scopes.
            try publish("result", record(command))
            try sequence.complete(request: command)
            pending = nil
        }
    }

    func modelReleased<T: Encodable>(_ record: T) throws {
        try guarded {
            guard ready, !released, pending == nil, sequence.completedRequests == steps.count else {
                throw ProbeError("Resident worker release preceded four published results")
            }
            try publish("released", record)
            released = true
        }
    }

    func shutdown<T: Encodable>(_ record: T) throws {
        try guarded {
            guard released, pending == nil,
                  try sequence.accept(command: next()) == nil, sequence.isStopped else {
                throw ProbeError("Resident worker requires shutdown after actual model release")
            }
            try publish("stopped", record)
        }
    }

    func fail() { sequence.fail() }

    private func next() throws -> QwenResidentBenchmarkWorkerCommand {
        try checked()
        guard let bytes = try read() else { throw ProbeError("Resident worker stdin ended before its next command") }
        try checked()
        return try .decode(bytes)
    }

    private func publish<T: Encodable>(_ type: String, _ record: T) throws {
        try output.publish(QwenResidentBenchmarkWorkerEvent(type: type,
            cohortID: sequence.open.cohortID, role: role, rank: rank, record: record), check: checked)
    }

    private func checked() throws {
        guard !sequence.failed else { throw ProbeError("Resident worker controller already failed") }
        try check()
        guard !sequence.failed else { throw ProbeError("Resident worker controller failed during its check") }
    }

    private func guarded(_ body: () throws -> Void) throws {
        do {
            guard !sequence.failed, !busy else { throw ProbeError("Resident worker controller failed or was reentered") }
            busy = true
            defer { busy = false }
            try checked(); try body(); try checked()
            guard !sequence.failed else { throw ProbeError("Resident worker controller failed during a callback") }
        } catch { sequence.fail(); throw error }
    }
}
