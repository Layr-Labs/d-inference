import Crypto
import Dispatch
import Foundation
import XCTest
@testable import ProviderCoreFoundation

final class WeightHasherConcurrencyTests: XCTestCase {
    func testWorkerSelectionDefaultsOnAndRetainsBoundedOverrides() {
        XCTAssertEqual(WeightHasher.resolvedHashWorkers(environment: [:]), 4)
        for value in ["", "0", "-1", "3", "5", "999", "true", "invalid"] {
            XCTAssertEqual(WeightHasher.resolvedHashWorkers(environment:
                ["DARKBLOOM_EXPERIMENT_HASH_WORKERS": value]), 1)
        }
        for value in [1, 2, 4] {
            XCTAssertEqual(WeightHasher.resolvedHashWorkers(environment:
                ["DARKBLOOM_EXPERIMENT_HASH_WORKERS": String(value)]), value)
        }
    }

    func testSortedRawDigestContractAndBoundaryFiles() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var files: [(file: URL, sortKey: String)] = []
        var expectedParts: [(String, SHA256Digest)] = []
        for (index, size) in [0, 1, 65535, 65536, 65537, 131079, 1_048_577].enumerated() {
            let bytes = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ index) })
            let file = directory.appendingPathComponent("file-\(index)")
            try bytes.write(to: file)
            let key = "relative-\(9-index)"
            files.append((file, key)); expectedParts.append((key, SHA256.hash(data: bytes)))
        }
        var expected = SHA256()
        for (_, digest) in expectedParts.sorted(by: { $0.0 < $1.0 }) {
            digest.withUnsafeBytes { expected.update(bufferPointer: $0) }
        }
        let hex = expected.finalize().map { String(format: "%02x", $0) }.joined()
        for workers in [1, 2, 4] {
            XCTAssertEqual(WeightHasher.hashFilesWithRelativeKey(files, workers: workers), hex)
            XCTAssertEqual(WeightHasher.hashFilesWithRelativeKey(Array(files.reversed()), workers: workers), hex)
        }
    }

    func testEmptyAggregateAndFailuresNeverProducePartialSuccess() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("valid")
        try Data("verified bytes".utf8).write(to: file)
        let missing = directory.appendingPathComponent("missing")
        let empty = SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()
        for workers in [1, 2, 4] {
            XCTAssertEqual(WeightHasher.hashFilesWithRelativeKey([], workers: workers), empty)
            for failing in [missing, directory] {
                XCTAssertNil(WeightHasher.hashFilesWithRelativeKey(
                    [(file, "b"), (failing, "a")], workers: workers))
                XCTAssertNil(WeightHasher.hashFilesWithRelativeKey(
                    [(file, "a"), (failing, "b")], workers: workers))
            }
        }
    }

    func testConcurrentInvocationsDoNotMixResults() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("payload")
        try Data(repeating: 0x73, count: 131077).write(to: file)
        let expected = try XCTUnwrap(WeightHasher.hashFilesWithRelativeKey([(file, "a"), (file, "b")], workers: 1))
        let failures = LockedFailures()
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            let result = WeightHasher.hashFilesWithRelativeKey([(file, "a"), (file, "b")], workers: 4)
            if result != expected { failures.increment() }
        }
        XCTAssertEqual(failures.count, 0)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hash-concurrency-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class LockedFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); defer { lock.unlock() }; value += 1 }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
