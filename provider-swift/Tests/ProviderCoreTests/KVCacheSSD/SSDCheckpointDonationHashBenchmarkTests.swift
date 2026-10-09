import Foundation
import Testing
@testable import ProviderCore

/// Opt-in CPU bookkeeping measurement; constructs no model, native arrays or
/// read/write job. Source/compiler/image qualification comes from the caller's
/// immutable external receipt, not from a guessed running-image location.
@Suite("Checkpoint donation hash preparation benchmark", .serialized)
struct SSDCheckpointDonationHashBenchmarkTests {
    private enum Arm: String, Codable, Hashable { case legacy, bounded }
    private enum Failure: Error { case invalidReceipt, invalidOutput, parity, calibration, checksum }
    private struct BuildIdentity: Codable {
        let compilerVersion: String
        let binarySHA256: String
        let sourceRevision: String
        let sourceSnapshotSHA256: String
    }
    private struct Workload {
        let name: String
        let tokens: [Int]
        let positions: [Int]
        let expectedLegacyBlocks: Int
        let expectedBoundedBlocks: Int
    }
    private struct Proof: Codable {
        let checkpointPositions: [Int]
        let legacyChainCounts: [Int]
        let boundedChainCounts: [Int]
        let legacySHABlocksPerIteration: Int
        let boundedSHABlocksPerIteration: Int
        let exactChainEndpointsAndTagsMatch: Bool
        let checksumPerIteration: UInt64
    }
    private struct Sample: Codable {
        let iterations: Int
        let seconds: Double
        let nanosecondsPerIteration: Double
        let consumedChecksum: UInt64
    }
    private struct Pair: Codable {
        let index: Int
        let firstArm: Arm
        let legacy: Sample
        let bounded: Sample
        let boundedTimeReductionPercent: Double
    }
    private struct Cell: Codable {
        let name: String
        let donorTokens: Int
        let proof: Proof
        let legacyCalibration: Sample
        let boundedCalibration: Sample
        let pairs: [Pair]
        let medianPairedTimeReductionPercent: Double
    }
    private struct Report: Codable {
        let schemaVersion: Int
        let startedUTC: String
        let endedUTC: String
        let identity: BuildIdentity
        let pairsPerCell: Int
        let equalWarmupIterationsPerArm: Int
        let calibrationTargetSeconds: Double
        let cells: [Cell]
        let scope: String
        let limitations: [String]
    }

    private static let scope = "synthetic-donation-hash-benchmark"
    private static let warmupIterations = 20
    private static let pairCount = 12
    private static let calibrationTarget = 0.15

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_DONATION_HASH_BENCHMARK"] == "1"))
    func realDonationHashPreparation() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let output = environment["DARKBLOOM_DONATION_HASH_BENCHMARK_OUTPUT"], output.hasPrefix("/"),
              !FileManager.default.fileExists(atPath: output),
              let receipt = environment["DARKBLOOM_DONATION_HASH_BENCHMARK_IDENTITY"], receipt.hasPrefix("/")
        else { throw Failure.invalidOutput }
        let identity = try JSONDecoder().decode(BuildIdentity.self, from: Data(contentsOf: URL(fileURLWithPath: receipt)))
        guard !identity.compilerVersion.isEmpty, identity.compilerVersion.utf8.count <= 512,
              Self.isHex(identity.binarySHA256, count: 64),
              Self.isHex(identity.sourceSnapshotSHA256, count: 64),
              Self.isHex(identity.sourceRevision, count: 40)
        else { throw Failure.invalidReceipt }

