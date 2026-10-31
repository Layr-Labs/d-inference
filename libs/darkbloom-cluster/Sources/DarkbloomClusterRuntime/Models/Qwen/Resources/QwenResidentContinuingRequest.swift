import Foundation
import MLX

extension QwenResidentRequestAllowance {
    /// What a running request still needs from the host: its charge less what
    /// this process's allocator already grew by since the request started,
    /// never below zero. The request was admitted at its reservation with its
    /// whole charge plus the loading headroom; the headroom is there for the
    /// host's drift between that admission and the allocations, so it is not
    /// asked for again on every check (re-asking turned an ordinary swing of
    /// desktop memory into the failure of a running request, and with it of
    /// the pair). The gate's harm guard still applies unchanged: once the
    /// kernel compressed or swapped out more than its limits since the
    /// request's first sample, no file cache is counted and free pages alone
    /// must cover what is still needed (`DESIGN-resource-gate-v3.md`, "The guard").
    static func continuingRequirement(reservedBytes: Int, additionalBytes: Int, grownBytes: Int) throws -> Int {
        guard reservedBytes >= 0, additionalBytes >= 0 else { throw ProbeError("Invalid continuing resident allowance") }
        return max(0, try QwenLongPrefillCheckedBytes.sum([reservedBytes, additionalBytes]) - max(0, grownBytes))
    }

    /// The live check while the request runs (`continuingRequirement`); the
    /// floor is the gate's truly-free tripwire instead of the 6 GiB a load asks.
    func requireContinuing(grownBytes: Int, additionalNativeBytes: Int = 0, additionalHostBytes: Int = 0) throws {
        guard additionalNativeBytes >= 0, additionalHostBytes >= 0 else {
            throw ProbeError("Invalid additional resident allowance")
        }
        // Power and thermal only: the entry check's 6 GiB floor would count
        // this request's own allocations against it (hardware, round-2 fix
        // u1: 0.58 GiB free once rank 1 had allocated a 30,848-token state).
        try QwenResidentResourceEnvironment.requirePower()
        let os = try QwenDenseStageLoadResources.observeOS()
        let remaining = try Self.continuingRequirement(reservedBytes: reservedBytes,
            additionalBytes: QwenLongPrefillCheckedBytes.sum([additionalNativeBytes, additionalHostBytes]),
            grownBytes: grownBytes)
        let remainingNative = try Self.continuingRequirement(reservedBytes: reservedBytes,
            additionalBytes: additionalNativeBytes, grownBytes: grownBytes)
        let allocator = try QwenLongPrefillCheckedBytes.sum([Memory.activeMemory, Memory.cacheMemory,
            remainingNative, QwenDenseStageLoadPolicy.allocatorHeadroomBytes])
        do {
            guard try watch.admits(os, bytes: remaining, floor: QwenDenseStageLoadPolicy.minimumTrulyFreeBytes),
                  Memory.memoryLimit >= allocator else {
                throw ProbeError("Resident request exceeds the allocator limit")
            }
        } catch {
            guard contextTokens > 0 else { throw error }
            throw ProbeError("A running request of \(contextTokens) context tokens (prompt plus output) on this rank: \(error)")
        }
    }
}
