// Copyright © 2026 Eigen Labs.

import CryptoKit
import Darwin
import Foundation
import Testing

@testable import MLXLLM

extension UnitTests {
    @Suite(.serialized) struct GLM5NextAlignedPayloadReaderTests {
        private typealias Reader = GLM5NextAlignedPayloadReader
        private static let a = Reader.alignmentBytes

        // Unaligned file size so the last window always ends at EOF mid-page.
        private final class PatternFile {
            let url: URL
            let bytes: Data
            let fd: Int32
            init(size: Int) throws {
                url = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "glm5-aligned-read-\(UUID())")
                var value = Data(count: size)
                value.withUnsafeMutableBytes { raw in
                    for i in 0 ..< size { raw[i] = UInt8(truncatingIfNeeded: i &* 2_654_435_761 >> 7) }
                }
                bytes = value
                try value.write(to: url)
                fd = open(url.path, O_RDONLY | O_CLOEXEC)
                #expect(fd >= 0)
                #expect(fcntl(fd, F_NOCACHE, 1) == 0)
                #expect(fcntl(fd, F_RDAHEAD, 0) == 0)
            }
            deinit {
                close(fd)
                try? FileManager.default.removeItem(at: url)
            }
        }

        private struct Call: Equatable {
            let pointer: UInt
            let count: Int
            let offset: off_t
        }

