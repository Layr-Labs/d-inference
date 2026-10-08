import CryptoKit
import Foundation

private let workerCheckEpoch = String(repeating: "a", count: 32)
// Python json.dumps(sort_keys=True, separators=(",", ":")), UTF-8, SHA-256.
private let workerCanonicalFixtureSHA256 = "b709fcf9cba5a98f73de5a9625de47aa59d4cc70eb6e36c2bf57aed487c350de"

private struct WorkerCheckCounts {
    var accepted = 0
    var rejected = 0

    mutating func reject(_ label: String, _ action: () throws -> Void) throws {
        var failed = false
        do { try action() } catch { failed = true }
        guard failed else { throw ProbeError("Worker protocol accepted \(label)") }
        rejected += 1
    }
}

private func workerCheckObject() -> [String: Any] {
    ["version": 3, "type": "infer", "epoch": workerCheckEpoch, "sequence": 1,
     "requestID": "check:1", "prompt": [1, 2, 3], "outputTokens": 3, "chunkSize": 2,
     "timeoutSeconds": 30, "captureLogits": true, "teacherTokens": [4, 5]]
}

private func workerCheckDecode(_ object: [String: Any]) throws -> WorkerCommand {
    try WorkerCommand.decode(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
}

private func workerCheckRequest(sequence: Int = 1, id: String = "request-1", epoch: String = workerCheckEpoch,
                                prompt: [Int] = [1], outputs: Int = 1, capture: Bool = false,
                                teacher: [Int]? = nil) -> WorkerCommand {
    .infer(WorkerInferenceRequest(epoch: epoch, sequence: sequence, requestID: id,
        prompt: prompt, outputTokens: outputs, chunkSize: 1, timeoutSeconds: 1,
        captureLogits: capture, teacherTokens: teacher))
}

private func checkWorkerDecoding(_ counts: inout WorkerCheckCounts) throws {
    let valid = workerCheckObject()
    let command = try workerCheckDecode(valid)
    let canonical = try command.canonicalData()
    let digest = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    let reordered = try JSONSerialization.data(withJSONObject: valid, options: [.prettyPrinted])
    guard digest == workerCanonicalFixtureSHA256,
        canonical == (try WorkerCommand.decode(reordered).canonicalData()),
        !canonical.contains(10), command.epoch == workerCheckEpoch, command.sequence == 1,
        canonical == (try WorkerCommand.decode(canonical).canonicalData()) else {
        throw ProbeError("Worker canonical encoding changed with input order or round trip")
    }
    counts.accepted += 2
    var optional = valid
    optional.removeValue(forKey: "teacherTokens")
    let noTeacher = try workerCheckDecode(optional).canonicalData()
    guard let noTeacherObject = try JSONSerialization.jsonObject(with: noTeacher) as? [String: Any],
        noTeacherObject["teacherTokens"] == nil else { throw ProbeError("Absent teacher tokens were encoded as null") }
    optional["outputTokens"] = 1; optional["teacherTokens"] = [Int]()
    let emptyTeacher = try workerCheckDecode(optional).canonicalData()
    guard let emptyObject = try JSONSerialization.jsonObject(with: emptyTeacher) as? [String: Any],
        (emptyObject["teacherTokens"] as? [Int]) == [] else {
        throw ProbeError("Explicit empty teacher history was discarded")
    }
    counts.accepted += 2
    for field in valid.keys where field != "teacherTokens" {
        var missing = valid; missing.removeValue(forKey: field)
        try counts.reject("missing \(field)") { _ = try workerCheckDecode(missing) }
    }
    let replacements: [(String, Any)] = [
        ("version", true), ("version", "2"), ("version", 1), ("version", 2), ("version", 4), ("type", 1), ("type", "ready"),
        ("epoch", true), ("epoch", String(repeating: "A", count: 32)), ("epoch", String(repeating: "a", count: 31)),
        ("sequence", true), ("sequence", "1"), ("sequence", 0), ("sequence", 1_000_000_001),
        ("requestID", ""), ("requestID", "with space"), ("requestID", "é"),
        ("requestID", String(repeating: "a", count: 129)), ("requestID", 1),
        ("prompt", [Int]()), ("prompt", [true]), ("prompt", ["1"]), ("prompt", [-1]), ("prompt", NSNull()),
        ("outputTokens", true), ("outputTokens", 0), ("outputTokens", 4097),
        ("chunkSize", 0), ("chunkSize", 32769), ("chunkSize", "1"),
        ("timeoutSeconds", 0), ("timeoutSeconds", 301), ("timeoutSeconds", true),
        ("captureLogits", 0), ("captureLogits", "true"), ("captureLogits", NSNull()),
        ("teacherTokens", NSNull()), ("teacherTokens", [1]), ("teacherTokens", [-1, 2]),
        ("teacherTokens", [true, false]), ("teacherTokens", ["1", "2"]), ("unknown", 1),
    ]
    for (field, value) in replacements {
        var malformed = valid; malformed[field] = value
        try counts.reject("malformed \(field)") { _ = try workerCheckDecode(malformed) }
    }
    let text = String(decoding: canonical, as: UTF8.self)
    let lexical = [
        text.replacingOccurrences(of: "\"sequence\":1", with: "\"sequence\":1.0"),
        text.replacingOccurrences(of: "\"sequence\":1", with: "\"sequence\":1e0"),
        text.replacingOccurrences(of: "\"sequence\":1", with: "\"sequence\":01"),
        text.replacingOccurrences(of: "\"sequence\":1", with: "\"sequence\":18446744073709551616"),
        text.replacingOccurrences(of: "\"version\":3", with: "\"version\":3,\"version\":3"),
        text.replacingOccurrences(of: "\"version\":3", with: "\"version\":3,\"vers\\u0069on\":3"),
        text + "{}", "[]", "null", "{\"version\":NaN}",
        "{\"unknown\":{\"x\":1,\"\\u0078\":2}}",
        String(repeating: "[", count: 66) + "0" + String(repeating: "]", count: 66),
        "{\"version\":3,}", "{\"version\":\"\\uZZZZ\"}",
    ]
    for malformed in lexical {
        guard malformed != text else { throw ProbeError("Worker lexical rejection fixture failed to mutate input") }
        try counts.reject("ambiguous or malformed JSON") { _ = try WorkerCommand.decode(Data(malformed.utf8)) }
    }
    let shutdown = ["version": 3, "type": "shutdown", "epoch": workerCheckEpoch, "sequence": 1] as [String: Any]
    guard case .shutdown = try workerCheckDecode(shutdown) else { throw ProbeError("Shutdown command decoded incorrectly") }
    counts.accepted += 1
    for version in [1, 2] {
        var legacyShutdown = shutdown; legacyShutdown["version"] = version
        try counts.reject("legacy shutdown") { _ = try workerCheckDecode(legacyShutdown) }
    }
    for field in shutdown.keys {
        var missing = shutdown; missing.removeValue(forKey: field)
        try counts.reject("missing shutdown \(field)") { _ = try workerCheckDecode(missing) }
    }
    var extra = shutdown; extra["requestID"] = "not-allowed"
    try counts.reject("unknown shutdown field") { _ = try workerCheckDecode(extra) }
    var limits = valid
    limits["requestID"] = String(repeating: "x", count: 128)
    limits["sequence"] = 1_000_000_000; limits["outputTokens"] = 4096
    limits["chunkSize"] = 32768; limits["timeoutSeconds"] = 300
    limits.removeValue(forKey: "teacherTokens")
    _ = try workerCheckDecode(limits)
    counts.accepted += 1
}

private func checkWorkerSequences(_ counts: inout WorkerCheckCounts) throws {
    var state = try WorkerSequence(epoch: workerCheckEpoch)
    try state.accept(command: workerCheckRequest(), vocabularySize: 16, maxContextTokens: 16)
    counts.accepted += 1
    let invalid: [(WorkerCommand, Int, Int)] = [
        (workerCheckRequest(sequence: 1, id: "new"), 16, 16),
        (workerCheckRequest(sequence: 3, id: "new"), 16, 16),
        (workerCheckRequest(sequence: 2), 16, 16),
        (workerCheckRequest(sequence: 2, id: "new", epoch: String(repeating: "b", count: 32)), 16, 16),
        (workerCheckRequest(sequence: 2, id: "after-failure", prompt: [16]), 16, 16),
        (workerCheckRequest(sequence: 2, id: "new", outputs: 2, teacher: [16]), 16, 16),
        (workerCheckRequest(sequence: 2, id: "new", prompt: [1, 2, 3], outputs: 4), 16, 6),
        (workerCheckRequest(sequence: 2, id: "new", outputs: 2, capture: true), Int.max, 16),
        (workerCheckRequest(sequence: 2, id: "new", outputs: 4096, capture: true), 257, 8192),
        (workerCheckRequest(sequence: 2, id: "new"), 0, 16),
        (workerCheckRequest(sequence: 2, id: "new"), 16, 0),
    ]
    for (command, vocabulary, context) in invalid {
        try counts.reject("sequence/request/model bound") {
            try state.accept(command: command, vocabularySize: vocabulary, maxContextTokens: context)
        }
        guard state.nextSequence == 2, state.inferenceCount == 1, !state.isShutdown else {
            throw ProbeError("Rejected worker command mutated sequence state")
        }
    }
    try state.accept(command: workerCheckRequest(sequence: 2, id: "after-failure"), vocabularySize: 16, maxContextTokens: 2)
    try state.accept(command: .shutdown(WorkerShutdown(epoch: workerCheckEpoch, sequence: 3)),
                     vocabularySize: 16, maxContextTokens: 16)
    guard state.isShutdown, state.nextSequence == 4, state.inferenceCount == 2 else {
        throw ProbeError("Worker shutdown state is inconsistent")
    }
    counts.accepted += 2
    for command in [workerCheckRequest(sequence: 4, id: "new"),
                    .shutdown(WorkerShutdown(epoch: workerCheckEpoch, sequence: 4))] {
        try counts.reject("command after shutdown") {
            try state.accept(command: command, vocabularySize: 16, maxContextTokens: 16)
        }
    }
    var capture = try WorkerSequence(epoch: workerCheckEpoch)
    try capture.accept(command: workerCheckRequest(outputs: 4096, capture: true),
                       vocabularySize: 256, maxContextTokens: 4097)
    counts.accepted += 1
    var bounded = try WorkerSequence(epoch: workerCheckEpoch)
    for sequence in 1...4096 {
        try bounded.accept(command: workerCheckRequest(sequence: sequence, id: "request-\(sequence)"),
                           vocabularySize: 2, maxContextTokens: 2)
    }
    guard bounded.inferenceCount == 4096, bounded.nextSequence == 4097 else {
        throw ProbeError("Worker epoch inference bound was not exercised")
    }
    counts.accepted += 4096
    try counts.reject("4097th inference in epoch") {
        try bounded.accept(command: workerCheckRequest(sequence: 4097, id: "request-4097"),
                           vocabularySize: 2, maxContextTokens: 2)
    }
    try bounded.accept(command: .shutdown(WorkerShutdown(epoch: workerCheckEpoch, sequence: 4097)),
                       vocabularySize: 2, maxContextTokens: 2)
    counts.accepted += 1
}

private func withWorkerReader(_ bytes: Data, _ action: (WorkerLineReader) throws -> Void) throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("cluster-worker-frame-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: path) }
    try bytes.write(to: path)
    let handle = try FileHandle(forReadingFrom: path)
    defer { try? handle.close() }
    try action(WorkerLineReader(handle: handle))
}

private func checkWorkerFraming(_ counts: inout WorkerCheckCounts) throws {
    let command = try workerCheckDecode(workerCheckObject()).canonicalData()
    let padded = command + Data(repeating: 32, count: 4095 - command.count)
    let input = padded + Data([10]) + command + Data([13, 10])
    try withWorkerReader(input) { reader in
        let first = try reader.next(), second = try reader.next(), end = try reader.next()
        guard first == padded, second == command + Data([13]), end == nil else {
            throw ProbeError("Worker framing lost a boundary, CRLF byte or EOF")
        }
    }
    counts.accepted += 2
    let limit = command + Data(repeating: 32, count: workerMaximumLineBytes - command.count)
    try withWorkerReader(limit + Data([10])) { reader in
        guard let frame = try reader.next(), frame.count == workerMaximumLineBytes,
            try WorkerCommand.decode(frame).canonicalData() == command else {
            throw ProbeError("Worker maximum legal line was not preserved")
        }
        guard try reader.next() == nil else { throw ProbeError("Maximum worker frame left unexpected input") }
    }
    counts.accepted += 1
    for bytes in [command, command + Data([10]) + Data("{\"version\":".utf8),
                  limit + Data([32, 10]), limit + Data([32])] {
        try counts.reject("truncated or oversized JSONL frame") {
            try withWorkerReader(bytes) { reader in while try reader.next() != nil {} }
        }
    }
    try counts.reject("oversized direct decode") { _ = try WorkerCommand.decode(limit + Data([32])) }
    try counts.reject("blank JSONL command") {
        try withWorkerReader(Data([10])) { reader in
            guard let frame = try reader.next() else { throw ProbeError("Missing expected blank frame") }
            _ = try WorkerCommand.decode(frame)
        }
    }
    try withWorkerReader(Data()) { reader in
        guard try reader.next() == nil else { throw ProbeError("Empty worker input was not EOF") }
    }
    counts.accepted += 1
}

func checkWorkerProtocol() throws {
    var counts = WorkerCheckCounts()
    try checkWorkerDecoding(&counts)
    try checkWorkerSequences(&counts)
    try checkWorkerFraming(&counts)
    try checkWorkerShortPipeFrame()
    counts.accepted += 1
    struct Result: Encodable {
        let kind = "worker_protocol_check"
        let version = 3
        let acceptedFixtures: Int
        let rejectedFixtures: Int
        let strictDuplicateKeys = true
        let integerSyntaxOnly = true
        let canonicalSortedKeys = true
        let canonicalFixtureSHA256 = workerCanonicalFixtureSHA256
        let sequenceMutatesOnlyAfterValidation = true
        let requestIDsUniqueWithinEpoch = true
        let boundedJSONLBytes = workerMaximumLineBytes
        let readerChunkBytes = 4096
        let epochInferenceLimit = 4096
        let truncatedFrameRejected = true
        let shortPipeFrameReturnsBeforeWriterCloses = true
        let cpuOnly = true
        let correctnessOnly = true
    }
    try emitJSON(Result(acceptedFixtures: counts.accepted, rejectedFixtures: counts.rejected))
}
