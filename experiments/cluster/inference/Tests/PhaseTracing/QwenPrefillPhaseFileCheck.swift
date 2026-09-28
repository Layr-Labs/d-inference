import Foundation
import Darwin

/// Only caller-owned temporary files are touched by these CPU fixtures.
enum QwenPrefillPhaseFileCheck {
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw QwenPrefillPhaseError("Phase output check: \(message)") }
    }

    static func reject(_ label: String, _ body: () throws -> Void) throws {
        var rejected = false
        do { try body() } catch { rejected = true }
        try require(rejected, "accepted \(label)")
    }

    static func exists(_ path: URL) -> Bool {
        var information = stat()
        return path.path.withCString { lstat($0, &information) } == 0
    }

    static func identity() throws -> QwenPrefillPhaseIdentity {
        try .init(requestFingerprint: String(repeating: "a", count: 64),
                  profile: "long_prefill_8k_v1", role: .solo)
    }

    static func makeTrace() throws -> QwenPrefillPhaseTrace {
        let owner = try identity()
        var now: UInt64 = 100
        let recorder = try QwenPrefillPhaseRecorder(identity: owner, maximumEvents: 4, testClock: {
            defer { now += 10 }; return now
        })
        try recorder.begin(expectedIdentity: owner)
        try recorder.observe(phase: "fixture.begin", committedTokens: 0)
        try recorder.observe(phase: "fixture.end", frameSequence: 15, committedTokens: 8192)
        try recorder.seal()
        return try recorder.successfulTrace()
    }

    static func run(directory: URL) throws -> [String] {
        let trace = try makeTrace(), path = directory.appendingPathComponent("direct.json")
        try QwenPrefillPhaseFile.preflight(path)
        try require(!exists(path), "preflight created a file")
        try QwenPrefillPhaseFile.write(trace, to: path)
        let bytes = try Data(contentsOf: path)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var expected = try encoder.encode(trace); expected.append(10)
        try require(bytes == expected && bytes.count <= QwenPrefillPhaseFile.maximumBytes,
                    "written JSON differs from the sealed CPU trace")
        var information = stat()
        try require(path.path.withCString { lstat($0, &information) } == 0,
                    "successful file is missing")
        try require((information.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
                    && (information.st_mode & mode_t(0o7777)) == mode_t(0o600),
                    "successful sidecar is not a private regular mode600 file")
        let parsed = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        try require(parsed?["clockSource"] as? String == "injected_test_clock"
                    && parsed?["modelReleaseAsserted"] as? Bool == false,
                    "file changed clock provenance or model-release scope")

        try reject("existing file preflight") { try QwenPrefillPhaseFile.preflight(path) }
        try reject("existing file write") { try QwenPrefillPhaseFile.write(trace, to: path) }
        try require(try Data(contentsOf: path) == bytes, "refused existing file was altered")

        let missingParent = directory.appendingPathComponent("absent/phase.json")
        try reject("missing parent") { try QwenPrefillPhaseFile.preflight(missingParent) }
        try reject("non-file URL") { try QwenPrefillPhaseFile.preflight(URL(string: "https://invalid.example/trace")!) }
        try reject("directory destination") { try QwenPrefillPhaseFile.preflight(directory) }

        for (name, target) in [("existing-link", path), ("broken-link", directory.appendingPathComponent("no-target"))] {
            let link = directory.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            try reject(name + " preflight") { try QwenPrefillPhaseFile.preflight(link) }
            try reject(name + " write") { try QwenPrefillPhaseFile.write(trace, to: link) }
            try require(exists(link), "refused symlink was removed")
        }
        try require(try Data(contentsOf: path) == bytes, "symlink target was altered")
        try require(!exists(directory.appendingPathComponent("no-target")), "broken symlink target was created")

        // Deliberately bypass the recorder only to exercise the final file-size
        // guard. This is not an admitted successful request trace.
        let oversized = QwenPrefillPhaseTrace(identity: trace.identity, clockSource: .injectedTestClock,
            maximumEvents: 1, events: [.init(ordinal: 0,
                phase: String(repeating: "x", count: QwenPrefillPhaseFile.maximumBytes),
                frameSequence: nil, committedTokens: 0, localUptimeNanoseconds: 0)],
            firstLocalUptimeNanoseconds: 0, lastLocalUptimeNanoseconds: 0, traceSpanNanoseconds: 0)
        let large = directory.appendingPathComponent("oversized.json")
        try reject("oversized serialization") { try QwenPrefillPhaseFile.write(oversized, to: large) }
        try require(!exists(large), "oversized trace opened a file before rejection")
        return ["exclusive_json_roundtrip_mode600", "preflight_has_no_file_side_effect",
            "existing_file_preserved", "missing_parent_refused", "non_file_url_refused", "directory_refused",
            "existing_symlink_preserved", "broken_symlink_preserved", "oversized_trace_refused_before_create"]
    }
}