        @Test func selectedBytesAreExactAcrossAlignmentWindowAndEOFBoundaries() throws {
            let size = 2 * Reader.maximumScratchRequestBytes + 3 * Self.a + 123
            let file = try PatternFile(size: size)
            let cases: [(Int, Int)] = [
                (0, 1), (0, size), (1, 1), (Self.a - 1, 2), (Self.a, Self.a), (77, Self.a * 3 + 5),
                (Reader.maximumScratchRequestBytes - 3, 7),
                (Reader.maximumScratchRequestBytes + 11, Reader.maximumScratchRequestBytes + 99),
                (size - 1, 1), (size - Self.a - 7, Self.a + 7), (size - 200_000, 200_000),
            ]
            for (offset, count) in cases {
                var calls: [Call] = []
                let data = try Reader.read(
                    descriptor: file.fd, fileSize: size, offset: offset, count: count,
                    checkUnchanged: {},
                    readCall: { fd, pointer, length, at in
                        calls.append(.init(pointer: UInt(bitPattern: pointer), count: length, offset: at))
                        return Darwin.pread(fd, pointer, length, at)
                    })
                #expect(data == file.bytes.subdata(in: offset ..< offset + count))
                // Every request is aligned in pointer, length and offset, never
                // exceeds the priced scratch, and windows are contiguous.
                #expect(calls.allSatisfy {
                    $0.pointer % UInt(Self.a) == 0 && $0.count % Self.a == 0
                        && Int($0.offset) % Self.a == 0
                        && $0.count <= Reader.maximumScratchRequestBytes
                })
                #expect(Int(calls.first!.offset) == offset - offset % Self.a)
                for (lhs, rhs) in zip(calls, calls.dropFirst()) {
                    #expect(Int(rhs.offset) == Int(lhs.offset) + lhs.count)
                }
            }
        }

        @Test func interruptedReadRetriesTheSameAlignedRequest() throws {
            let file = try PatternFile(size: 3 * Self.a + 10)
            var calls: [Call] = []
            var interrupted = false
            let data = try Reader.read(
                descriptor: file.fd, fileSize: 3 * Self.a + 10, offset: 5, count: 2 * Self.a,
                checkUnchanged: {},
                readCall: { fd, pointer, length, at in
                    calls.append(.init(pointer: UInt(bitPattern: pointer), count: length, offset: at))
                    if !interrupted {
                        interrupted = true
                        errno = EINTR
                        return -1
                    }
                    return Darwin.pread(fd, pointer, length, at)
                })
            #expect(data == file.bytes.subdata(in: 5 ..< 5 + 2 * Self.a))
            #expect(calls.count == 2 && calls[0] == calls[1])
        }

        @Test func shortErrorAndZeroReadsFailClosed() throws {
            let size = 4 * Self.a
            let file = try PatternFile(size: size)
            let failures: [(Int32, UnsafeMutableRawPointer, Int, off_t) -> Int] = [
                { _, _, length, _ in length - 1 },  // short before EOF
                { _, _, _, _ in 0 },  // unexpected EOF
                { _, _, _, _ in errno = EIO; return -1 },
                { _, _, length, _ in length + 1 },  // more than requested
            ]
            for failure in failures {
                #expect(throws: GLM5NextArtifactError.invalid("truncated read")) {
                    _ = try Reader.read(
                        descriptor: file.fd, fileSize: size, offset: 3, count: Self.a,
                        checkUnchanged: {}, readCall: failure)
                }
            }
        }

        @Test func mutationCheckRunsAroundEveryReadAndStopsTheLoad() throws {
            let size = 3 * Reader.maximumScratchRequestBytes
            let file = try PatternFile(size: size)
            var checks = 0, reads = 0
            _ = try Reader.read(
                descriptor: file.fd, fileSize: size, offset: 0, count: size,
                checkUnchanged: { checks += 1 },
                readCall: { reads += 1; return Darwin.pread($0, $1, $2, $3) })
            #expect(reads == 3 && checks == 1 + 2 * reads)

            struct Changed: Error {}
            reads = 0
            var allowed = 2
            #expect(throws: Changed.self) {
                _ = try Reader.read(
                    descriptor: file.fd, fileSize: size, offset: 0, count: size,
                    checkUnchanged: {
                        if allowed == 0 { throw Changed() }
                        allowed -= 1
                    },
                    readCall: { reads += 1; return Darwin.pread($0, $1, $2, $3) })
            }
            #expect(reads == 1)  // a change observed after a read stops further reads
        }

        @Test func outOfRangeRequestsAreRejectedBeforeAnyRead() throws {
            let file = try PatternFile(size: Self.a + 1)
            for (descriptor, offset, count) in [
                (file.fd, 0, 0), (file.fd, -1, 1), (file.fd, 0, Self.a + 2), (file.fd, Self.a + 1, 1),
                (Int32(-1), 0, 1),
            ] {
                var reads = 0
                #expect(throws: GLM5NextArtifactError.self) {
                    _ = try Reader.read(
                        descriptor: descriptor, fileSize: Self.a + 1, offset: offset, count: count,
                        checkUnchanged: {}, readCall: { reads += 1; return Darwin.pread($0, $1, $2, $3) })
                }
                #expect(reads == 0)
            }
        }

        @Test func scratchIsReleasedOnSuccessAndFailure() throws {
            // Each call maps a full 8 MiB extent; leaking it would grow the
            // footprint by far more than the tolerance below.
            let size = 2 * Reader.maximumScratchRequestBytes
            let file = try PatternFile(size: size)
            func footprint() -> Int {
                var info = task_vm_info_data_t()
                var count = mach_msg_type_number_t(
                    MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
                let status = withUnsafeMutablePointer(to: &info) {
                    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                    }
                }
                #expect(status == KERN_SUCCESS)
                return Int(info.phys_footprint)
            }
            _ = try Reader.read(
                descriptor: file.fd, fileSize: size, offset: 0, count: 1, checkUnchanged: {})
            let before = footprint()
            for i in 0 ..< 64 {
                if i % 2 == 0 {
                    _ = try Reader.read(
                        descriptor: file.fd, fileSize: size, offset: 1, count: size - 1,
                        checkUnchanged: {})
                } else {
                    _ = try? Reader.read(
                        descriptor: file.fd, fileSize: size, offset: 1, count: size - 1,
                        checkUnchanged: {},
                        readCall: { fd, pointer, length, at in
                            // Touch the whole scratch so a leak is resident, then fail.
                            _ = Darwin.pread(fd, pointer, length, at)
                            return 0
                        })
                }
            }
            #expect(footprint() - before < 4 * Reader.maximumScratchRequestBytes)
        }

        // Many shards are verified concurrently; the corrupted one is still the
        // reported failure and no valid set is rejected by the parallel path.
        @Test func concurrentVerificationReportsTheCorruptShard() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "glm5-parallel-verify-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: root) }
            var files: [String: GLM5NextArtifactIdentity.File] = [:]
            func add(_ name: String, _ data: Data) throws {
                try data.write(to: root.appendingPathComponent(name))
                files[name] = .init(
                    bytes: data.count,
                    sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
            }
            try add("config.json", Data("{}".utf8))
            try add("model.safetensors.index.json", Data("{}".utf8))
            for i in 0 ..< 24 {
                // Sizes straddle the 8 MiB chunk so multi-chunk files are covered.
                try add("w-\(i).safetensors", Data(repeating: UInt8(i), count: (i % 3) * 5_000_000 + 1234))
            }
            let identity = GLM5NextArtifactIdentity(
                repository: "synthetic/glm5-parallel", revision: String(repeating: "a", count: 40),
                files: files)
            // Valid set: verification passes and the loader fails later on metadata.
            do {
                _ = try GLM5NextArtifactLoader(directory: root, expectedIdentity: identity, storage: .float32)
                Issue.record("synthetic metadata unexpectedly loaded")
            } catch let error as GLM5NextArtifactError {
                if case .invalid(let reason) = error { #expect(!reason.hasPrefix("SHA-256")) }
            } catch {}
            // Same size, one flipped byte in a middle shard.
            let bad = root.appendingPathComponent("w-13.safetensors")
            var data = try Data(contentsOf: bad)
            data[data.count / 2] ^= 1
            try data.write(to: bad)
            #expect(throws: GLM5NextArtifactError.invalid("SHA-256 w-13.safetensors")) {
                _ = try GLM5NextArtifactLoader(directory: root, expectedIdentity: identity, storage: .float32)
            }
        }

        @Test func scratchAllowanceIsExposedForResourceQuotes() {
            #expect(
                GLM5NextArtifactLoader.payloadReadScratchAllowanceBytes
                    == Reader.maximumScratchRequestBytes + Reader.alignmentBytes)
            #expect(Reader.alignmentBytes % Int(getpagesize()) == 0)
            #expect(GLM5NextArtifactLoader.verificationHostBytes >= 8 * 1024 * 1024)
            #expect(GLM5NextArtifactLoader.verificationHostBytes <= 64 * 1024 * 1024)
        }
    }
}
