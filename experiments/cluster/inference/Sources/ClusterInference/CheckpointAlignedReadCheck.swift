import CryptoKit
import Darwin
import Foundation

struct CheckpointAlignedReadCheckResult: Encodable {
    let kind = "checkpoint_aligned_selected_read_check"
    let accepted: [String], rejected: [String]
    let cpuOnly = true, modelPayloadRead = false, physicalCacheSavingsMeasured = false
}

func checkAlignedCheckpointPayloadRead() throws -> CheckpointAlignedReadCheckResult {
    var accepted = [String](), rejected = [String]()
    func require(_ value: Bool, _ message: String) throws {
        guard value else { throw ProbeError("Aligned read fixture: " + message) }
    }
    func accept(_ name: String, _ body: () throws -> Void) throws { try body(); accepted.append(name) }
    func reject(_ name: String, _ body: () throws -> Void) throws {
        do { try body() } catch { rejected.append(name); return }
        throw ProbeError("Aligned read fixture unexpectedly accepted " + name)
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aligned-read-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let a = CheckpointAlignedReadPlan.alignmentBytes, b = CheckpointAlignedReadPlan.maximumScratchRequestBytes
    let bytes = Data((0..<(b + 3 * a + 37)).map { UInt8($0 % 251) })
    let url = directory.appendingPathComponent("fixture.safetensors")
    try bytes.write(to: url)
    let file = try VerifiedCheckpoint.File(url: url, path: "fixture.safetensors", expectedSize: bytes.count)
    try require(try file.digest() == SHA256.hash(data: bytes), "fixture hash differs")
    try accept("ordinary reads retain exact bytes and no aligned accounting") {
        var output = Data(count: 79)
        let stats = try output.withUnsafeMutableBytes { try file.read(into: $0, offset: 11) }
        try require(stats == nil && output == bytes.subdata(in: 11..<90), "cached path changed")
    }
    try file.bypassPayloadCache()
    func read(_ offset: Int, _ count: Int) throws -> (Data, CheckpointAlignedReadAccounting) {
        var result = Data(count: count)
        let accounting = try result.withUnsafeMutableBytes { try file.read(into: $0, offset: offset) }
        guard let accounting else { throw ProbeError("Fixture aligned accounting missing") }
        return (result, accounting)
    }
    try accept("unaligned destination and selected offset preserve guard bytes") {
        let count = a + 19
        var storage = Data(repeating: 0xa5, count: count + 10)
        let stats = try storage.withUnsafeMutableBytes { buffer in
            try file.read(into: .init(start: buffer.baseAddress!.advanced(by: 5), count: count), offset: 17)
        }
        try require(storage.prefix(5) == Data(repeating: 0xa5, count: 5)
            && storage.suffix(5) == Data(repeating: 0xa5, count: 5)
            && storage.subdata(in: 5..<(count + 5)) == bytes.subdata(in: 17..<(17 + count)), "copy crossed selection")
        try require(stats?.selectedBytes == count && stats?.returnedReadBytes == 2 * a, "padding not separated")
    }
    try accept("multiple aligned windows copy one selected tensor") {
        let (actual, stats) = try read(7, b + 31)
        try require(actual == bytes.subdata(in: 7..<(b + 38)) && stats.preadCalls == 2
            && stats.selectedBytes == b + 31 && stats.largestScratchRequestBytes == b
            && stats.largestScratchAllocationBytes >= b && stats.largestScratchAllocationBytes <= b + a,
            "window or scratch bound differs")
    }
    try accept("EOF short return counts actual padding instead of requested tail") {
        let (actual, stats) = try read(bytes.count - 31, 31)
        try require(actual == bytes.suffix(31) && stats.requestedReadBytes == a
            && stats.returnedReadBytes == 37 && stats.paddingReadBytes == 6
            && stats.shortEOFReads == 1, "EOF rounding was counted as copied data")
    }
    try accept("whole file including partial final page is exact") {
        let (actual, stats) = try read(0, bytes.count)
        try require(actual == bytes && stats.selectedBytes == bytes.count && stats.paddingReadBytes == 0
            && stats.shortEOFReads == 1, "whole-file exact copy differs")
    }
    try accept("disjoint selected spans aggregate copied and padded bytes separately") {
        var selected = Data(), total = CheckpointAlignedReadAccounting()
        for span in [19..<117, (a + 3)..<(a + 91), (2 * a + 8)..<(2 * a + 31)] {
            let (actual, stats) = try read(span.lowerBound, span.count)
            try require(actual == bytes.subdata(in: span), "selected span differs")
            selected.append(actual); try total.merge(stats)
        }
        try require(total.selectedBytes == selected.count && total.preadCalls == 3
            && total.returnedReadBytes == total.selectedBytes + total.paddingReadBytes,
            "span merge changed selected count")
    }
    try accept("zero length at EOF preserves the old empty path") {
        try require(try file.data(offset: bytes.count, count: 0).isEmpty, "empty read refused")
    }
    try accept("EINTR retries the same aligned window and records requested bytes") {
        var output = Data(count: 97), calls = 0, first: (UInt, Int, off_t)?
        let stats = try output.withUnsafeMutableBytes { destination in
            try CheckpointAlignedReader.read(descriptor: file.descriptor, fileSize: file.size,
                into: destination, offset: 23, checkUnchanged: file.checkUnchanged, readCall: { fd, pointer, count, offset in
                    let identity = (UInt(bitPattern: pointer), count, offset)
                    calls += 1
                    if calls == 1 { first = identity; errno = EINTR; return -1 }
                    guard let first, first.0 == identity.0, first.1 == count, first.2 == offset,
                        identity.0 % UInt(a) == 0, count % a == 0, offset % off_t(a) == 0 else { return 0 }
                    return Darwin.pread(fd, pointer, count, offset)
                })
        }
        try require(output == bytes.subdata(in: 23..<120) && stats.interruptedCalls == 1
            && stats.preadCalls == 2 && stats.requestedReadBytes == 2 * a
            && stats.returnedReadBytes == a, "interrupted accounting or retry alignment differs")
    }
    try accept("rehash preserves original digest and later aligned policy") {
        try require(try file.digest() == SHA256.hash(data: bytes), "rehash differs")
        let (_, stats) = try read(37, 89)
        try require(stats.selectedBytes == 89 && stats.preadCalls == 1, "rehash polluted per-read counters")
    }
    try reject("selected interval beyond EOF") { _ = try read(bytes.count - 1, 2) }
    try reject("negative selected offset") { _ = try read(-1, 2) }
    try reject("negative plan length") { _ = try CheckpointAlignedReadPlan(fileSize: 10, offset: 0, count: -1) }
    try reject("zero plan length is not an IO window") { _ = try CheckpointAlignedReadPlan(fileSize: 10, offset: 0, count: 0) }
    try reject("rounded end overflow before allocation") {
        _ = try CheckpointAlignedReadPlan(fileSize: Int.max, offset: Int.max - 1, count: 1)
    }
    for (name, result, errorNumber) in [("unexpected positive short", 128, 0), ("zero return before EOF", 0, 0),
                                        ("non-EINTR syscall failure", -1, EIO)] {
        try reject(name) {
            var output = Data(count: 37)
            _ = try output.withUnsafeMutableBytes { destination in
                try CheckpointAlignedReader.read(descriptor: file.descriptor, fileSize: file.size,
                    into: destination, offset: 0, checkUnchanged: file.checkUnchanged, readCall: { _, _, _, _ in
                        errno = errorNumber; return result
                    })
            }
        }
    }
    try reject("counter overflow refuses an otherwise valid merge") {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CheckpointAlignedReadAccounting())) as! [String: Any]
        object["selectedBytes"] = Int.max
        var total = try JSONDecoder().decode(CheckpointAlignedReadAccounting.self,
            from: JSONSerialization.data(withJSONObject: object))
        let (_, stats) = try read(0, 1)
        try total.merge(stats)
    }
    try reject("in-place mutation during pread") {
        var output = Data(count: 97)
        _ = try output.withUnsafeMutableBytes { destination in
            try CheckpointAlignedReader.read(descriptor: file.descriptor, fileSize: file.size,
                into: destination, offset: 0, checkUnchanged: file.checkUnchanged, readCall: { fd, pointer, count, offset in
                    let result = Darwin.pread(fd, pointer, count, offset)
                    let writer = open(url.path, O_WRONLY)
                    if writer >= 0 {
                        var value: UInt8 = 255
                        _ = Darwin.pwrite(writer, &value, 1, 0); close(writer)
                    }
                    return result
                })
        }
    }
    return .init(accepted: accepted, rejected: rejected)
}
