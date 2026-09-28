import Foundation

func checkObservedManifestPin(_ checks: inout QwenObservedFixtureChecks) throws {
    let raw = Data("{\"files\":[]}\n".utf8), digest = sha256(raw)
    try QwenCheckpointManifestPin.validateExpected(nil)
    try checks.require("manifest nil keeps legacy unbound", try QwenCheckpointManifestPin.match(raw, expected: nil) == nil)
    try checks.require("manifest exact raw bytes", try QwenCheckpointManifestPin.match(raw, expected: digest) == digest)
    try checks.reject("manifest changed whitespace is different raw identity") {
        _ = try QwenCheckpointManifestPin.match(raw + Data([32]), expected: digest)
    }
    try checks.reject("manifest wrong independent pin") {
        _ = try QwenCheckpointManifestPin.match(raw, expected: String(repeating: "0", count: 64))
    }
    for value in ["", "0", String(repeating: "A", count: 64), String(repeating: "g", count: 64)] {
        try checks.reject("manifest malformed expectation " + value) { try QwenCheckpointManifestPin.validateExpected(value) }
    }
    let oversized = Data(repeating: 32, count: 4 * 1024 * 1024 + 1)
    try checks.reject("manifest pinned metadata cap") { _ = try QwenCheckpointManifestPin.match(oversized, expected: digest) }
    try checks.require("manifest nil does not add a metadata cap", try QwenCheckpointManifestPin.match(oversized, expected: nil) == nil)
}
