// Copyright © 2026 Eigen Labs.

import CryptoKit
import Darwin
import Foundation
import Testing

@testable import MLXLLM

extension UnitTests {
    @Suite(.serialized) struct GLM5NextArtifactCachePolicyTests {
        // Holds real dup() witnesses of each open file description. Their offsets
        // distinguish a rejected pre-read open from a descriptor that hashed bytes.
        private final class Probe {
            struct Request {
                let command: Int32
                let argument: Int32
                let offset: off_t
                let result: Int32
            }
            final class Open {
                let witness: Int32
                var requests: [Request] = []
                init(_ fd: Int32) {
                    witness = Darwin.dup(fd)
                    #expect(witness >= 0)
                }
            }
            let failingCommand: Int32?
            var opens: [Open] = []
            init(failingCommand: Int32? = nil) { self.failingCommand = failingCommand }
            deinit { closeWitnesses() }

            // Verification opens files from concurrent workers. Each open's
            // F_NOCACHE/F_RDAHEAD pair is recorded against its own descriptor.
            private let lock = NSLock()
            func control(_ fd: Int32, _ command: Int32, _ argument: Int32) -> Int32 {
                lock.lock()
                defer { lock.unlock() }
                if command == F_NOCACHE { opens.append(Open(fd)) }
                guard let current = opens.last(where: { Self.sameFile($0.witness, fd) }) else {
                    Issue.record("read-ahead requested before cache bypass")
                    errno = EINVAL
                    return -1
                }
                let offset = lseek(fd, 0, SEEK_CUR)
                let result: Int32
                if command == failingCommand {
                    errno = EIO
                    result = -1
                } else {
                    // Success is never fabricated, including before F_RDAHEAD failure.
                    result = Darwin.fcntl(fd, command, argument)
                }
                current.requests.append(
                    .init(command: command, argument: argument, offset: offset, result: result))
                return result
            }

            private static func sameFile(_ witness: Int32, _ fd: Int32) -> Bool {
                var a = stat(), b = stat()
                return fstat(witness, &a) == 0 && fstat(fd, &b) == 0
                    && a.st_dev == b.st_dev && a.st_ino == b.st_ino
                    && lseek(witness, 0, SEEK_CUR) == lseek(fd, 0, SEEK_CUR)
            }

            func closeWitnesses() {
                for opened in opens where opened.witness >= 0 { Darwin.close(opened.witness) }
                opens.removeAll()
            }
        }

        // Deliberately invalid model metadata: the test must reach the real shard
        // hash rejection before parsing it. No model, MLX array or GPU is created.
        private final class CorruptArtifact {
            let directory: URL
            let identity: GLM5NextArtifactIdentity
            let payloadBytes: Int
            init() throws {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "glm5-cache-policy-\(UUID())")
                try FileManager.default.createDirectory(
                    at: root, withIntermediateDirectories: false)
                var complete = false
                defer { if !complete { try? FileManager.default.removeItem(at: root) } }
                let original = Data("real shard bytes".utf8)
                let bytes = [
                    "config.json": Data("{}".utf8),
                    "model.safetensors.index.json": Data("{}".utf8),
                    "weights.safetensors": original,
                ]
                var files: [String: GLM5NextArtifactIdentity.File] = [:]
                for (name, data) in bytes {
                    try data.write(to: root.appendingPathComponent(name))
                    files[name] = .init(
                        bytes: data.count,
                        sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
                }
                let expected = GLM5NextArtifactIdentity(
                    repository: "synthetic/glm5-cache-policy",
                    revision: String(repeating: "a", count: 40), files: files)
                var corrupted = original
                corrupted[0] ^= 1
                try corrupted.write(to: root.appendingPathComponent("weights.safetensors"))
                directory = root
                identity = expected
                payloadBytes = original.count
                complete = true
            }
            deinit { try? FileManager.default.removeItem(at: directory) }
        }

        // Check only this unique fixture's descriptors, so parallel suites opening
        // unrelated files cannot turn cleanup checks into process-wide count races.
        private func openFiles(in directory: URL) throws -> [Int32] {
            struct Identity: Hashable {
                let device: dev_t
                let inode: ino_t
                init(_ value: stat) {
                    device = value.st_dev
                    inode = value.st_ino
                }
            }
            let files = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
            let identities = try Set(
                ([directory] + files).map { url in
                    var value = stat()
                    try #require(Darwin.lstat(url.path, &value) == 0)
                    return Identity(value)
                })
            var found: [Int32] = []
            for entry in try FileManager.default.contentsOfDirectory(atPath: "/dev/fd") {
                guard let fd = Int32(entry) else { continue }
                var value = stat()
                if fstat(fd, &value) == 0, identities.contains(Identity(value)) {
                    found.append(fd)
                }
            }
            return found
        }

