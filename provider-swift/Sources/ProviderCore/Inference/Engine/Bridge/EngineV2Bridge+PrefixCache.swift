import MLXLMCommon

// MARK: - Bridge surfaces

extension EngineV2Bridge {

    nonisolated func prefixCacheEvidenceCallbacks(
        requestID: String, nonce: String, send: SendHandle,
        readyBoundaryMode: String? = nil
    ) -> PrefixCacheV2EvidenceCallbacks? {
        let ssd = prefixCacheEvidenceSequencer?.callbacks(
            requestID: requestID, nonce: nonce, send: send,
            readyBoundaryMode: readyBoundaryMode)
        let memory = residentPrefixCacheEvidenceSequencer?.callbacks(
            requestID: requestID, nonce: nonce, send: send,
            forwardTerminal: ssd == nil)
        guard ssd != nil || memory != nil else { return nil }
        return PrefixCacheV2EvidenceCallbacks(
            lookup: { result in
                ssd?.lookup(result)
                memory?.lookup(result)
            },
            ready: { result in
                ssd?.ready(result)
                memory?.ready(result)
            },
            terminal: { message in
                memory?.terminal(message)
                ssd?.terminal(message)
            })
    }

    nonisolated func prefixCacheModelStatus() -> PrefixCacheModelStatus {
        guard let durablePrefixCacheEvidenceSource else { return prefixCacheBaseStatus }
        return durablePrefixCacheEvidenceSource.prefixCacheAdvertisement(base: prefixCacheBaseStatus).status
    }

    /// Slot KV grant for contiguous/segmented storage; physical capacity for
    /// an explicit fixed-reference paged pool. Actual segmented ownership is
    /// tracked by native Admission and the shared process ledger.
    /// Fleet sizing (`makeEngineV2BridgeForSlot`) and the heartbeat clamp
    /// (`EngineV2Runtime.capacitySummary`) subtract THIS — not the bare
    /// engine capacity — for co-resident slots.
    public func slotKVBytesClaim() -> Int {
        let snapshot = capacitySnapshot()
        let engineClaim =
            kvBackendKind == .paged && snapshot.kvBytesBackendCapacity > 0
            ? snapshot.kvBytesBackendCapacity
            : snapshot.kvBytesCapacity
        return engineClaim
    }

    /// Current logical admission target. Re-slice rollback uses this exact
    /// value; unlike `slotKVBytesClaim()`, it does
    /// not replace a shrunk fixed-reference ledger with its larger physical pool.
    func resliceAdmissionBytesClaim() -> Int {
        engine.capacity().kvBytesCapacity
    }
}
