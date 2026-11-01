import Foundation
import Testing
@testable import DarkbloomClusterRuntime

/// Every reservation charges its request at its own context
/// (`GLM5NextTensorParallelRequestCharge.bytes`), on both ranks in turn,
/// before the request starts. On the registered artifact's real inventory
/// (114,160 stored tensors) the charge must not re-hash the inventory each
/// time: those hashes are computed once (`EvidenceDigests`), and the charge
/// is the bytes the per-call estimate gives. Reads the artifact's metadata
/// and safetensors headers only (no weight), from
/// `GLM_CHARGE_TIMING_MODEL_DIR`; skipped without it.
struct GLM5NextRequestChargeTimingTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLM_CHARGE_TIMING_MODEL_DIR"] != nil))
    func aReservationsChargeDoesNotHashTheInventory() throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GLM_CHARGE_TIMING_MODEL_DIR"]!)
        let spec = try GLM5NextRegisteredSpecification.specification(runtimeModelID: GLM5NextRegisteredModel.glm53Flash.rawValue)
        let config = try BoundedProbeInput.data(directory.appendingPathComponent("config.json"),
            maximumBytes: GLM5NextRegisteredSpecification.maximumConfigurationBytes)
        let manifest = try BoundedProbeInput.data(directory.appendingPathComponent("manifest.json"),
            maximumBytes: GLM5NextRegisteredSpecification.maximumManifestBytes)
        let descriptor = try spec.descriptor(configuration: config, manifest: manifest, cut: spec.supportedCuts[21])
        let inventory = try descriptor.inspectInventory(directory: directory)
        #expect(inventory.entries.count == 114_160)
        let envelopes = try (0 ..< 2).map {
            try GLM5NextServingResources.envelope(descriptor: descriptor, inventory: inventory, rank: $0,
                buildSHA256: String(repeating: "a", count: 64))
        }
        let charge = try GLM5NextTensorParallelRequestCharge(descriptor: descriptor, envelopes: envelopes,
            fixedBytes: 1 << 30, speculativeDepth: 2, maximumBufferBytes: Int.max,
            allocationBound: QwenResidentResourceEnvironment.allocationBound)
        func seconds(_ body: () throws -> Void) rethrows -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        }
        // What every charge used to compute twice (once per envelope).
        let digests = try (0 ..< 3).map { _ in
            try seconds { _ = try GLM5NextRequestStateBudget.EvidenceDigests(inventory: inventory,
                executionPolicy: descriptor.executionPolicy) }
        }
        // A 2.7K-token prompt with 8 outputs, as the endpoint bench's short prompt.
        var bytes = 0
        let charges = try (0 ..< 20).map { _ in try seconds { bytes = try charge.bytes(contextTokens: 2_708) } }
        // The same charge with the digests computed in the estimate, as before.
        let c = descriptor.configuration.textConfig, p = descriptor.profile, context = 2_708
        let prompt = min(p.maximumPromptTokens, context - 1)
        let scope = GLM5NextRequestStateBudget.Scope(maximumContextTokens: context, maximumPromptTokens: prompt,
            maximumOutputTokens: min(p.maximumOutputTokens, context - 1), maximumChunkTokens: min(p.maximumChunkTokens, prompt))
        let history = GLM5NextRequestStateBudget.HistoryBound.reserved(tokens: charge.historyTokens(contextTokens: context))
        for envelope in envelopes {
            let layers = envelope.rank == 0 ? 0 ..< descriptor.cut : descriptor.cut ..< c.hiddenLayers
            func estimate(_ digests: GLM5NextRequestStateBudget.EvidenceDigests?) throws -> GLM5NextRequestStateBudget {
                try GLM5NextRequestStateBudget.estimate(inventory: envelope.inventory, layers: layers, rank: envelope.rank,
                    scope: scope, executionPolicy: descriptor.executionPolicy,
                    executionEnvironmentSHA256: envelope.executionEnvironmentSHA256, workspace: envelope.workspace,
                    transport: GLM5NextResidentResourceEnvelope.transportTerms, maximumBufferBytes: Int.max,
                    allocationBound: QwenResidentResourceEnvironment.allocationBound,
                    hostAllocationBound: envelope.hostAllocationBound, history: history, digests: digests)
            }
            #expect(try estimate(nil) == estimate(charge.digests[envelope.rank]))
        }
        let median = charges.sorted()[charges.count / 2]
        print(String(format: "glm-charge-timing digests_ms=%@ charge_ms_median=%.3f charge_ms_max=%.3f bytes=%d",
            digests.map { String(format: "%.1f", $0 * 1000) }.joined(separator: ","), median * 1000,
            (charges.max() ?? 0) * 1000, bytes))
        // Hashing the inventory alone takes tens of milliseconds; a charge, well under one.
        #expect(median < 0.005)
    }
}