        @Test func hintsPrecedeRealHashAndCorruptPayloadStillFails() throws {
            let fixture = try CorruptArtifact()
            let probe = Probe()
            #expect(throws: GLM5NextArtifactError.invalid("SHA-256 weights.safetensors")) {
                _ = try GLM5NextArtifactLoader(
                    directory: fixture.directory, expectedIdentity: fixture.identity,
                    storage: .float32, descriptorControl: probe.control)
            }
            // Both the stat preflight and the reopened hash descriptor need policy.
            #expect(probe.opens.count >= 2)
            for opened in probe.opens {
                #expect(opened.requests.map(\.command) == [F_NOCACHE, F_RDAHEAD])
                #expect(opened.requests.map(\.argument) == [1, 0])
                #expect(opened.requests.allSatisfy { $0.offset == 0 && $0.result == 0 })
            }
            #expect(
                probe.opens.contains {
                    lseek($0.witness, 0, SEEK_CUR) == off_t(fixture.payloadBytes)
                })
            #expect(try !openFiles(in: fixture.directory).isEmpty)
            probe.closeWitnesses()
            #expect(try openFiles(in: fixture.directory).isEmpty)
        }

        @Test(arguments: [F_NOCACHE, F_RDAHEAD])
        func rejectedHintClosesDescriptorsBeforeAnyRead(_ command: Int32) throws {
            let fixture = try CorruptArtifact()
            let probe = Probe(failingCommand: command)
            let reason = command == F_NOCACHE ? "cache bypass" : "read-ahead"
            #expect(throws: GLM5NextArtifactError.invalid("\(reason) weights.safetensors")) {
                _ = try GLM5NextArtifactLoader(
                    directory: fixture.directory, expectedIdentity: fixture.identity,
                    storage: .float32, descriptorControl: probe.control)
            }
            let opened = try #require(probe.opens.first)
            #expect(probe.opens.count == 1)
            #expect(
                opened.requests.map(\.command)
                    == (command == F_NOCACHE
                        ? [F_NOCACHE] : [F_NOCACHE, F_RDAHEAD]))
            #expect(opened.requests.last?.result == -1)
            #expect(opened.requests.allSatisfy { $0.offset == 0 })
            // dup shares the original's offset: no read syscall is mocked.
            #expect(lseek(opened.witness, 0, SEEK_CUR) == 0)
            #expect(try !openFiles(in: fixture.directory).isEmpty)
            probe.closeWitnesses()
            // Includes the original shard AND root directory FD, excluding only
            // the witnesses just closed by the test.
            #expect(try openFiles(in: fixture.directory).isEmpty)
        }

        @Test func completeLoaderAndRevalidationUseRealDescriptorPolicy() throws {
            // This existing fixture writes tiny deterministic Data, never MLX arrays.
            let fixture = try GLM5NextLocalArtifactFixture()
            let probe = Probe()
            do {
                let loader = try GLM5NextArtifactLoader(
                    directory: fixture.directory, expectedIdentity: fixture.identity(),
                    storage: fixture.storage, descriptorControl: probe.control)
                let ordinary = try fixture.loader()
                #expect(loader.inventory.entries.count == fixture.tensors.count)
                #expect(loader.unresolved(in: .mtp).count == ordinary.unresolved(in: .mtp).count)
                #expect(
                    loader.resources.conservativeLoadPeakBytes
                        == ordinary.resources.conservativeLoadPeakBytes)
                try loader.verifyUnchanged()
            }
            #expect(probe.opens.count > fixture.shards.count)
            #expect(
                probe.opens.allSatisfy {
                    $0.requests.map(\.command) == [F_NOCACHE, F_RDAHEAD]
                        && $0.requests.allSatisfy { $0.offset == 0 && $0.result == 0 }
                })
            #expect(try !openFiles(in: fixture.directory).isEmpty)
            probe.closeWitnesses()
            #expect(try openFiles(in: fixture.directory).isEmpty)
        }
    }
}
