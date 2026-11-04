import Foundation
import MLXLLM
import Testing
@testable import DarkbloomClusterRuntime

/// A serving GLM pipeline rank reserves no request at LOAD
/// (`GLM5NextResidentResourceEnvelope.admitsRequestsOnArrival`): it loads on
/// its weights and what only loading holds, and admits each request when it
/// arrives, at its own context, on live memory and its GPU's working set.
/// Synthetic metadata and constructed memory samples only: no model, no GPU work.
@Suite("GLM pipeline requests admitted on arrival")
struct GLM5NextRequestOnArrivalTests {
    typealias Fixture = GLM5NextResidentRuntimeTests.Fixture
    static let gib = 1 << 30

    @Test func aServingRankLoadsOnWhatLoadingNeedsWhereReservingTheRequestWouldNot() throws {
        let fixture = try Fixture()
        let inventory = fixture.artifact.metadata.inventory
        for rank in 0...1 {
            let roomy = try Fixture.resources(descriptor: fixture.descriptor, inventory: inventory, rank: rank, onArrival: true)
            let quote = try roomy.quote(descriptor: fixture.descriptor, maximumBufferBytes: Int.max, allocationBound: { $0 })
            let load = quote.load.summary.initialLoadPeakBytes
            #expect(load < quote.peak.reservedBytes && load == quote.peak.reservedBytes - quote.request.reservedBytes)
            func envelope(_ capacity: Int, onArrival: Bool) throws -> GLM5NextResidentResourceEnvelope {
                try Fixture.resources(descriptor: fixture.descriptor, inventory: inventory, rank: rank,
                    loadCapacity: capacity, onArrival: onArrival)
            }
            // What loading holds fits exactly; reserving the request beside it would not.
            _ = try envelope(load, onArrival: true).quote(descriptor: fixture.descriptor, maximumBufferBytes: Int.max,
                allocationBound: { $0 })
            #expect(throws: ProbeError.self) {
                try envelope(load, onArrival: false).quote(descriptor: fixture.descriptor, maximumBufferBytes: Int.max,
                    allocationBound: { $0 })
            }
            let refusal = #expect(throws: ProbeError.self) {
                try envelope(load - 1, onArrival: true).quote(descriptor: fixture.descriptor, maximumBufferBytes: Int.max,
                    allocationBound: { $0 })
            }
            let gib = QwenDenseStageLoadPolicy.gibText, weights = quote.load.summary.sourceAllocationBoundBytes
            #expect(refusal?.description == "GLM rank \(rank) at cut \(fixture.descriptor.cut) needs \(gib(load)) to load "
                + "(weights \(gib(weights)), load scratch \(gib(load - weights))), more than its load capacity of "
                + "\(gib(load - 1)) (on a serving rank, what its GPU keeps resident)")
        }
    }

    @Test func aRequestIsChargedAtItsOwnContextUpToTheMemoryPlan() throws {
        let fixture = try Fixture()
        let envelope = fixture.resources, descriptor = fixture.descriptor
        let maximum = descriptor.memoryProfile.maximumContextTokens
        let charges = try [2, 17, 64, 200, maximum].map { try envelope.budget(descriptor: descriptor, contextTokens: $0) }
        #expect(zip(charges, charges.dropFirst()).allSatisfy { $0.reservedBytes < $1.reservedBytes })
        #expect(charges.last == (try envelope.budget(descriptor: descriptor)))
        // The activation floor (the workspace) is charged whatever the context.
        #expect(charges.allSatisfy { $0.workspaceNativeBytes == charges.last!.workspaceNativeBytes })
        #expect(throws: ProbeError.self) { _ = try envelope.budget(descriptor: descriptor, contextTokens: 1) }
        #expect(throws: ProbeError.self) { _ = try envelope.budget(descriptor: descriptor, contextTokens: maximum + 1) }
    }

    /// A consistent sample: `freeGiB` of free pages and nothing else counted.
    static func observation(freeGiB: Double, physicalGiB: Int = 128, activeGiB: Double,
                            cacheGiB: Double = 0) -> QwenTensorParallelRequestCharge.GateObservation {
        let page = 16_384, free = Int(freeGiB * Double(gib)) / page, inactive = 1_000, speculative = 500
        let os = QwenDenseStageLoadOSObservation(startedNanoseconds: 900, completedNanoseconds: 1_000,
            timestampUTC: "2026-11-01T00:00:00Z", physicalMemoryBytes: physicalGiB * gib, pageSizeBytes: page,
            kernelFreePages: free + speculative, freePages: free, inactivePages: inactive,
            speculativePages: speculative, actualFreeBytes: free * page,
            estimatedReclaimableBytes: (free + inactive + speculative) * page, pressureLevel: 1, swapUsedBytes: 0)
        return .init(os: os, uptimeNanoseconds: 1_100, activeBytes: Int(activeGiB * Double(gib)),
            cacheBytes: Int(cacheGiB * Double(gib)), memoryLimitBytes: 121 * gib)
    }

    /// GLM rank 0 at cut 24 on an M5 Max 128 GB, in the shape of its quote:
    /// about 20.8 GiB at 65,536 tokens, of which about 6.75 GiB grows with the
    /// context; 83.5 GiB of weights resident.
    static func charge(_ context: Int) -> (native: Int, host: Int) {
        (native: 13_100_000_000 + 110_628 * context, host: 1_250_000_000)
    }

    @Test func theServingContextIsTheLongestThatFitsNowAndOneWhenNothingDoes() throws {
        func serving(_ sample: QwenTensorParallelRequestCharge.GateObservation, gpuGiB: Double = 112,
                     reclaimableGiB: Double = 0) throws -> Int {
            try GLM5NextResidentRuntime.servingContext(memoryContextTokens: 65_536, chunkTokens: 2048,
                observation: sample, reclaimableBytes: Int(reclaimableGiB * Double(Self.gib)),
                gpuLimitBytes: Int(gpuGiB * Double(Self.gib)), charge: Self.charge)
        }
        // An idle Mac with the stage loaded: a 65,536-token request fits now.
        #expect(try serving(Self.observation(freeGiB: 36, activeGiB: 83.5)) == 65_536)
        // Applications hold memory: only a shorter context passes the host gate, and exactly the longest one that does.
        let short = try serving(Self.observation(freeGiB: 21, activeGiB: 83.5))
        #expect(short > 2049 && short < 65_536)
        let required = { (context: Int) in Self.charge(context).native + Self.charge(context).host + 4 * Self.gib }
        #expect(required(short) <= 21 * Self.gib && required(short + 1) > 21 * Self.gib)
        // The GPU's working set binds: the stage and the request must fit it together.
        let bound = try serving(Self.observation(freeGiB: 36, activeGiB: 83.5), gpuGiB: 100)
        #expect(bound > 2049 && bound < 65_536 && Int(83.5 * Double(Self.gib)) + Self.charge(bound).native <= 100 * Self.gib)
        // Not even one chunk and one output token fit: 1, so the pair refuses every request up front.
        #expect(try serving(Self.observation(freeGiB: 8, activeGiB: 83.5)) == 1)
        #expect(try serving(Self.observation(freeGiB: 36, activeGiB: 83.5), gpuGiB: 90) == 1)
        // Kept prompt prefixes give way before a reservation is refused, so they count as free.
        #expect(try serving(Self.observation(freeGiB: 21, activeGiB: 89.5), reclaimableGiB: 6) > short)
    }
}