        let fixture = try SSDCheckpointDonationHashFixture()
        defer { fixture.remove() }
        let workloads = [
            Workload(name: "short-three-frontiers", tokens: SSDCheckpointDonationHashFixture.tokens(7_169),
                     positions: [1_024, 6_144, 7_168], expectedLegacyBlocks: 84, expectedBoundedBlocks: 56),
            Workload(name: "long-three-frontiers", tokens: SSDCheckpointDonationHashFixture.tokens(16_513),
                     positions: [4_096, 12_288, 16_384], expectedLegacyBlocks: 192, expectedBoundedBlocks: 128),
            Workload(name: "deepest-only-control", tokens: SSDCheckpointDonationHashFixture.tokens(16_513),
                     positions: [16_384], expectedLegacyBlocks: 64, expectedBoundedBlocks: 64),
        ]
        // Arrays, empty-store preparation and strict byte/address proofs are
        // outside every timed operation, including the calibration batches.
        let proofs = try workloads.map { try Self.prove($0, store: fixture.store) }
        let started = Date().ISO8601Format()
        var cells: [Cell] = []
        for (workload, proof) in zip(workloads, proofs) {
            for arm in [Arm.legacy, .bounded] {
                try Self.verify(Self.measure(workload, store: fixture.store, arm: arm,
                                             iterations: Self.warmupIterations), proof: proof)
            }
            let legacyCalibration = try Self.calibrate(workload, store: fixture.store, arm: .legacy, proof: proof)
            let boundedCalibration = try Self.calibrate(workload, store: fixture.store, arm: .bounded, proof: proof)
            // Reset with the same seed work after per-arm calibration; paired
            // batches use fixed independently calibrated iteration counts.
            for arm in [Arm.legacy, .bounded] {
                try Self.verify(Self.measure(workload, store: fixture.store, arm: arm,
                                             iterations: Self.warmupIterations), proof: proof)
            }
            var pairs: [Pair] = []
            for index in 0..<Self.pairCount {
                let first: Arm = index.isMultiple(of: 2) ? .legacy : .bounded
                let order: [Arm] = first == .legacy ? [.legacy, .bounded] : [.bounded, .legacy]
                var samples: [Arm: Sample] = [:]
                for arm in order {
                    let iterations = arm == .legacy ? legacyCalibration.iterations : boundedCalibration.iterations
                    let sample = Self.measure(workload, store: fixture.store, arm: arm, iterations: iterations)
                    try Self.verify(sample, proof: proof)
                    samples[arm] = sample
                }
                let legacy = samples[.legacy]!, bounded = samples[.bounded]!
                pairs.append(Pair(index: index, firstArm: first, legacy: legacy, bounded: bounded,
                                  boundedTimeReductionPercent: (1 - bounded.nanosecondsPerIteration
                                                               / legacy.nanosecondsPerIteration) * 100))
            }
            cells.append(Cell(name: workload.name, donorTokens: workload.tokens.count, proof: proof,
                              legacyCalibration: legacyCalibration, boundedCalibration: boundedCalibration,
                              pairs: pairs, medianPairedTimeReductionPercent:
                                Self.median(pairs.map(\.boundedTimeReductionPercent))))
        }
        let report = Report(schemaVersion: 1, startedUTC: started, endedUTC: Date().ISO8601Format(),
                            identity: identity, pairsPerCell: Self.pairCount,
                            equalWarmupIterationsPerArm: Self.warmupIterations * 2,
                            calibrationTargetSeconds: Self.calibrationTarget, cells: cells,
                            scope: "Actual CPU hash chain, checkpoint endpoint selection and HMAC tag; synthetic donor inputs.",
                            limitations: ["Not complete prepareWriteJob, model TTFT, GPU generation TPS, RSS or measured total allocations.",
                                          "Digest-output bytes and actual produced chain counts do not measure allocator or physical memory use.",
                                          "No write job, encrypted file, cache-hit or fsync qualification is performed here.",
                                          "Checksum consumes timed work; exact full endpoint/tag equality is proved separately before timing.",
                                          "External build identity is caller-supplied and must be checked against its source/image/toolchain receipt."])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: URL(fileURLWithPath: output), options: .atomic)
    }

    private static func prove(_ workload: Workload, store: SSDHybridCheckpointStore) throws -> Proof {
        var legacyCounts: [Int] = [], boundedCounts: [Int] = []
        var checksum: UInt64 = 0
        for position in workload.positions {
            let legacy = store.hashes(tokens: workload.tokens, scope: scope)
            guard let bounded = store.donationHashes(tokens: workload.tokens, scope: scope, checkpointPosition: position)
            else { throw Failure.parity }
            let index = position / PrefixCachePolicy.blockSize - 1
            guard legacy.indices.contains(index), bounded.indices.contains(index),
                  bounded.count == position / PrefixCachePolicy.blockSize, legacy[index] == bounded[index]
            else { throw Failure.parity }
            let legacyTag = store.lookupKeys.checkpointTag(chainHash: legacy[index], cacheSalt: scope)
            let boundedTag = store.lookupKeys.checkpointTag(chainHash: bounded[index], cacheSalt: scope)
            guard legacyTag == boundedTag, legacyTag.count == 32 else { throw Failure.parity }
            checksum &+= Self.consume(legacyTag, position: position)
            legacyCounts.append(legacy.count); boundedCounts.append(bounded.count)
        }
        let legacyTotal = legacyCounts.reduce(0, +), boundedTotal = boundedCounts.reduce(0, +)
        guard legacyTotal == workload.expectedLegacyBlocks, boundedTotal == workload.expectedBoundedBlocks
        else { throw Failure.parity }
        return Proof(checkpointPositions: workload.positions, legacyChainCounts: legacyCounts,
                     boundedChainCounts: boundedCounts, legacySHABlocksPerIteration: legacyTotal,
                     boundedSHABlocksPerIteration: boundedTotal, exactChainEndpointsAndTagsMatch: true,
                     checksumPerIteration: checksum)
    }

    private static func measure(_ workload: Workload, store: SSDHybridCheckpointStore,
                                arm: Arm, iterations: Int) -> Sample {
        let clock = ContinuousClock(), started = clock.now
        var checksum: UInt64 = 0
        for _ in 0..<iterations {
            for position in workload.positions {
                let chain = arm == .legacy
                    ? store.hashes(tokens: workload.tokens, scope: scope)
                    : store.donationHashes(tokens: workload.tokens, scope: scope, checkpointPosition: position)!
                let digest = chain[position / PrefixCachePolicy.blockSize - 1]
                let tag = store.lookupKeys.checkpointTag(chainHash: digest, cacheSalt: scope)
                checksum &+= consume(tag, position: position)
            }
        }
        let duration = (clock.now - started).components
        let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        return Sample(iterations: iterations, seconds: seconds,
                      nanosecondsPerIteration: seconds * 1e9 / Double(iterations), consumedChecksum: checksum)
    }

    private static func calibrate(_ workload: Workload, store: SSDHybridCheckpointStore,
                                  arm: Arm, proof: Proof) throws -> Sample {
        let maximumIterations = 1_048_576
        var iterations = 1
        while true {
            let sample = measure(workload, store: store, arm: arm, iterations: iterations)
            try verify(sample, proof: proof)
            if sample.seconds >= 0.1 {
                let target = Int(min(Double(maximumIterations), max(1,
                    Double(iterations) * calibrationTarget / sample.seconds)))
                let calibrated = measure(workload, store: store, arm: arm, iterations: target)
                try verify(calibrated, proof: proof)
                return calibrated
            }
            guard iterations < maximumIterations else { throw Failure.calibration }
            iterations *= 2
        }
    }

    private static func verify(_ sample: Sample, proof: Proof) throws {
        guard sample.seconds.isFinite, sample.seconds > 0,
              sample.consumedChecksum == proof.checksumPerIteration &* UInt64(sample.iterations)
        else { throw Failure.checksum }
    }

    private static func consume(_ tag: Data, position: Int) -> UInt64 {
        UInt64(tag[tag.startIndex]) &+ UInt64(tag[tag.index(before: tag.endIndex)]) &+ UInt64(position)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted(), middle = sorted.count / 2
        return (sorted[middle - 1] + sorted[middle]) / 2
    }

    private static func isHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
