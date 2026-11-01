import Foundation
import MLXLLM
import Testing
@testable import DarkbloomClusterRuntime

/// The model-free parts of GLM tensor-parallel speculative decode: reading a
/// round's agreement and the request charge. The round itself needs the model
/// and a pair (`darkbloom-cluster-tp-check glm --mtp-depth`).
@Suite("GLM tensor-parallel speculative decode")
struct GLM5NextTensorParallelSpeculationTests {
    typealias Speculation = GLM5NextTensorParallelSpeculation

    /// One rank's slot: the target's token at each window position, the proposals, the stop flag.
    static func slot(_ targets: [Int], _ drafts: [Int], stop: Float = 0) -> [Float] {
        targets.map(Float.init) + drafts.map(Float.init) + [stop]
    }

    @Test func keepsTheAcceptedPrefixAndTheTargetAfterIt() throws {
        let targets = [11, 12, 13, 14]
        #expect(try Speculation.decide(Self.slot(targets, [11, 12, 13]), ranks: 1, window: 3).tokens == [11, 12, 13, 14])
        #expect(try Speculation.decide(Self.slot(targets, [11, 99, 13]), ranks: 1, window: 3).tokens == [11, 12])
        // A later match after a miss is not accepted.
        #expect(try Speculation.decide(Self.slot(targets, [98, 12, 13]), ranks: 1, window: 3).tokens == [11])
        // No proposal: a plain step's token.
        #expect(try Speculation.decide(Self.slot([11], []), ranks: 1, window: 0).tokens == [11])
    }

