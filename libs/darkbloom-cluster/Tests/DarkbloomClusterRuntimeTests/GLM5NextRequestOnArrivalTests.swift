import DarkbloomClusterProtocol
import Foundation
import MLX
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

    /// The fixture's model with a memory plan's request (32 + 8 within 64 tokens) below its profile (128 + 8 within
    /// 256), as the registered row's 32,768 + 32,768 is below its native context.
    static func scopedDescriptor(_ fixture: Fixture) throws -> GLM5NextResidentDescriptor {
        let d = fixture.descriptor
        return try GLM5NextResidentDescriptor(modelID: d.modelID, artifactIdentity: d.artifactIdentity,
            artifactAggregateSHA256: d.artifactAggregateSHA256,
            configurationBytes: Data(contentsOf: fixture.artifact.url("config.json")), cut: d.cut, storage: d.storage,
            executionPolicy: d.executionPolicy, profileID: d.profile.identifier, maximumPromptTokens: 128,
            maximumChunkTokens: 16, maximumOutputTokens: 8, maximumContextTokens: 256,
            memoryScope: .init(promptTokens: 32, outputTokens: 8, contextTokens: 64))
    }

    /// The registered row's serving pipeline rank admits on arrival up to the pipeline's owner context, 262,144
    /// tokens: 262,143 prompt and the registered 65,536 output tokens, beyond the memory plan's 32,768 + 32,768.
    @Test func theRegisteredRowsServingRankAdmitsUpTo262144Tokens() throws {
        let spec = try #require(GLM5NextRegisteredSpecification.all.first)
        let memory = try spec.memoryProfile()
        let arrival = try GLM5NextResidentDescriptor.arrivalProfile(profile: spec.profile(), memoryProfile: memory)
        #expect(arrival.maximumContextTokens == 262_144 && arrival.maximumPromptTokens == 262_143)
        #expect(arrival.maximumOutputTokens == 65_536 && arrival.maximumChunkTokens == 2048)
        #expect(arrival.identifier == memory.identifier)
        #expect(ClusterRuntimeAdapter.glm5NextLayerStage.pipelineOwnerContextTokens == arrival.maximumContextTokens)
        // A profile within the memory plan's request: that request.
        #expect(try GLM5NextResidentDescriptor.arrivalProfile(profile: memory, memoryProfile: memory) == memory)
    }

    /// A serving rank charges a request at its own context up to its arrival profile, beyond the memory plan's
    /// request, with the DSA indexer's prefill scores beyond the memory plan's context; a rank whose LOAD reserved
    /// the request stays within it.
    @Test func aServingRankChargesARequestBeyondTheMemoryPlanUpToItsArrivalProfile() throws {
        let fixture = try Fixture()
        let descriptor = try Self.scopedDescriptor(fixture), inventory = fixture.artifact.metadata.inventory
        #expect(descriptor.memoryProfile.maximumContextTokens == 64)
        #expect(descriptor.arrivalProfile.maximumContextTokens == 256)
        // Rank 1 holds the fixture's DSA layers (3 and 7 of 8).
        let serving = try Fixture.resources(descriptor: descriptor, inventory: inventory, rank: 1, onArrival: true)
        let loaded = try Fixture.resources(descriptor: descriptor, inventory: inventory, rank: 1)
        let charges = try [64, 65, 200, 256].map { try serving.budget(descriptor: descriptor, contextTokens: $0) }
        #expect(zip(charges, charges.dropFirst()).allSatisfy { $0.reservedBytes < $1.reservedBytes })
        #expect(throws: ProbeError.self) { _ = try serving.budget(descriptor: descriptor, contextTokens: 257) }
        #expect(throws: ProbeError.self) { _ = try loaded.budget(descriptor: descriptor, contextTokens: 65) }
        // One chunk's FP32 scores over the context's pools, beyond those of the memory plan's context.
        let c = descriptor.configuration.textConfig
        func pools(_ context: Int) -> Int { (context + c.indexKPool - 1) / c.indexKPool }
        #expect(charges[0].indexScoreBytes == 0)
        let scores = try QwenResidentResourceEnvironment.allocationBound(16 * (pools(256) - pools(64)) * 4)
        #expect(charges[3].indexScoreBytes == scores)
        let plain = try GLM5NextRequestStateBudget.estimate(inventory: inventory,
            layers: descriptor.cut..<c.hiddenLayers, rank: 1,
            scope: charges[3].scope, executionPolicy: descriptor.executionPolicy,
            executionEnvironmentSHA256: serving.executionEnvironmentSHA256, workspace: serving.workspace,
            transport: GLM5NextResidentResourceEnvelope.transportTerms, maximumBufferBytes: GPU.deviceInfo().maxBufferSize,
            allocationBound: QwenResidentResourceEnvironment.allocationBound,
            hostAllocationBound: serving.hostAllocationBound)
        #expect(charges[3].nativeBytes == plain.nativeBytes + scores)
        #expect(charges[3].reservedBytes == plain.reservedBytes + scores)
    }

    /// A serving rank's admission takes a request beyond the memory plan's request, within its arrival profile; a
    /// rank whose LOAD reserved the request refuses it.
    @Test func aServingRanksAdmissionTakesARequestBeyondTheMemoryPlan() throws {
        let fixture = try Fixture()
        let descriptor = try Self.scopedDescriptor(fixture), inventory = fixture.artifact.metadata.inventory
        let now = DispatchTime.now().uptimeNanoseconds
        func admission(onArrival: Bool) throws -> GLM5NextResidentAdmission {
            try GLM5NextResidentAdmission(configuration: fixture.configuration(rank: 0), descriptor: descriptor,
                resources: Fixture.resources(descriptor: descriptor, inventory: inventory, rank: 0, onArrival: onArrival),
                now: now)
        }
        func reservation(prompt: Int, output: Int) -> ClusterWorkerReservation {
            .init(profileID: descriptor.profile.identifier, promptTokenIDs: Array(repeating: 4, count: prompt),
                stopTokenIDs: [], outputCount: output, chunkSize: 16, deadlineUptimeNanoseconds: now + 30_000_000_000,
                capacityLimitBytes: 64 << 20, sampling: nil, prefixCache: nil)
        }
        let serving = try admission(onArrival: true), loaded = try admission(onArrival: false)
        #expect(try serving.request(reservation(prompt: 120, output: 8), id: UUID(), now: now).maximumTokens == 128)
        #expect(throws: ProbeError.self) {
            _ = try loaded.request(reservation(prompt: 120, output: 8), id: UUID(), now: now)
        }
        #expect(try loaded.request(reservation(prompt: 32, output: 8), id: UUID(), now: now).maximumTokens == 40)
    }

    /// A serving rank's request capacity, which its READY reports, is its quotation at its arrival profile's context:
    /// the longest request it serves fits it. A rank whose LOAD reserves the request keeps the memory plan's.
    @Test func aServingRanksRequestCapacityQuotesItsArrivalContext() throws {
        let fixture = try Fixture()
        let descriptor = try Self.scopedDescriptor(fixture), inventory = fixture.artifact.metadata.inventory
        let build = String(repeating: "a", count: 64)
        // Rank 1 holds the fixture's DSA layers, whose histories grow with the context.
        let serving = try GLM5NextServingResources.envelope(descriptor: descriptor, inventory: inventory, rank: 1,
            buildSHA256: build, admitsRequestsOnArrival: true)
        let loaded = try GLM5NextServingResources.envelope(descriptor: descriptor, inventory: inventory, rank: 1,
            buildSHA256: build)
        #expect(serving.requestCapacityBytes == (try serving.budget(descriptor: descriptor, contextTokens: 256)).reservedBytes)
        #expect(loaded.requestCapacityBytes == (try loaded.budget(descriptor: descriptor)).reservedBytes)
        #expect(serving.requestCapacityBytes > loaded.requestCapacityBytes)
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
