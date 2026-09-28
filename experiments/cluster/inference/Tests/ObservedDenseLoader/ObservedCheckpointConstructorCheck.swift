import CryptoKit
import Foundation

/// Exercise the actual proposed Foundation/Darwin constructor on a new private
/// directory containing only a tiny invented config and three-byte payload.
/// No model directory, downloaded header or checkpoint is accepted as input.
func checkObservedCheckpointConstructor(_ checks: inout QwenObservedFixtureChecks) throws {
    let manager = FileManager.default
    let directory = manager.temporaryDirectory.appendingPathComponent("qwen-observed-check-" + UUID().uuidString, isDirectory: true)
    try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? manager.removeItem(at: directory) }
    let config = Data("{}\n".utf8), payload = Data([1, 2, 3])
    try config.write(to: directory.appendingPathComponent("config.json"))
    try payload.write(to: directory.appendingPathComponent("payload.bin"))
    func manifest(payloadName: String) throws -> (data: Data, aggregate: String) {
        let entries = [CheckpointManifest.Entry(path: "config.json", sha256: sha256(config), size_bytes: config.count),
            .init(path: payloadName, sha256: sha256(payload), size_bytes: payload.count)]
        var digests = Data()
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            digests.append(contentsOf: SHA256.hash(data: entry.path == "config.json" ? config : payload))
        }
        let aggregate = sha256(digests)
        let manifest = CheckpointManifest(aggregate_sha256: aggregate, file_count: 2,
            total_size_bytes: config.count + payload.count, files: entries)
        return (try canonicalJSONData(manifest), aggregate)
    }
    func rejectExact(_ label: String, _ expected: String, _ body: () throws -> Void) throws {
        do { try body() } catch {
            guard String(describing: error) == expected else {
                throw ProbeError("Constructor fixture received wrong error for \(label): \(error)")
            }
            checks.rejected.append(label); return
        }
        throw ProbeError("Constructor fixture accepted invalid case: " + label)
    }
    let valid = try manifest(payloadName: "payload.bin")
    try valid.data.write(to: directory.appendingPathComponent("manifest.json"))
    let pinned = try VerifiedCheckpoint(directory: directory, configurationData: config,
        expectedAggregateSHA256: valid.aggregate, expectedManifestSHA256: sha256(valid.data))
    try pinned.checkUnchanged()
    try checks.require("constructor exact raw pin and full aggregate", pinned.verifiedManifestSHA256 == sha256(valid.data) &&
        pinned.aggregate == valid.aggregate && Set(pinned.files.keys) == Set(["config.json", "payload.bin"]))
    let legacy = try VerifiedCheckpoint(directory: directory, configurationData: config,
        expectedAggregateSHA256: valid.aggregate)
    try checks.require("constructor legacy nil remains nil", legacy.verifiedManifestSHA256 == nil && legacy.aggregate == valid.aggregate)

    let missing = try manifest(payloadName: "missing.bin")
    try missing.data.write(to: directory.appendingPathComponent("manifest.json"))
    try rejectExact("constructor wrong raw pin precedes missing payload", "Checkpoint raw manifest differs from expected SHA256") {
        _ = try VerifiedCheckpoint(directory: directory, configurationData: config,
            expectedAggregateSHA256: missing.aggregate, expectedManifestSHA256: String(repeating: "0", count: 64))
    }
    try rejectExact("constructor matching pin still verifies missing payload", "Cannot open checkpoint file missing.bin") {
        _ = try VerifiedCheckpoint(directory: directory, configurationData: config,
            expectedAggregateSHA256: missing.aggregate, expectedManifestSHA256: sha256(missing.data))
    }
    try rejectExact("constructor malformed pin precedes directory IO", "Expected manifest must be a lowercase SHA256") {
        _ = try VerifiedCheckpoint(directory: directory.appendingPathComponent("absent-directory"),
            configurationData: config, expectedManifestSHA256: "not-a-sha256")
    }
    try valid.data.write(to: directory.appendingPathComponent("manifest.json"))
    try Data([1, 2, 4]).write(to: directory.appendingPathComponent("payload.bin"))
    try rejectExact("constructor matching raw pin cannot hide corrupt payload", "Checkpoint SHA256 mismatch: payload.bin") {
        _ = try VerifiedCheckpoint(directory: directory, configurationData: config,
            expectedAggregateSHA256: valid.aggregate, expectedManifestSHA256: sha256(valid.data))
    }
    try rejectExact("constructor legacy still refuses corrupt payload", "Checkpoint SHA256 mismatch: payload.bin") {
        _ = try VerifiedCheckpoint(directory: directory, configurationData: config, expectedAggregateSHA256: valid.aggregate)
    }
}
