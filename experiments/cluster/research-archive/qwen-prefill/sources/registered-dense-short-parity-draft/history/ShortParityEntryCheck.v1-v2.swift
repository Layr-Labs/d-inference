import Darwin
import Foundation

struct ShortParityEntryCheckResult: Encodable {
    let kind = "qwen_dense_short_parity_entry_check", schemaVersion = 1
    let accepted: [String], rejected: [String]
    let syntheticTokenFileIOPerformed = true, fabricatedPublicationValues = true
    let modelConstructed = false, tensorPayloadRead = false, forwardExecuted = false
    let nativeOwnerCleanupExercised = false, numericalParityEstablished = false
}

func checkShortParityEntry(_ inputs: QwenObservedFixtureInputs) throws -> ShortParityEntryCheckResult {
    var accepted: [String] = [], rejected: [String] = []
    func require(_ name: String, _ ok: Bool) throws {
        guard ok else { throw ProbeError("Short parity entry fixture: " + name) }; accepted.append(name)
    }
    func reject(_ name: String, _ body: () throws -> Void) throws {
        do { try body() } catch { rejected.append(name); return }
        throw ProbeError("Short parity entry accepted invalid: " + name)
    }
    let prompt = Data("[1,2,3]".utf8), teacher = Data("[4]".utf8)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("darkbloom-short-entry-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let p = root.appendingPathComponent("prompt.json"), t = root.appendingPathComponent("teacher.json")
    try prompt.write(to: p); try teacher.write(to: t)
    let base = ["--mode", QwenDenseShortParityCLI.mode, "--model-dir", root.path,
        "--registered-dense-profile", "registered_qwen35_9b", "--tokens-file", p.path,
        "--tokens-sha256", sha256(prompt), "--teacher-tokens-file", t.path,
        "--teacher-tokens-sha256", sha256(teacher), "--timeout-seconds", "300"]
    func changed(_ key: String, _ value: String) -> [String] {
        var args = base; args[args.firstIndex(of: key)! + 1] = value; return args
    }
    for (model, input, hidden) in [(QwenRegisteredDenseModel.qwen35NineB, inputs.nine, 4096),
        (.qwen38TwentySevenB, inputs.twentySeven, 5120)] {
        let args = changed("--registered-dense-profile", model.rawValue), cli = try QwenDenseShortParityCLI(arguments: args)
        let metadata = try QwenDenseConstructorAdmission.admit(model: model,
            configuration: input.configuration, manifest: input.manifest,
            environment: QwenLongPrefillArithmeticEnvironment.requiredValues)
        let rawPrompt = try QwenDenseShortParityInput.tokens(cli.promptFile, expectedSHA256: cli.promptSHA256)
        let rawTeacher = try QwenDenseShortParityInput.tokens(cli.teacherFile, expectedSHA256: cli.teacherSHA256)
        let admission = try QwenDenseShortReferenceAdmission.admit(metadata: metadata, requestID: UUID(),
            promptData: rawPrompt, promptSHA256: cli.promptSHA256, teacherData: rawTeacher, teacherSHA256: cli.teacherSHA256)
        let geometry = try QwenDenseShortBaselineGeometry(configuration: input.configuration)
        try require(model.rawValue + " captured CLI to real admission", cli.model == model && cli.timeoutSeconds == 300 &&
            rawPrompt == prompt && rawTeacher == teacher && admission.request.steps.map(\.committedTokens) == [2,3,4] &&
            admission.request.steps.map(\.tokenIDs) == [[1,2],[3],[4]] && geometry.hidden == hidden && geometry.namespace == "language_model.")
    }
    let reordered = stride(from: 14, through: 0, by: -2).flatMap { [base[$0], base[$0+1]] }
    try require("pair order independent", try QwenDenseShortParityCLI(arguments: reordered).timeoutSeconds == 300)
    try require("timeout lower boundary", try QwenDenseShortParityCLI(arguments: changed("--timeout-seconds", "1")).timeoutSeconds == 1)
    try require("dispatch exact mode", QwenDenseShortParityCLI.isRequested(base) && QwenDenseShortParityCLI.isRequested(reordered))
    try require("dispatch unrelated and dangling mode", !QwenDenseShortParityCLI.isRequested([]) &&
        !QwenDenseShortParityCLI.isRequested(["--mode"]) && !QwenDenseShortParityCLI.isRequested(changed("--mode", "adapter-check")))
    for index in stride(from: 0, to: base.count, by: 2) {
        var args = base; args.removeSubrange(index...index+1)
        try reject("missing " + base[index]) { _ = try QwenDenseShortParityCLI(arguments: args) }
        args = base; args[index] = "--unregistered-knob"
        try reject("unknown replacing " + base[index]) { _ = try QwenDenseShortParityCLI(arguments: args) }
        args = base; args[index+1] = ""
        try reject("empty " + base[index]) { _ = try QwenDenseShortParityCLI(arguments: args) }
    }
    for suffix in [["--warmups", "1"], ["--mode"], ["--timeout-seconds", "1"]] {
        try reject("extra " + suffix.joined(separator: " ")) { _ = try QwenDenseShortParityCLI(arguments: base + suffix) }
    }
    var duplicate = base; duplicate[2] = "--mode"; duplicate[3] = QwenDenseShortParityCLI.mode
    try reject("duplicate pair replacing required key") { _ = try QwenDenseShortParityCLI(arguments: duplicate) }
    for value in ["0", "301", "01", "+1", "-1", "1.0", "1e2", " 1", "1 ", "١", String(repeating: "9", count: 80)] {
        try reject("timeout " + value) { _ = try QwenDenseShortParityCLI(arguments: changed("--timeout-seconds", value)) }
    }
    for (key, values) in [("--mode", ["adapter-check"]), ("--registered-dense-profile", ["qwen35", "registered_qwen35_35b"]),
        ("--tokens-sha256", [sha256(prompt).uppercased(), String(repeating: "g", count: 64), "0"]),
        ("--teacher-tokens-sha256", [sha256(teacher).uppercased(), String(repeating: "0", count: 63)])] {
        for value in values { try reject(key + " invalid " + value) { _ = try QwenDenseShortParityCLI(arguments: changed(key, value)) } }
    }
    for key in ["--model-dir", "--tokens-file", "--teacher-tokens-file"] {
        for (label, value) in [("relative", "foo"), ("NUL", "/foo\0bar"), ("oversize", "/" + String(repeating: "x", count: 4096))] {
            try reject(key + " " + label) { _ = try QwenDenseShortParityCLI(arguments: changed(key, value)) }
        }
    }
    try reject("token wrong content pin") { _ = try QwenDenseShortParityInput.tokens(p, expectedSHA256: sha256(teacher)) }
    try reject("token uppercase pin") { _ = try QwenDenseShortParityInput.tokens(p, expectedSHA256: sha256(prompt).uppercased()) }
    try reject("token directory") { _ = try QwenDenseShortParityInput.tokens(root, expectedSHA256: sha256(prompt)) }
    try reject("token missing") { _ = try QwenDenseShortParityInput.tokens(root.appendingPathComponent("missing"), expectedSHA256: sha256(prompt)) }
    let symlink = root.appendingPathComponent("symlink")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: p)
    try reject("token final symlink") { _ = try QwenDenseShortParityInput.tokens(symlink, expectedSHA256: sha256(prompt)) }
    let fifo = root.appendingPathComponent("fifo"); guard mkfifo(fifo.path, 0o600) == 0 else { throw ProbeError("Could not create synthetic FIFO") }
    try reject("token FIFO returns without writer") { _ = try QwenDenseShortParityInput.tokens(fifo, expectedSHA256: sha256(prompt)) }
    for count in [0, 4097] {
        let bytes = Data(repeating: 32, count: count); try bytes.write(to: p)
        try reject("token size \(count)") { _ = try QwenDenseShortParityInput.tokens(p, expectedSHA256: sha256(bytes)) }
    }
    let boundary = Data("[1,2,3]".utf8) + Data(repeating: 32, count: 4089); try boundary.write(to: p)
    try require("token exact 4096 raw capture", try QwenDenseShortParityInput.tokens(p, expectedSHA256: sha256(boundary)) == boundary)
    let metadata = try QwenDenseConstructorAdmission.admit(model: .qwen35NineB,
        configuration: inputs.nine.configuration, manifest: inputs.nine.manifest,
        environment: QwenLongPrefillArithmeticEnvironment.requiredValues)
    for raw in ["[1.0,2,3]", "[true,2,3]", "[1e0,2,3]", "[1,2]", "[-1,2,3]", "[1,2,3] trailing"] {
        let data = Data(raw.utf8); try data.write(to: p)
        try reject("captured input strict JSON " + raw) {
            let captured = try QwenDenseShortParityInput.tokens(p, expectedSHA256: sha256(data))
            _ = try QwenDenseShortReferenceAdmission.admit(metadata: metadata, requestID: UUID(), promptData: captured,
                promptSHA256: sha256(data), teacherData: teacher, teacherSHA256: sha256(teacher))
        }
    }
    // Publication operates on fabricated CPU values, using the actual encoder and state machine.
    var writes: [Data] = [], checks = 0
    let output = QwenDenseShortParityOutput()
    try output.publish(["z": 1, "a": 2], as: .baseline, check: { checks += 1 }, write: { writes.append($0) })
    try output.publish(["done": true], as: .comparison, check: { checks += 1 }, write: { writes.append($0) })
    try output.requireComplete()
    try require("two canonical ordered newline records", writes == [Data("{\"a\":2,\"z\":1}\n".utf8), Data("{\"done\":true}\n".utf8)] && checks == 6)
    try reject("third record refused") { try output.publish(1, as: .comparison, check: {}, write: { _ in }) }
    let wrong = QwenDenseShortParityOutput()
    try reject("comparison before baseline") { try wrong.publish(1, as: .comparison, check: {}, write: { _ in throw ProbeError("unexpected write") }) }
    try reject("bad order poisons publisher") { try wrong.publish(1, as: .baseline, check: {}, write: { _ in }) }
    let incomplete = QwenDenseShortParityOutput()
    try incomplete.publish(1, as: .baseline, check: {}, write: { _ in })
    try reject("baseline alone incomplete") { try incomplete.requireComplete() }
    try reject("incomplete check poisons publisher") { try incomplete.publish(1, as: .comparison, check: {}, write: { _ in }) }
    enum Fault: Error { case expected }
    for failAt in [1, 2, 3] {
        let deadline = QwenDenseShortParityOutput(); var calls = 0, writeCalls = 0, exactError = false
        do { try deadline.publish(1, as: .baseline, check: { calls += 1; if calls == failAt { throw Fault.expected } }, write: { _ in writeCalls += 1 }) }
        catch Fault.expected { exactError = true }
        try require("deadline \(failAt) preserves error and write boundary", exactError && writeCalls == (failAt == 3 ? 1 : 0))
        try reject("deadline \(failAt) poisons publisher") { try deadline.publish(1, as: .baseline, check: {}, write: { _ in }) }
    }
    let failedWrite = QwenDenseShortParityOutput(); var exactWrite = false
    do { try failedWrite.publish(1, as: .baseline, check: {}, write: { _ in throw Fault.expected }) }
    catch Fault.expected { exactWrite = true }
    try require("write error preserved", exactWrite)
    try reject("write error poisons publisher") { try failedWrite.publish(1, as: .baseline, check: {}, write: { _ in }) }
    struct BadEncoding: Encodable { func encode(to encoder: Encoder) throws { throw Fault.expected } }
    let badEncoding = QwenDenseShortParityOutput(); var exactEncoding = false
    do { try badEncoding.publish(BadEncoding(), as: .baseline, check: {}, write: { _ in throw ProbeError("unexpected write") }) }
    catch Fault.expected { exactEncoding = true }
    try require("encoding error preserved", exactEncoding)
    try reject("encoding error poisons publisher") { try badEncoding.publish(1, as: .baseline, check: {}, write: { _ in }) }
    let maximum = String(repeating: "x", count: QwenDenseShortParityOutput.recordByteLimit - 3)
    let bounded = QwenDenseShortParityOutput(); var lengths: [Int] = []
    try bounded.publish(maximum, as: .baseline, check: {}, write: { lengths.append($0.count) })
    try bounded.publish(maximum, as: .comparison, check: {}, write: { lengths.append($0.count) })
    try bounded.requireComplete()
    try require("exact encoded 32 MiB each and 64 MiB total including newlines", lengths == [33_554_432, 33_554_432])
    let oversized = QwenDenseShortParityOutput()
    try reject("encoded record one byte too large") { try oversized.publish(maximum + "x", as: .baseline, check: {}, write: { _ in throw ProbeError("unexpected write") }) }
    let escaped = QwenDenseShortParityOutput()
    try reject("encoded escaping counted before write") { try escaped.publish(String(repeating: "\n", count: 16_777_215), as: .baseline, check: {}, write: { _ in throw ProbeError("unexpected write") }) }
    let reentrant = QwenDenseShortParityOutput(); var reentered = false, escapedWrites = 0
    try reject("swallowed reentrant check still rejects outer") {
        try reentrant.publish(1, as: .baseline, check: {
            if !reentered { reentered = true; try? reentrant.publish(2, as: .baseline, check: {}, write: { _ in escapedWrites += 1 }) }
        }, write: { _ in escapedWrites += 1 })
    }
    try require("reentrant check emits no record", escapedWrites == 0)
    return .init(accepted: accepted, rejected: rejected)
}