    @Test func ranksMustAgreeOnTokensAndProposalsButNotOnStops() throws {
        let zero = Self.slot([11, 12, 13], [11, 12]), one = Self.slot([11, 12, 13], [11, 12], stop: 4)
        #expect(try Speculation.decide(zero + one, ranks: 2, window: 2) == .init(tokens: [11, 12, 13], stops: [0, 4]))
        #expect(throws: ProbeError.self) {
            try Speculation.decide(zero + Self.slot([11, 12, 15], [11, 12]), ranks: 2, window: 2)
        }
        #expect(throws: ProbeError.self) {
            try Speculation.decide(zero + Self.slot([11, 12, 13], [11, 17]), ranks: 2, window: 2)
        }
        #expect(throws: ProbeError.self) { try Speculation.decide(zero, ranks: 2, window: 2) }
    }

    /// One rank's split slot: its vocabulary half's maximum and global
    /// argmax at each window position, the proposals, the stop flag.
    static func split(_ maxima: [Float], _ indices: [Int], _ drafts: [Int], stop: Float = 0) -> [Float] {
        maxima + indices.map(Float.init) + drafts.map(Float.init) + [stop]
    }

    @Test func splitRoundsTakeTheLargerHalfAndRankZeroOnATie() throws {
        // Positions: rank 1 wins, a tie (rank 0's lower index), rank 0 wins.
        let zero = Self.split([1.5, 2.0, 3.0], [11, 12, 13], [80_000, 12])
        let one = Self.split([2.5, 2.0, -1.0], [80_000, 77_440, 90_000], [80_000, 12], stop: 2)
        #expect(try Speculation.decide(zero + one, ranks: 2, window: 2, vocabularySplit: true)
            == .init(tokens: [80_000, 12, 13], stops: [0, 2]))
        // The first proposal missing keeps only the first target.
        let early = Self.split([1.5, 2.0, 3.0], [11, 12, 13], [9, 12])
        let late = Self.split([2.5, 2.0, -1.0], [80_000, 77_440, 90_000], [9, 12])
        #expect(try Speculation.decide(early + late, ranks: 2, window: 2, vocabularySplit: true).tokens == [80_000])
        // No proposal: the window's one token.
        #expect(try Speculation.decide(Self.split([0.5], [3], []) + Self.split([0.25], [77_441], []),
            ranks: 2, window: 0, vocabularySplit: true).tokens == [3])
        // The ranks' proposals must agree; the split needs two ranks and greedy rounds.
        #expect(throws: ProbeError.self) {
            try Speculation.decide(zero + Self.split([2.5, 2.0, -1.0], [80_000, 77_440, 90_000], [80_000, 13]),
                ranks: 2, window: 2, vocabularySplit: true)
        }
        #expect(throws: ProbeError.self) {
            try Speculation.decide(zero + one, ranks: 2, window: 2, sampled: true, vocabularySplit: true)
        }
        #expect(throws: ProbeError.self) { try Speculation.decide(zero, ranks: 1, window: 2, vocabularySplit: true) }
        #expect(Speculation.segments(windows: [2, 0], ranks: 2, split: true) == [0 ..< 18, 18 ..< 24])
    }

    @Test func sampledRoundsTakeRankZerosDrawsAndCheckOnlyTheProposals() throws {
        // Rank 0 drew [11, 12, 13]; rank 1 put its argmax and adopts rank 0's draws.
        let zero = Self.slot([11, 12, 13], [11, 40]), one = Self.slot([11, 7, 9], [11, 40], stop: 3)
        #expect(try Speculation.decide(zero + one, ranks: 2, window: 2, sampled: true)
            == .init(tokens: [11, 12], stops: [0, 3]))
        // Greedy reading of the same values: the ranks' tokens differ.
        #expect(throws: ProbeError.self) { try Speculation.decide(zero + one, ranks: 2, window: 2) }
        // The proposals must still be equal.
        #expect(throws: ProbeError.self) {
            try Speculation.decide(zero + Self.slot([11, 7, 9], [11, 41]), ranks: 2, window: 2, sampled: true)
        }
    }

    /// A multi-lane round's agreement is each lane's own round's slots, lane
    /// after lane: every segment decides exactly as that lane's round alone.
    @Test func multiLaneAgreementIsEachLanesOwnRoundLaneAfterLane() throws {
        let segments = Speculation.segments(windows: [2, 0, 3], ranks: 2)
        #expect(segments == [0 ..< 12, 12 ..< 16, 16 ..< 32])
        let lanes: [[Float]] = [
            Self.slot([11, 12, 13], [11, 12]) + Self.slot([11, 12, 13], [11, 12], stop: 4),
            Self.slot([7], []) + Self.slot([7], []),
            Self.slot([1, 2, 3, 4], [1, 9, 3]) + Self.slot([1, 2, 3, 4], [1, 9, 3]),
        ]
        let values = lanes.flatMap { $0 }
        #expect(values.count == segments.last?.upperBound)
        for (index, (segment, window)) in zip(segments, [2, 0, 3]).enumerated() {
            #expect(try Speculation.decide(Array(values[segment]), ranks: 2, window: window)
                == Speculation.decide(lanes[index], ranks: 2, window: window))
        }
        #expect(try Speculation.decide(Array(values[segments[2]]), ranks: 2, window: 3).tokens == [1, 2])
        #expect(Speculation.segments(windows: [], ranks: 2).isEmpty)
    }

    @Test func requestChargeIsZeroWithoutSpeculationAndGrowsWithDepth() throws {
        let c = try GLM5NextMetadataTestFixture(layers: 8).configuration.textConfig
        let profile = try QwenLayerStageGenerationProfile(identifier: "glm-tp-mtp-fixture",
            vocabularySize: c.vocabularySize, hiddenSize: c.hiddenSize, activationDType: c.dtype,
            maximumPromptTokens: 128, maximumChunkTokens: 16, maximumOutputTokens: 8,
            maximumContextTokens: 256, residualStreams: 4)
        func bytes(_ depth: Int) throws -> Int {
            try GLM5NextTensorParallelResidentRuntime.speculationRequestBytes(configuration: c, profile: profile,
                depth: depth, executionPolicy: .reference, allocationBound: { $0 })
        }
        #expect(try bytes(0) == 0)
        let charges = try (1...3).map(bytes)
        #expect(charges[0] > 0 && charges[0] < charges[1] && charges[1] < charges[2])
        // At least the captured windows: two of depth + 1 states of every KDA layer.
        let linear = c.linearAttention, kda = c.layerTypes.filter { $0 == .linearAttention }.count
        let state = linear.numHeads * linear.headDim * linear.headDim * 4
            + 3 * linear.numHeads * linear.headDim * linear.shortConvKernelSize * 4
        #expect(charges[0] >= 2 * 2 * state * kda)
    }
}
