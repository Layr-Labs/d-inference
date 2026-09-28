import Foundation
import Darwin

func checkQwenPrefillOwnerOutput() throws -> QwenPrefillOwnerOutputCheckReceipt {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("owner-output-check-" + UUID().uuidString)
    guard directory.path.withCString({ mkdir($0, mode_t(0o700)) }) == 0 else {
        throw QwenPrefillOwnerError("Cannot create owner output fixture directory")
    }
    defer { try? FileManager.default.removeItem(at: directory) }
    let identity = try QwenPrefillOwnerIdentity(requestFingerprint: String(repeating: "a", count: 64),
        profile: "long_prefill_8k_v1", role: .solo)
    var cases: [String] = []
    func path(_ name: String) -> URL { directory.appendingPathComponent(name + ".json") }
    func require(_ value: Bool) throws { try QwenPrefillPhaseFileCheck.require(value, "Owner output fixture failed") }
    func exists(_ url: URL) -> Bool { QwenPrefillPhaseFileCheck.exists(url) }
    func reject(_ body: () throws -> Void) throws { try QwenPrefillPhaseFileCheck.reject("owner output", body) }
    func owner(_ capture: QwenPrefillOwnerCapture, count: Int = 8) throws -> QwenPrefillOwnerRecorder {
        let recorder = try capture.makeRecorder(identity: identity)
        for (index, phase) in CBv2OwnerPhase.allCases.prefix(count).enumerated() {
            try recorder.observe(.init(phase: phase, tokenCount: 512, committedTokens: index == 7 ? 4096 : 3584))
        }
        return recorder
    }
    func phase(_ capture: QwenPrefillPhaseCapture) throws -> QwenPrefillPhaseRecorder {
        let value = try QwenPrefillPhaseFileCheck.identity()
        let recorder = try capture.makeRecorder(identity: value)
        try recorder.begin(expectedIdentity: value)
        try recorder.observe(phase: "fixture.outer", committedTokens: 0)
        try recorder.seal()
        return recorder
    }

    let disabled = try withQwenPrefillTraceCaptures(phaseOutput: nil, ownerOutput: nil) { a, b in
        try require(a == nil && b == nil); return 17
    }
    try require(disabled == 17); cases.append("disabled_allocates_no_captures")
    let solo = path("owner-success")
    try withQwenPrefillTraceCaptures(phaseOutput: nil, ownerOutput: solo) { a, b in
        try require(a == nil); _ = try owner(b!)
        try require(!exists(solo))
    }
    let raw = try Data(contentsOf: solo)
    let row = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
    try require(row["kind"] as? String == "qwen_prefill_selected_owner_trace"
        && (row["events"] as? [Any])?.count == 8 && raw.last == 10)
    let attributes = try FileManager.default.attributesOfItem(atPath: solo.path)
    try require((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    cases.append("owner_schema_mode600_after_outer_return")

    let bothA = path("both-phase"), bothB = path("both-owner")
    try withQwenPrefillTraceCaptures(phaseOutput: bothA, ownerOutput: bothB) { a, b in
        _ = try phase(a!); _ = try owner(b!); try require(!exists(bothA) && !exists(bothB))
    }
    try require(exists(bothA) && exists(bothB)); cases.append("independent_schemas_publish_after_outer_return")
    var ran = false
    try reject {
        try withQwenPrefillTraceCaptures(phaseOutput: path("same"), ownerOutput: path("same")) { _, _ in ran = true }
    }
    try require(!ran && !exists(path("same"))); cases.append("same_path_rejected_before_execution")

    for state in ["missing", "partial", "failed", "duplicate"] {
        let output = path(state), capture = try QwenPrefillOwnerCapture(output: path(state))
        if state != "missing" {
            let recorder = try owner(capture, count: state == "partial" ? 7 : 8)
            if state == "failed" { recorder.fail() }
            if state == "duplicate" { try reject { _ = try capture.makeRecorder(identity: identity) } }
        }
        try reject { try capture.publishAfterOwnerSuccess() }
        try require(!exists(output)); cases.append(state + "_owner_cannot_publish")
    }
    enum LateError: Error { case nativeCheck }
    var retainedPhase: QwenPrefillPhaseRecorder?, retainedOwner: QwenPrefillOwnerRecorder?
    let failedA = path("failed-phase"), failedB = path("failed-owner")
    try reject {
        try withQwenPrefillTraceCaptures(phaseOutput: failedA, ownerOutput: failedB) { a, b in
            retainedPhase = try phase(a!); retainedOwner = try owner(b!)
            throw LateError.nativeCheck
        }
    }
    try require(!exists(failedA) && !exists(failedB))
    try reject { _ = try retainedPhase!.successfulTrace() }
    try reject { try retainedOwner!.sealAfterOuterSuccess() }
    cases.append("late_outer_failure_poisons_both_without_files")

    // If the second publication fails, the first file is retained as partial
    // evidence. Both mutable recorders become unusable and execution fails.
    let partialA = path("partial-phase"), partialB = path("partial-owner")
    let marker = Data("created during the outer owner".utf8)
    try reject {
        try withQwenPrefillTraceCaptures(phaseOutput: partialA, ownerOutput: partialB) { a, b in
            retainedPhase = try phase(a!); retainedOwner = try owner(b!)
            try marker.write(to: partialB)
        }
    }
    try require(exists(partialA) && (try Data(contentsOf: partialB)) == marker)
    try reject { _ = try retainedPhase!.successfulTrace() }
    try reject { _ = try retainedOwner!.successfulTrace() }
    cases.append("second_write_failure_preserves_files_and_poisons_both")

    let oncePath = path("once"), once = try QwenPrefillOwnerCapture(output: path("once"))
    _ = try owner(once); try once.publishAfterOwnerSuccess()
    let original = try Data(contentsOf: oncePath)
    try reject { try once.publishAfterOwnerSuccess() }
    try require(try Data(contentsOf: oncePath) == original)
    cases.append("duplicate_publication_preserves_original_bytes")
    return .init(cases: cases)
}

struct QwenPrefillOwnerOutputCheckReceipt: Encodable {
    let kind = "qwen_prefill_owner_output_check"
    let cpuOnly = true, nativeExecution = false, passed = true
    let cases: [String]
}
