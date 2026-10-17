import CryptoKit
import Darwin
import Foundation
@testable import DarkbloomClusterRuntimeChecks

enum TestFailure: Error { case failed(String) }
func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    guard value() else { throw TestFailure.failed(message) }
}
func reject(_ message: String, _ body: () throws -> Void) throws {
    do { try body() } catch is TestFailure { throw TestFailure.failed(message) } catch { return }
    throw TestFailure.failed(message)
}
func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
func sha256Hex(_ data: Data) -> String { hex(Data(SHA256.hash(data: data))) }
func unhex(_ string: String) -> Data {
    var data = Data(); var i = string.startIndex
    while i < string.endIndex {
        let next = string.index(i, offsetBy: 2)
        data.append(UInt8(string[i..<next], radix: 16)!); i = next
    }
    return data
}

struct FixtureCheckpoint {
    let root: URL
    let config: Data
    let payloads: [String: Data]
    let manifestData: Data
    let manifestSHA256: String
    let aggregate: String

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("checkpoint-fixture-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        config = Data(#"{"arch":"fixture","layers":2}"#.utf8)
        payloads = [
            "model-00001-of-00002.safetensors": Data((0..<8192).map { UInt8($0 % 251) }),
            "model-00002-of-00002.safetensors": Data((0..<4096).map { UInt8(($0 * 7) % 241) }),
        ]
        var entries: [[String: Any]] = [["path": "config.json", "sha256": sha256Hex(config), "size_bytes": config.count]]
        var aggregateHasher = SHA256()
        var digestHex: [String] = []
        for (path, bytes) in payloads.sorted(by: { $0.key < $1.key }) {
            let digest = Data(SHA256.hash(data: bytes))
            digestHex.append(hex(digest))
            entries.append(["path": path, "sha256": hex(digest), "size_bytes": bytes.count])
        }
        // The aggregate is over the per-file digests in sorted path order
        // (config.json first, then payload paths).
        var sortedDigests: [Data] = [Data(SHA256.hash(data: config))]
        for hexDigest in digestHex { sortedDigests.append(unhex(hexDigest)) }
        for digest in sortedDigests { aggregateHasher.update(data: digest) }
        aggregate = hex(Data(aggregateHasher.finalize()))
        let total = payloads.values.reduce(config.count) { $0 + $1.count }
        let object: [String: Any] = ["aggregate_sha256": aggregate, "file_count": entries.count,
            "total_size_bytes": total, "files": entries]
        manifestData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        manifestSHA256 = sha256Hex(manifestData)
        try config.write(to: root.appendingPathComponent("config.json"), options: .withoutOverwriting)
        for (path, bytes) in payloads { try bytes.write(to: root.appendingPathComponent(path), options: .withoutOverwriting) }
        try manifestData.write(to: root.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
    }

    func rewrite(_ path: String, bytes: Data) throws {
        try bytes.write(to: root.appendingPathComponent(path), options: [])
    }
}

@main enum CheckpointCheck {
    static func main() {
        do {
            try verifiedCheckpointAgreesAndPins()
            try manifestRefusals()
            try alignedReadContract()
            print(#"{"passed":true,"groups":3,"modelExecution":false,"mlxUsed":false,"networkUsed":false}"#)
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }

    static func verifiedCheckpointAgreesAndPins() throws {
        let fixture = try FixtureCheckpoint()
        let verified = try VerifiedCheckpoint(directory: fixture.root, configurationData: fixture.config,
            expectedAggregateSHA256: fixture.aggregate, maximumPayloadBytes: 16 * 1024,
            expectedManifestSHA256: fixture.manifestSHA256)
        try require(verified.aggregate == fixture.aggregate, "aggregate differs")
        try require(verified.verifiedManifestSHA256 == fixture.manifestSHA256, "manifest pin not retained")
        try require(verified.files.count == 3, "manifest file set changed")
        // Pinned descriptors notice byte changes under the same path.
        let payload = fixture.payloads.keys.sorted().first!
        var changed = fixture.payloads[payload]!
        changed[10] ^= 1
        try fixture.rewrite(payload, bytes: changed)
        try reject("modified payload not detected") {
            _ = try VerifiedCheckpoint(directory: fixture.root, configurationData: fixture.config,
                expectedAggregateSHA256: fixture.aggregate, expectedManifestSHA256: fixture.manifestSHA256)
        }
    }

    static func manifestRefusals() throws {
        let fixture = try FixtureCheckpoint()
        // Wrong aggregate expectation.
        try reject("wrong aggregate admitted") {
            _ = try VerifiedCheckpoint(directory: fixture.root, configurationData: fixture.config,
                expectedAggregateSHA256: String(repeating: "a", count: 64))
        }
        // Wrong raw-manifest pin.
        try reject("wrong manifest pin admitted") {
            _ = try VerifiedCheckpoint(directory: fixture.root, configurationData: fixture.config,
                expectedManifestSHA256: String(repeating: "b", count: 64))
        }
        // Payload byte limit is enforced against the manifest's own counts.
        try reject("payload limit bypassed") {
            _ = try VerifiedCheckpoint(directory: fixture.root, configurationData: fixture.config,
                maximumPayloadBytes: 1024)
        }
        // Loaded configuration must be the manifest's exact configuration.
        try reject("substituted configuration admitted") {
            _ = try VerifiedCheckpoint(directory: fixture.root, configurationData: Data("other".utf8))
        }
        // A manifest whose path escapes the checkpoint directory is refused.
        var escaped = try JSONSerialization.jsonObject(with: fixture.manifestData) as! [String: Any]
        var files = escaped["files"] as! [[String: Any]]
        files.append(["path": "../outside", "sha256": String(repeating: "c", count: 64), "size_bytes": 1])
        escaped["files"] = files
        escaped["file_count"] = files.count
        let escapedData = try JSONSerialization.data(withJSONObject: escaped, options: [.sortedKeys])
        let escapedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("checkpoint-escaped-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: escapedRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: escapedRoot) }
        for file in ["config.json", "model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors"] {
            let source = fixture.root.appendingPathComponent(file)
            try FileManager.default.copyItem(at: source, to: escapedRoot.appendingPathComponent(file))
        }
        try escapedData.write(to: escapedRoot.appendingPathComponent("manifest.json"))
        try reject("escaping manifest path admitted") {
            _ = try VerifiedCheckpoint(directory: escapedRoot, configurationData: fixture.config)
        }
        // Non-lowercase expectations are rejected before any file work.
        try reject("malformed expectation admitted") {
            _ = try VerifiedCheckpoint(directory: fixture.root, configurationData: fixture.config,
                expectedManifestSHA256: "ZZZ")
        }
    }

    static func alignedReadContract() throws {
        let fixture = try FixtureCheckpoint()
        let payload = fixture.payloads.keys.sorted().first!
        let verified = try VerifiedCheckpoint(directory: fixture.root, configurationData: fixture.config)
        let file = verified.files[payload]!
try require(verified.files[payload] != nil, "payload file missing")
        let source = fixture.payloads[payload]!
        // An unaligned window is read through page-aligned scratch; the
        // destination must equal the exact source slice.
        let offset = 123, count = 3000
        let destination = UnsafeMutableRawBufferPointer.allocate(byteCount: count, alignment: 1)
        defer { destination.deallocate() }
        let accounting = try CheckpointAlignedReader.read(descriptor: file.descriptor, fileSize: file.size,
            into: destination, offset: offset, checkUnchanged: {})
        try require(Data(bytes: destination.baseAddress!, count: count) == source.subdata(in: offset..<(offset + count)),
            "aligned read bytes differ from source slice")
        try require(accounting.selectedBytes == count && accounting.preadCalls >= 1, "accounting lost the read")
        // A descriptor below zero or an out-of-file window never reads.
        try reject("invalid descriptor read") {
            _ = try CheckpointAlignedReader.read(descriptor: -1, fileSize: file.size,
                into: destination, offset: 0, checkUnchanged: {})
        }
        try reject("out-of-file window read") {
            _ = try CheckpointAlignedReader.read(descriptor: file.descriptor, fileSize: file.size,
                into: destination, offset: file.size + 1, checkUnchanged: {})
        }
        // EINTR retries the SAME aligned pointer/offset/length before continuing.
        var attempts: [(Int, off_t)] = [], calls = 0
        _ = try CheckpointAlignedReader.read(descriptor: file.descriptor, fileSize: file.size,
            into: destination, offset: offset, checkUnchanged: {},
            readCall: { descriptor, pointer, requested, at in
                calls += 1
                if calls == 1 { errno = EINTR; return -1 }
                attempts.append((requested, at))
                return Darwin.pread(descriptor, pointer, requested, at)
            })
        try require(attempts.count >= 1, "retry never issued a real read")
        // A permanently short read fails closed.
        try reject("short read admitted") {
            _ = try CheckpointAlignedReader.read(descriptor: file.descriptor, fileSize: file.size,
                into: destination, offset: offset, checkUnchanged: {},
                readCall: { _, _, _, _ in 0 })
        }
        // A mid-read unchanged failure aborts publication.
        try reject("post-read tamper admitted") {
            _ = try CheckpointAlignedReader.read(descriptor: file.descriptor, fileSize: file.size,
                into: destination, offset: offset, checkUnchanged: { throw ProbeError("changed") })
        }
    }
}
