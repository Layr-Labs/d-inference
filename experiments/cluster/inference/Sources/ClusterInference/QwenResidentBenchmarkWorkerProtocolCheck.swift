import Foundation

struct QwenResidentBenchmarkWorkerProtocolCheckReport: Encodable {
    let kind = "qwen_resident_benchmark_worker_protocol_check"
    let accepted: [String]
    let rejected: [String]
    let cpuOnly = true
    let modelConstructed = false
    let modelTensorPayloadRead = false
    let nativeRequestExecuted = false
    let transportExecuted = false
}

private struct ProtocolChecks {
    var accepted: [String] = []
    var rejected: [String] = []

    mutating func accept(_ name: String, _ body: () throws -> Void) throws {
        try body()
        accepted.append(name)
    }

    mutating func reject(_ name: String, _ body: () throws -> Void) throws {
        do { try body() } catch { rejected.append(name); return }
        throw ProbeError("Resident benchmark fixture unexpectedly accepted: \(name)")
    }
}

private func protocolRequire(_ condition: Bool, _ message: String) throws {
    guard condition else { throw ProbeError("Resident benchmark fixture: \(message)") }
}

private func fixtureOpen(_ cohort: String = "prompt:solo") -> QwenResidentBenchmarkWorkerOpen {
    .init(cohortID: cohort, requests: (0..<4).map { ordinal in
        .init(requestID: cohort + QwenResidentBenchmarkWorkerCommand.suffixes[ordinal],
              epoch: String(repeating: "0", count: 31) + String(ordinal + 1))
    })
}

private func fixtureRun(_ open: QwenResidentBenchmarkWorkerOpen, _ ordinal: Int) -> QwenResidentBenchmarkWorkerRun {
    .init(cohortID: open.cohortID, sequence: ordinal + 1,
          requestID: open.requests[ordinal].requestID, epoch: open.requests[ordinal].epoch)
}

private func fixtureObject(_ command: QwenResidentBenchmarkWorkerCommand) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: command.canonicalData()) as? [String: Any] else {
        throw ProbeError("Fixture did not encode an object")
    }
    return value
}

private func fixtureBytes(_ value: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}

