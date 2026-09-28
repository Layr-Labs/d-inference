import Foundation

private final class Tape {
    var lines: [Data] = []
    var reads = 0
    var writes: [Data] = []
    var writeFailure = false
    var checkFailure = false
    func read() throws -> Data? { reads += 1; return lines.isEmpty ? nil : lines.removeFirst() }
    func write(_ data: Data) throws {
        if writeFailure { throw ProbeError("injected write failure") }
        writes.append(data)
    }
    func check() throws { if checkFailure { throw ProbeError("injected check failure") } }
}

private struct Metadata: Encodable { let value = "cpu-fixture" }
private struct EncodingFailure: Encodable {
    func encode(to encoder: Encoder) throws { throw ProbeError("injected encoding failure") }
}

struct ControlCheckResult: Encodable {
    let kind = "resident_benchmark_worker_control_check"
    let cpuOnly = true, nativeRequestsExecuted = false
    let accepted: [String], rejected: [String]
}

func checkResidentBenchmarkWorkerControl() throws -> ControlCheckResult {
    let cohort = "prompt:solo"
    let requests = (0..<4).map { index in
        QwenResidentBenchmarkWorkerRequest(requestID: cohort + QwenResidentBenchmarkWorkerCommand.suffixes[index],
            epoch: String(repeating: "0", count: 31) + String(index + 1))
    }
    let open = QwenResidentBenchmarkWorkerOpen(cohortID: cohort, requests: requests)
    let steps = (0..<4).map { index in
        QwenLongPrefillResidentRequestStep(ordinal: index, excludedWarmup: index == 0,
            requestID: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(index + 1)")!,
            recordedRequestFingerprint: String(repeating: "a", count: 64), promptFileSHA256: String(repeating: "b", count: 64))
    }
    let runs = requests.enumerated().map { index, request in
        QwenResidentBenchmarkWorkerRun(cohortID: cohort, sequence: index + 1, requestID: request.requestID, epoch: request.epoch)
    }
    let shutdown = QwenResidentBenchmarkWorkerCommand.shutdown(.init(cohortID: cohort, sequence: 5))
    func make(_ tape: Tape, role: String = "solo") throws -> QwenResidentBenchmarkWorkerControl {
        tape.lines = try runs.map { try QwenResidentBenchmarkWorkerCommand.run($0).canonicalData() } + [shutdown.canonicalData()]
        return try .init(open: open, steps: steps, role: role, read: tape.read,
            output: .init(write: tape.write), check: tape.check)
    }
    var accepted: [String] = [], rejected: [String] = []
    func require(_ condition: Bool, _ message: String) throws { if !condition { throw ProbeError(message) } }
    func reject(_ name: String, _ body: () throws -> Void) throws {
        do { try body() } catch { rejected.append(name); return }
        throw ProbeError("Control fixture admitted " + name)
    }

    let tape = Tape(), control = try make(tape)
    try control.modelReady(Metadata(), rank: nil)
    try require(tape.reads == 0 && tape.writes.count == 1, "Ready consumed a request")
    for index in 0..<4 {
        try require(tape.reads == index, "A later permission was consumed eagerly")
        try control.permit(steps[index])
        try require(tape.reads == index + 1 && tape.writes.count == index + 1, "Permission published execution")
        try control.result(steps[index]) { command in
            try require(command == runs[index], "Result changed permitted command")
            return command
        }
    }
    try control.modelReleased(Metadata())
    try require(tape.reads == 4 && tape.writes.count == 6, "Release consumed shutdown or repeated results")
    try control.shutdown(Metadata())
    let events = try tape.writes.map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] }
    try require(events.compactMap { $0["type"] as? String } == ["ready", "result", "result", "result", "result", "released", "stopped"], "Event order differs")
    try require(events.allSatisfy { $0["rank"] is NSNull && $0["schema"] as? String == QwenResidentBenchmarkWorkerCommand.schema }, "Envelope lost exact null rank/schema")
    accepted.append("four explicit permissions and seven bounded records")
    try reject("run after stopped") { try control.permit(steps[0]) }
    try reject("stopped controller cannot recover") { try control.modelReady(Metadata(), rank: nil) }

    for (name, fail) in [
        ("result before permission", { (c: QwenResidentBenchmarkWorkerControl) in try c.result(steps[0]) { _ in Metadata() } }),
        ("release before results", { (c: QwenResidentBenchmarkWorkerControl) in try c.modelReleased(Metadata()) }),
        ("shutdown before release", { (c: QwenResidentBenchmarkWorkerControl) in try c.shutdown(Metadata()) }),
        ("repeated loaded ready", { (c: QwenResidentBenchmarkWorkerControl) in try c.modelReady(Metadata(), rank: nil) }),
        ("native step out of order", { (c: QwenResidentBenchmarkWorkerControl) in try c.permit(steps[1]) }),
    ] {
        let t = Tape(), c = try make(t)
        try c.modelReady(Metadata(), rank: nil)
        try reject(name) { try fail(c) }
        try reject(name + " poisons controller") { try c.permit(steps[0]) }
        try require(t.reads == 0, "Invalid owner transition read another command")
    }
    for name in ["eof", "malformed command", "open replay", "future command"] {
        let t = Tape(), c = try make(t)
        try c.modelReady(Metadata(), rank: nil)
        switch name {
        case "eof": t.lines = []
        case "malformed command": t.lines = [Data("{".utf8)]
        case "open replay": t.lines = [try QwenResidentBenchmarkWorkerCommand.open(open).canonicalData()]
        default: t.lines = [try QwenResidentBenchmarkWorkerCommand.run(runs[1]).canonicalData()]
        }
        try reject(name) { try c.permit(steps[0]) }
        t.lines = [try QwenResidentBenchmarkWorkerCommand.run(runs[0]).canonicalData()]
        try reject(name + " no recovery") { try c.permit(steps[0]) }
        try require(t.reads == 1, "Failed command was retried")
    }
    for failure in ["encoding", "write", "check"] {
        let t = Tape(), c = try make(t)
        try c.modelReady(Metadata(), rank: nil); try c.permit(steps[0])
        try reject("result " + failure) {
            if failure == "encoding" { try c.result(steps[0]) { _ in EncodingFailure() } }
            else {
                t.writeFailure = failure == "write"; t.checkFailure = failure == "check"
                try c.result(steps[0]) { _ in Metadata() }
            }
        }
        t.writeFailure = false; t.checkFailure = false
        try reject("result " + failure + " no next request") { try c.permit(steps[1]) }
        try require(t.reads == 1 && t.writes.count == 1, "Failed result advanced execution")
    }
    let rankTape = Tape(), rankControl = try make(rankTape, role: "rank")
    try rankControl.modelReady(Metadata(), rank: 1)
    accepted.append("rank one ready")
    let badRankTape = Tape(), badRank = try make(badRankTape, role: "rank")
    try reject("rank requires actual zero or one") { try badRank.modelReady(Metadata(), rank: nil) }
    var wrongSteps = steps
    wrongSteps[0] = .init(ordinal: 0, excludedWarmup: true, requestID: UUID(),
        recordedRequestFingerprint: steps[0].recordedRequestFingerprint, promptFileSHA256: steps[0].promptFileSHA256)
    try reject("native uuid must equal open epoch") {
        _ = try QwenResidentBenchmarkWorkerControl(open: open, steps: wrongSteps, role: "solo", read: { nil }, output: .init(write: { _ in }), check: {})
    }

    var output: QwenResidentBenchmarkWorkerOutput!
    output = .init(write: { _ in try? output.publish(Metadata(), check: {}) })
    try reject("reentrant output remains failed") { try output.publish(Metadata(), check: {}) }
    try require(output.failed && output.completedBytes == 0, "Reentrant write advanced completed bytes")
    try reject("failed output never retries") { try output.publish(Metadata(), check: {}) }
    for poisonedCheck in 1...2 {
        var checkedWrites = 0, checkedCalls = 0
        var checkedOutput: QwenResidentBenchmarkWorkerOutput!
        checkedOutput = .init(write: { _ in checkedWrites += 1 })
        try reject("swallowed reentry in output check \(poisonedCheck)") {
            try checkedOutput.publish(Metadata()) {
                checkedCalls += 1
                if checkedCalls == poisonedCheck { try? checkedOutput.publish(Metadata(), check: {}) }
            }
        }
        try require(checkedWrites == 0, "Poisoned output check published bytes")
    }
    for poisonedCheck in 1...3 {
        var checkedWrites = 0, checkedCalls = 0
        var checkedControl: QwenResidentBenchmarkWorkerControl!
        checkedControl = try .init(open: open, steps: steps, role: "solo", read: { nil },
            output: .init(write: { _ in checkedWrites += 1 }), check: {
                checkedCalls += 1
                if checkedCalls == poisonedCheck { checkedControl.fail() }
            })
        try reject("swallowed controller poison in check \(poisonedCheck)") {
            try checkedControl.modelReady(Metadata(), rank: nil)
        }
        try require(checkedWrites == 0, "Poisoned controller check published bytes")
    }
    let cap = QwenResidentBenchmarkWorkerOutput(write: { _ in })
    try reject("encoded line cap") { try cap.publish(String(repeating: "a", count: QwenResidentBenchmarkWorkerOutput.maximumLineBytes), check: {}) }
    let total = QwenResidentBenchmarkWorkerOutput(write: { _ in })
    let chunk = String(repeating: "a", count: 20 * 1024 * 1024)
    for _ in 0..<7 { try total.publish(chunk, check: {}) }
    try reject("encoded total cap") { try total.publish(chunk, check: {}) }
    return .init(accepted: accepted, rejected: rejected)
}
