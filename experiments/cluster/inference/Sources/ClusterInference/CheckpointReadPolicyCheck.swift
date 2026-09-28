import CryptoKit
import Foundation

/// Real descriptor IO on a tiny CPU fixture; no model arrays or GPU work.
/// This checks byte/identity behavior, not the amount of physical memory saved.
func checkCheckpointReadPolicy() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("checkpoint-read-policy-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("fixture.safetensors")
    let bytes = Data((0..<8192).map { UInt8($0 % 251) })
    try bytes.write(to: url)
    let file = try VerifiedCheckpoint.File(url: url, path: "fixture.safetensors", expectedSize: bytes.count)
    let expected = SHA256.hash(data: bytes)
    guard try file.digest() == expected,
        try file.data(offset: 11, count: 2049) == bytes.subdata(in: 11..<2060) else {
        throw ProbeError("Cached checkpoint fixture differs")
    }
    try file.bypassPayloadCache()
    try file.bypassPayloadCache()
    guard try file.data(offset: 3, count: 4097) == bytes.subdata(in: 3..<4100),
        try file.digest() == expected else {
        throw ProbeError("Uncached checkpoint fixture differs")
    }
    // Rehashing cannot change bytes; subsequent selected reads still work.
    guard try file.data(offset: 0, count: bytes.count) == bytes else {
        throw ProbeError("Post-hash checkpoint fixture differs")
    }
    var refusedBounds = false
    do { _ = try file.data(offset: bytes.count - 1, count: 2) }
    catch { refusedBounds = String(describing: error).contains("out of range") }
    guard refusedBounds else { throw ProbeError("Uncached read weakened file bounds") }
    let handle = try FileHandle(forWritingTo: url)
    try handle.seek(toOffset: 17)
    try handle.write(contentsOf: Data([255]))
    try handle.close()
    var refusedMutation = false
    do { try file.checkUnchanged() }
    catch { refusedMutation = String(describing: error).contains("changed during") }
    guard refusedMutation else { throw ProbeError("Uncached read weakened file identity") }
    struct Result: Encodable {
        let kind = "checkpoint_read_policy_check"
        let cpuOnly = true
        let cachedAndUncachedBytesIdentical = true
        let repeatedPolicyAndRehash = true
        let boundsAndMutationRefused = true
        let physicalMemorySavingsMeasured = false
    }
    try emitJSON(Result())
}
