// Copyright © 2026 Eigen Labs.

import Foundation

/// Model-aware activation-reserve plumbing for the provider host.
///
/// The model scanner resolves each checkpoint's measured profile once and
/// advertises that byte value. Runtime policy carries the same value into the
/// loaded slot, uses the maximum across co-resident models, and publishes that
/// maximum to the process-wide KV ledger before weights can arrive.
extension ProviderLoop {
    static func activationReserveBytes(for model: ModelInfo) -> UInt64 {
        ModelActivationPolicy.reportedOrDefault(model.activationReserveBytes)
    }

    /// Conservative baseline used by the legacy scalar `free_for_load_gb`
    /// heartbeat field. Current coordinators instead use the separately
    /// reported pre-activation capacity with each candidate's exact reserve.
    func advertisedActivationReserveBytes() -> UInt64 {
        ModelActivationPolicy.largestReserveBytes(
            advertisedModels.values.lazy.map { Self.activationReserveBytes(for: $0) })
    }

    func fleetActivationReserveBytes(
        including candidate: (modelId: String, reserveBytes: UInt64)? = nil
    ) -> UInt64 {
        var reserves = modelsLoading
        for (modelId, slot) in modelSlots {
            reserves[modelId] = max(
                reserves[modelId] ?? 0,
                slot.sizing.activationReserveBytes)
        }
        if let candidate {
            reserves[candidate.modelId] = max(
                reserves[candidate.modelId] ?? 0,
                candidate.reserveBytes)
        }
        return ModelActivationPolicy.fleetReserveBytes(reserves.values)
    }

    static func loadHeadroomGb(activationReserveBytes: UInt64) -> Double {
        Double(UnifiedMemoryCap.loadHeadroomBytes(
            activationReserveBytes: activationReserveBytes
        )) / Double(ModelActivationPolicy.bytesPerGiB)
    }

    func requiredLoadGb(
        modelId: String,
        weightsGb: Double,
        candidateActivationReserveBytes: UInt64
    ) -> Double {
        ModelLoadAdmission.requiredToLoadGb(
            weightsGb: weightsGb,
            headroomGb: Self.loadHeadroomGb(
                activationReserveBytes: fleetActivationReserveBytes(
                    including: (
                        modelId: modelId,
                        reserveBytes: candidateActivationReserveBytes))))
    }

    func publishFleetActivationReserve(
        including candidate: (modelId: String, reserveBytes: UInt64)? = nil
    ) async {
        activationReserveGeneration &+= 1
        let generation = activationReserveGeneration
        await kvBudget.setActivationReserveBytes(
            fleetActivationReserveBytes(including: candidate),
            generation: generation)
    }
}
