import Foundation
import Darwin

struct QwenPrefillPhaseOutputCheckReceipt: Encodable {
    let kind = "qwen_prefill_phase_output_check", schemaVersion = 1
    let cpuOnly = true, nativeModelExecuted = false, temporaryFilesOnly = true
    let recorderDoesNotProveRealRequestRetirement = true
    let cases: [String]
    let maximumSidecarBytes: Int
    let passed = true
}

/// Standalone Foundation/Darwin fixtures. A few capture observations use the
/// production CPU clock; file roundtrip arithmetic uses an injected clock.
func checkQwenPrefillPhaseOutput() throws -> QwenPrefillPhaseOutputCheckReceipt {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("phase-output-check-" + UUID().uuidString)
    let created = directory.path.withCString { mkdir($0, mode_t(0o700)) }
    guard created == 0 else { throw QwenPrefillPhaseError("Cannot create exclusive phase fixture directory") }
    defer { try? FileManager.default.removeItem(at: directory) }
    var cases = try QwenPrefillPhaseFileCheck.run(directory: directory)
    let identity = try QwenPrefillPhaseFileCheck.identity()

    func recorder(_ capture: QwenPrefillPhaseCapture, sealed: Bool) throws -> QwenPrefillPhaseRecorder {
        let owner = try capture.makeRecorder(identity: identity)
        try owner.begin(expectedIdentity: identity)
        try owner.observe(phase: "fixture.owner", committedTokens: 0)
        if sealed { try owner.seal() }
        return owner
    }

    let disabled: Int = try withQwenPrefillPhaseCapture(output: nil) { capture in
        try QwenPrefillPhaseFileCheck.require(capture == nil, "disabled capture was allocated")
        return 7
    }
    try QwenPrefillPhaseFileCheck.require(disabled == 7, "disabled wrapper changed its result")
    cases.append("disabled_wrapper_passes_nil_and_result")

    let successful = directory.appendingPathComponent("owner-success.json")
    let returned: Int = try withQwenPrefillPhaseCapture(output: successful) { capture in
        guard let capture else { throw QwenPrefillPhaseError("Missing enabled capture") }
        _ = try recorder(capture, sealed: true)
        try QwenPrefillPhaseFileCheck.require(!QwenPrefillPhaseFileCheck.exists(successful), "file opened before owner returned")
        return 23
    }
    try QwenPrefillPhaseFileCheck.require(returned == 23 && QwenPrefillPhaseFileCheck.exists(successful),
                                        "successful wrapper did not publish after return")
    cases.append("publication_follows_successful_outer_return")

    for state in ["missing", "unsealed", "failed"] {
        let path = directory.appendingPathComponent(state + ".json")
        let capture = try QwenPrefillPhaseCapture(output: path)
        if state != "missing" {
            let owner = try recorder(capture, sealed: state == "failed")
            if state == "failed" { owner.fail() }
        }
        try QwenPrefillPhaseFileCheck.reject(state + " publication") { try capture.publishAfterOwnerSuccess() }
        try QwenPrefillPhaseFileCheck.require(!QwenPrefillPhaseFileCheck.exists(path), "invalid owner published a file")
        cases.append(state + "_owner_has_no_publication")
    }

    let duplicate = directory.appendingPathComponent("duplicate-owner.json")
    let capture = try QwenPrefillPhaseCapture(output: duplicate)
    let first = try capture.makeRecorder(identity: identity)
    try QwenPrefillPhaseFileCheck.reject("duplicate owner") { _ = try capture.makeRecorder(identity: identity) }
    try QwenPrefillPhaseFileCheck.reject("poisoned original owner") { try first.begin(expectedIdentity: identity) }
    try QwenPrefillPhaseFileCheck.reject("duplicate-owner publication") { try capture.publishAfterOwnerSuccess() }
    try QwenPrefillPhaseFileCheck.require(!QwenPrefillPhaseFileCheck.exists(duplicate), "duplicate owner produced a file")
    cases.append("duplicate_owner_poisoned_without_file")

    let published = directory.appendingPathComponent("one-publication.json")
    let once = try QwenPrefillPhaseCapture(output: published); _ = try recorder(once, sealed: true)
    try once.publishAfterOwnerSuccess(); let original = try Data(contentsOf: published)
    try QwenPrefillPhaseFileCheck.reject("duplicate publication") { try once.publishAfterOwnerSuccess() }
    try QwenPrefillPhaseFileCheck.require(try Data(contentsOf: published) == original, "duplicate publication altered completed file")
    cases.append("duplicate_publication_preserves_existing_bytes")

    let raced = directory.appendingPathComponent("created-after-preflight.json")
    let late = try QwenPrefillPhaseCapture(output: raced); _ = try recorder(late, sealed: true)
    let marker = Data("existing owned marker".utf8); try marker.write(to: raced)
    try QwenPrefillPhaseFileCheck.reject("path created after preflight") { try late.publishAfterOwnerSuccess() }
    try QwenPrefillPhaseFileCheck.require(try Data(contentsOf: raced) == marker, "publication overwrote a later-created path")
    cases.append("post_preflight_path_creation_preserved")

    enum InjectedOwnerFailure: Error { case failed, cancelled, lateNativeCheck }
    for (name, error) in [("failed", InjectedOwnerFailure.failed), ("cancelled", .cancelled), ("late-native", .lateNativeCheck)] {
        let path = directory.appendingPathComponent("outer-" + name + ".json")
        var retained: QwenPrefillPhaseRecorder?
        try QwenPrefillPhaseFileCheck.reject(name + " outer owner") {
            let _: Int = try withQwenPrefillPhaseCapture(output: path) { capture in
                guard let capture else { throw QwenPrefillPhaseError("Missing capture in failure fixture") }
                retained = try recorder(capture, sealed: name != "cancelled")
                throw error
            }
        }
        try QwenPrefillPhaseFileCheck.require(!QwenPrefillPhaseFileCheck.exists(path), "failed/cancelled owner published trace")
        try QwenPrefillPhaseFileCheck.reject(name + " retained partial/sealed trace") { _ = try retained!.successfulTrace() }
        cases.append(name + "_outer_error_discards_trace_before_publication")
    }
    return .init(cases: cases, maximumSidecarBytes: QwenPrefillPhaseFile.maximumBytes)
}