func checkQwenResidentBenchmarkWorkerProtocol() throws -> QwenResidentBenchmarkWorkerProtocolCheckReport {
    typealias Command = QwenResidentBenchmarkWorkerCommand
    var checks = ProtocolChecks()
    let open = fixtureOpen()
    let first = fixtureRun(open, 0)
    let shutdown = QwenResidentBenchmarkWorkerShutdown(cohortID: open.cohortID, sequence: 5)
    let commands: [Command] = [.open(open), .run(first), .shutdown(shutdown)]
    for (index, command) in commands.enumerated() {
        try checks.accept("canonical_roundtrip_\(index)") {
            let raw = try command.canonicalData()
            let decoded = try Command.decode(raw)
            try protocolRequire(try decoded.canonicalData() == raw, "canonical roundtrip changed")
        }
    }
    try checks.accept("fixed_run_bytes") {
        let expected = "{\"cohort_id\":\"prompt:solo\",\"epoch\":\"00000000000000000000000000000001\",\"request_id\":\"prompt:solo:warmup:0\",\"schema\":\"qwen_resident_benchmark_worker_v1\",\"sequence\":1,\"type\":\"run\"}"
        try protocolRequire(try Command.run(first).canonicalData() == Data(expected.utf8), "run encoding changed")
    }
    try checks.accept("maximum_label_lengths") {
        let value = fixtureOpen(String(repeating: "a", count: 64) + ":" + String(repeating: "b", count: 64))
        _ = try Command.decode(Command.open(value).canonicalData())
        try protocolRequire(value.cohortID.utf8.count == 129 && value.requests[3].requestID.utf8.count == 140,
                            "maximum IDs differ from matrix bounds")
    }
    try checks.accept("exact_decoder_byte_cap") {
        var raw = try Command.open(open).canonicalData()
        raw.append(Data(repeating: 32, count: Command.maximumEncodedBytes - raw.count))
        _ = try Command.decode(raw)
    }
    let validRun = String(decoding: try Command.run(first).canonicalData(), as: UTF8.self)
    let invalidJSON: [(String, Data)] = [
        ("empty", Data()), ("oversize", Data(repeating: 32, count: 4097)),
        ("non_object", Data("[]".utf8)), ("truncated", Data(validRun.dropLast().utf8)),
        ("trailing_object", Data((validRun + "{}").utf8)), ("invalid_utf8", Data([255])),
        ("duplicate_key", Data(validRun.replacingOccurrences(of: "\"sequence\":1", with: "\"sequence\":1,\"sequence\":1").utf8)),
        ("escaped_duplicate_key", Data(validRun.replacingOccurrences(of: "\"sequence\":1", with: "\"sequence\":1,\"sequenc\\u0065\":1").utf8))
    ]
    for (name, raw) in invalidJSON {
        try checks.reject(name) { _ = try Command.decode(raw) }
    }
    for literal in ["true", "false", "1.0", "1e0", "-0", "0", "5", "-1", "9223372036854775808", "NaN"] {
        let raw = Data(validRun.replacingOccurrences(of: "\"sequence\":1", with: "\"sequence\":" + literal).utf8)
        try checks.reject("invalid_sequence_" + literal) { _ = try Command.decode(raw) }
    }
    for (index, command) in commands.enumerated() {
        let value = try fixtureObject(command)
        for key in value.keys.sorted() {
            var missing = value; missing.removeValue(forKey: key)
            try checks.reject("missing_\(index)_\(key)") { _ = try Command.decode(fixtureBytes(missing)) }
        }
        var extra = value; extra["model_dir"] = "not-admitted"
        try checks.reject("extra_\(index)") { _ = try Command.decode(fixtureBytes(extra)) }
    }
    for (key, value) in [("schema", "worker_v5"), ("type", "infer"), ("cohort_id", "missing-colon"),
                         ("cohort_id", "too:many:labels"), ("cohort_id", "bad/:label"),
                         ("cohort_id", "é:label"), ("cohort_id", ":label"),
                         ("cohort_id", String(repeating: "x", count: 65) + ":label"),
                         ("request_id", "wrong:request"), ("epoch", String(repeating: "A", count: 32)),
                         ("epoch", "short")] {
        var object = try fixtureObject(.run(first)); object[key] = value
        try checks.reject("invalid_\(key)_\(value)") { _ = try Command.decode(fixtureBytes(object)) }
    }
    for count in [0, 3, 5] {
        let rows = count == 5 ? open.requests + [open.requests[0]] : Array(open.requests.prefix(count))
        try checks.reject("open_count_\(count)") {
            _ = try QwenResidentBenchmarkWorkerSequence(open: .init(cohortID: open.cohortID, requests: rows))
        }
    }
    for mutation in ["duplicate_epoch", "wrong_order", "extra_request_field", "missing_epoch", "boolean_epoch"] {
        var object = try fixtureObject(.open(open))
        var rows = object["requests"] as! [[String: Any]]
        switch mutation {
        case "duplicate_epoch": rows[1]["epoch"] = rows[0]["epoch"]
        case "wrong_order": rows.swapAt(0, 1)
        case "extra_request_field": rows[0]["phase"] = "warmup"
        case "missing_epoch": rows[0].removeValue(forKey: "epoch")
        default: rows[0]["epoch"] = true
        }
        object["requests"] = rows
        try checks.reject(mutation) { _ = try Command.decode(fixtureBytes(object)) }
    }
    try checks.accept("four_explicit_runs_then_shutdown") {
        var sequence = try QwenResidentBenchmarkWorkerSequence(open: open)
        try protocolRequire(!sequence.requestActive && sequence.completedRequests == 0, "open performed work")
        for ordinal in 0..<4 {
            let request = fixtureRun(open, ordinal)
            let accepted = try sequence.accept(command: .run(request))
            try protocolRequire(accepted == request && sequence.requestActive && sequence.completedRequests == ordinal,
                                "acceptance prematurely completed a request")
            try sequence.complete(request: request)
            try protocolRequire(!sequence.requestActive && sequence.completedRequests == ordinal + 1,
                                "completion did not retire protocol scope")
        }
        try protocolRequire(try sequence.accept(command: .shutdown(shutdown)) == nil,
                            "shutdown unexpectedly returned a run")
        try protocolRequire(sequence.isStopped && !sequence.failed, "clean shutdown failed")
    }
    let invalidInitial: [(String, Command)] = [
        ("repeat_open", .open(open)), ("early_shutdown", .shutdown(shutdown)),
        ("out_of_order", .run(fixtureRun(open, 1))),
        ("wrong_epoch", .run(.init(cohortID: open.cohortID, sequence: 1,
                                   requestID: first.requestID, epoch: open.requests[1].epoch))),
        ("wrong_cohort", .run(fixtureRun(fixtureOpen("other:solo"), 0))),
        ("direct_invalid_sequence", .run(.init(cohortID: open.cohortID, sequence: 0,
                                               requestID: first.requestID, epoch: first.epoch)))
    ]
    for (name, command) in invalidInitial {
        var sequence = try QwenResidentBenchmarkWorkerSequence(open: open)
        try checks.reject(name) { _ = try sequence.accept(command: command) }
        try protocolRequire(sequence.failed && sequence.completedRequests == 0, "rejection was not terminal")
        try checks.reject(name + "_no_recovery") { _ = try sequence.accept(command: .run(first)) }
    }
    for name in ["second_while_pending", "shutdown_while_pending", "mismatched_completion", "external_failure"] {
        var sequence = try QwenResidentBenchmarkWorkerSequence(open: open)
        _ = try sequence.accept(command: .run(first))
        try checks.reject(name) {
            switch name {
            case "second_while_pending": _ = try sequence.accept(command: .run(fixtureRun(open, 1)))
            case "shutdown_while_pending": _ = try sequence.accept(command: .shutdown(shutdown))
            case "mismatched_completion": try sequence.complete(request: fixtureRun(open, 1))
            default: sequence.fail(); try sequence.complete(request: first)
            }
        }
        try protocolRequire(sequence.failed && sequence.requestActive && sequence.completedRequests == 0,
                            "failure fabricated completion or cleared pending ownership")
    }
    for name in ["replay", "duplicate_completion", "partial_shutdown"] {
        var sequence = try QwenResidentBenchmarkWorkerSequence(open: open)
        _ = try sequence.accept(command: .run(first)); try sequence.complete(request: first)
        try checks.reject(name) {
            switch name {
            case "replay": _ = try sequence.accept(command: .run(first))
            case "duplicate_completion": try sequence.complete(request: first)
            default: _ = try sequence.accept(command: .shutdown(shutdown))
            }
        }
        try protocolRequire(sequence.failed && sequence.completedRequests == 1, "completed count changed on failure")
    }
    for name in ["shutdown_replay", "run_after_stop", "fifth_request"] {
        var sequence = try QwenResidentBenchmarkWorkerSequence(open: open)
        for ordinal in 0..<4 {
            let request = fixtureRun(open, ordinal)
            _ = try sequence.accept(command: .run(request)); try sequence.complete(request: request)
        }
        if name != "fifth_request" { _ = try sequence.accept(command: .shutdown(shutdown)) }
        try checks.reject(name) {
            if name == "shutdown_replay" { _ = try sequence.accept(command: .shutdown(shutdown)) }
            else { _ = try sequence.accept(command: .run(first)) }
        }
        try protocolRequire(sequence.failed && sequence.completedRequests == 4, "terminal count changed")
    }
    return .init(accepted: checks.accepted, rejected: checks.rejected)
}
