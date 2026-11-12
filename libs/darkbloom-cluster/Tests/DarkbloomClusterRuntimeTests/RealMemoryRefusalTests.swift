import DarkbloomClusterProtocol
import Foundation
import Testing
@testable import DarkbloomClusterRuntime

/// A Mac whose memory another process holds, as the host memory gate samples
/// it: 512 MiB free, no file cache, normal pressure and no swap. No fault is
/// armed: the gates read it as they read the kernel's counters, and every
/// requirement a live gate asks is more than that.
enum TakenMemory {
    static let freeBytes = 512 * 1_048_576

    static func sample() -> QwenDenseStageLoadOSObservation {
        let now = DispatchTime.now().uptimeNanoseconds
        let page = 16_384, physical = QwenDenseStageLoadPolicy.localPhysicalMemoryBytes
        let free = freeBytes / page, used = physical / page - free
        return .init(startedNanoseconds: now, completedNanoseconds: now, timestampUTC: ResourceObservationTimestamp.utc(),
            physicalMemoryBytes: physical, pageSizeBytes: page, kernelFreePages: free, freePages: free,
            inactivePages: 0, speculativePages: 0, actualFreeBytes: free * page, estimatedReclaimableBytes: free * page,
            pressureLevel: QwenDenseStageLoadPolicy.normalPressureLevel, swapUsedBytes: 0, activePages: used,
            fileBackedPages: 0, anonymousPages: used, inactiveFileBackedPages: 0, inactiveAnonymousPages: 0)
    }

    /// `body` on this thread with every host sample reading `sample()`.
    static func whileTaken<T>(_ body: () throws -> T) rethrows -> T {
        try QwenDenseStageLoadResources.$sampleOverride.withValue({ sample() }, operation: body)
    }

    /// A running lane's check as the runtimes classify it (D6): true when
    /// memory refused it; any other refusal is thrown and fails the batch.
    static func refusesLane(_ gate: () throws -> Void) throws -> Bool {
        do { try whileTaken(gate); return false } catch is QwenResidentMemoryRefusal { return true }
    }

    static let gib = 1_073_741_824
    static func mimo() -> MiMoResidentRequestAllowance {
        .init(budget: .init(fullAttentionLayers: 1, slidingLayers: 0, fullAttentionStateBytes: gib, slidingStateBytes: 0,
            boundaryBytes: 0, rowBytes: 0, workspaceBytes: 0, reservedBytes: gib))
    }
    static func gptOSS() -> GPTOSSResidentRequestAllowance {
        .init(budget: .init(fullAttentionLayers: 1, slidingLayers: 0, fullAttentionStateBytes: gib, slidingStateBytes: 0,
            boundaryBytes: 0, rowBytes: 0, workspaceBytes: 0, reservedBytes: gib))
    }
    static func qwen() -> QwenResidentRequestAllowance {
        .init(stateBytes: gib, fusionBytes: 0, reservedBytes: gib, contextTokens: 4096)
    }
}

/// D6 in every pair mode, on a real refusal: this Mac's memory reads as
/// taken (no fault armed), and each family's running gate refuses it with
/// the typed memory refusal its stop latch, stop slot and lanes act on. An
/// untyped refusal ends the worker instead.
@Suite("A real memory refusal is typed in every running gate", .serialized)
struct RealMemoryRefusalTests {
    private static func typed(_ gate: () throws -> Void) -> Bool {
        do { try TakenMemory.whileTaken(gate); return false } catch is QwenResidentMemoryRefusal { return true } catch {
            Issue.record("an untyped refusal, which ends the worker: \(error)")
            return false
        }
    }

    @Test func theTakenSampleIsJudgedAndRefusedAtTheEntryFloor() throws {
        let decision = try QwenDenseStageLoadPolicy.decide(TakenMemory.sample(), requiredBytes: 0, purpose: "taken",
            now: DispatchTime.now().uptimeNanoseconds)
        #expect(!decision.admitted && decision.admissibleBytes == TakenMemory.freeBytes)
        // The load's entry check refuses it untyped: no running gate may ask it first.
        TakenMemory.whileTaken {
            #expect(throws: ProbeError.self) { _ = try QwenDenseStageLoadResources.requireInitial() }
        }
    }

    /// Gemma 4, GLM and MiMo tensor parallel (one request, Gemma's and GLM's
    /// lanes, GLM's page growth): `ClusterLiveMemory`.
    @Test func everyTensorParallelGateTypesARealRefusal() {
        #expect(Self.typed { try Gemma4TensorParallelResidentRuntime.requireLiveMemory(bytes: 0) })
        #expect(Self.typed { try GLM5NextTensorParallelResidentRuntime.requireLiveMemory(bytes: 0) })
        #expect(Self.typed { try MiMoTensorParallelResidentRuntime.requireLiveMemory(bytes: 0) })
    }

    /// The pipelines: MiMo's and GPT-OSS's gates (one request, MTP and lanes),
    /// and Qwen's and Gemma's, which were typed already.
    @Test func everyPipelineGateTypesARealRefusal() {
        #expect(Self.typed { try TakenMemory.mimo().requireLive() })
        #expect(Self.typed { try TakenMemory.mimo().requireLive(additionalNativeBytes: 1, additionalHostBytes: 1) })
        #expect(Self.typed { try TakenMemory.gptOSS().requireLive() })
        #expect(Self.typed { try TakenMemory.qwen().requireContinuing(grownBytes: 0) })
        #expect(Self.typed { try TakenMemory.qwen().requireLive(onLoadedStage: true) })
    }

    /// A stage's stop latch over MiMo's and GPT-OSS's own gates latches a
    /// real refusal instead of throwing it out of the transfer.
    @Test func aStopLatchOverAPipelineGateLatchesARealRefusal() throws {
        let gates: [(rank: Int, gate: () throws -> Void)] = [
            (1, { try TakenMemory.mimo().requireLive() }), (0, { try TakenMemory.gptOSS().requireLive() }),
        ]
        for (rank, gate) in gates {
            let latch = QwenStageAbort(rank: rank, intervalNanoseconds: 0) { try TakenMemory.whileTaken(gate) }
            #expect(try latch.poll())
            #expect(latch.latched == ClusterWorkerAbort(reason: .memory, rank: rank))
        }
    }
}
