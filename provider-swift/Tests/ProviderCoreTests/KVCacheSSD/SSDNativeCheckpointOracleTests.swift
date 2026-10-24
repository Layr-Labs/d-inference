import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing
@testable import ProviderCore

/// Host byte copies cannot alias native buffers or keep native permits alive.
enum NativeCheckpointOracle {
    static func coldBitsOnNewCPUThread(_ fixture: NativeDiffusionCheckpointFixture) async throws -> [Data] {
        var worker: Thread?
        let result: Result<[Data], any Error> = await withCheckedContinuation { continuation in
            let thread = Thread {
                let result = Result {
                    try Device.withDefaultDevice(.cpu) {
                        bits(try fixture.coldCache(prefixCount: 256))
                    }
                }
                continuation.resume(returning: result)
            }
            worker = thread
            thread.start()
        }
        // The isolated-process watchdog bounds native work. Join the actual
        // thread even on an error; a cancelled task is not a retirement receipt.
        let thread = try #require(worker)
        while !thread.isFinished { await Task.yield() }
        return try result.get()
    }

    static func bits(_ cache: DiffusionGemmaRequestCache) -> [Data] {
        cache.snapshots().flatMap { [bits($0.keys), bits($0.values)] }
    }

    static func bits(_ array: MLXArray) -> Data {
        let values = array.asArray(Float.self).map(\.bitPattern)
        return values.withUnsafeBytes { Data($0) }
    }

    static func differences(_ lhs: [Data], _ rhs: [Data]) -> [Int] {
        (0..<max(lhs.count, rhs.count)).filter {
            !lhs.indices.contains($0) || !rhs.indices.contains($0) || lhs[$0] != rhs[$0]
        }
    }

    static func authenticatedBits(_ fixture: NativeDiffusionCheckpointFixture,
                                  store: SSDHybridCheckpointStore, position: Int) throws -> [Data] {
        var envelope: SSDHybridCheckpointEnvelope?
        var tensors: [Data] = []
        try SSDBlockStore.readStreaming(from: fixture.file(store, position: position), kekKey: fixture.key,
            maximumChunkBytes: CBv2CompleteCheckpointManifest.maximumSegmentBytes,
            maximumPlaintextBytes: store.config.maxReadBytes, requireEOF: true,
            validateMetadata: { _ in }, consumeChunk: { index, data in
                if index == 0 {
                    let manifest = try SSDHybridCheckpointEnvelope.decodeManifest(data)
                    try #require(manifest.identity == fixture.identity && manifest.position == position)
                    try #require(manifest.prefixTokens == Array(fixture.tokens.prefix(position)))
                    try #require(manifest.tensors.allSatisfy { $0.dtype.mlxDType == .float32 })
                    envelope = try SSDHybridCheckpointEnvelope(manifest: manifest,
                        maximumPlaintextBytes: store.config.maxReadBytes)
                    tensors = Array(repeating: Data(), count: manifest.tensors.count)
                } else {
                    let segment = try #require(envelope).segments[index - 1]
                    try #require(data.count == segment.bytes && tensors[segment.tensor].count == segment.offset)
                    tensors[segment.tensor].append(data)
                }
            })
        try #require(envelope != nil && !tensors.isEmpty)
        return tensors
    }
}

// Run in a fresh CPU-only process, alongside the runner's other isolated
// suites. Swift task-local CPU selection does not change the C++ default
// stream used to key its per-thread compiled-function cache.
@Suite("Native checkpoint cold-computation oracle", .serialized)
struct SSDNativeCheckpointOracleTests {
    private func withFixture(
        seed: UInt64?, _ body: (NativeDiffusionCheckpointFixture) async throws -> Void
    ) async throws {
        try await Device.withDefaultDevice(.cpu) {
            let fixture: NativeDiffusionCheckpointFixture
            if let seed {
                fixture = try withRandomState(MLXRandom.RandomState(seed: seed)) {
                    try NativeDiffusionCheckpointFixture(rootParent: SSDTestDirectory.parent())
                }
            } else {
                fixture = try NativeDiffusionCheckpointFixture(rootParent: SSDTestDirectory.parent())
            }
            defer { fixture.remove() }
            do {
                let parameters = fixture.model.parameters().flattened().sorted { $0.0 < $1.0 }.map(\.1)
                let before = parameters.map(NativeCheckpointOracle.bits)
                try await body(fixture)
                #expect(NativeCheckpointOracle.differences(before, parameters.map(NativeCheckpointOracle.bits)).isEmpty)
                #expect(fixture.engine.capacity().kvBytesReserved == 0)
            } catch {
                await fixture.engine.shutdown()
                throw error
            }
            await fixture.engine.shutdown()
        }
    }

    @Test("first and warmed cold executions use the same frozen parameters without SSD",
          arguments: [nil, 0, 1, 7, 42] as [UInt64?])
    func repeatedColdState(_ seed: UInt64?) async throws {
        try await withFixture(seed: seed) { fixture in
            let first = NativeCheckpointOracle.bits(try fixture.coldCache(prefixCount: 256))
            let second = NativeCheckpointOracle.bits(try fixture.coldCache(prefixCount: 256))
            let third = NativeCheckpointOracle.bits(try fixture.coldCache(prefixCount: 256))
            #expect(NativeCheckpointOracle.differences(first, second).isEmpty,
                "independent cold executions must match before testing SSD")
            #expect(NativeCheckpointOracle.differences(second, third).isEmpty,
                "a warmed cold execution must not drift either")
        }
    }

    @Test("sequential cold execution across owned CPU threads preserves the same frozen parameters",
          arguments: [nil, 0, 1, 7, 42] as [UInt64?])
    func repeatedColdStateAcrossThreads(_ seed: UInt64?) async throws {
        try await withFixture(seed: seed) { fixture in
            let caller = NativeCheckpointOracle.bits(try fixture.coldCache(prefixCount: 256))
            let firstThread = try await NativeCheckpointOracle.coldBitsOnNewCPUThread(fixture)
            let secondThread = try await NativeCheckpointOracle.coldBitsOnNewCPUThread(fixture)
            let resumed = NativeCheckpointOracle.bits(try fixture.coldCache(prefixCount: 256))
            #expect(NativeCheckpointOracle.differences(caller, firstThread).isEmpty,
                "sequential CPU thread selection must not change a cold reference")
            #expect(NativeCheckpointOracle.differences(firstThread, secondThread).isEmpty)
            #expect(NativeCheckpointOracle.differences(caller, resumed).isEmpty)
        }
    }
}
