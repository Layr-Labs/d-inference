import MLXLMCommon

/// Read-only facts captured from a live bridge. Missing facts stay absent;
/// ready state and a persistent key do not by themselves prove a cache hit.
struct LocalServingPosture: Sendable {
    let backend: EngineV2KVBackendKind
    let capacity: CBv2CapacitySnapshot
    let pageSize: Int?
    let prefix: PrefixCacheModelStatus
    let completeKeyPersistent: Bool?
    var prefixConstructionFailure: SSDPrefixCacheConstructionFailure? = nil
    /// A cluster pair's slot (`DistributedCBv2Engine`): its KV lives in the
    /// ranks' own pools, charged whole to each request at reservation; the
    /// leader holds that reservation ledger, so the paged families report it.
    var pairLedger = false
}

extension EngineV2Bridge {
    func localMetricsSample(model: String) -> MTPSlotMetricsSample? {
        guard ownedEngine != nil else { return nil }
        return .init(model: model, snapshot: mtpStatusSnapshot(), posture: .init(
            backend: kvBackendKind, capacity: capacitySnapshot(), pageSize: pagedPageSize,
            prefix: prefixCacheModelStatus(),
            completeKeyPersistent: ssdHybridCheckpointStore.map { !$0.usesEphemeralKey },
            prefixConstructionFailure: prefixCacheConstructionFailure))
    }
}

extension EngineV2Bridge {
    /// A cluster pair's `/metrics` sample (the cluster API): the MTP counts
    /// rank 0's runtime reported request by request
    /// (`DistributedCBv2Engine.mtpTotalsSnapshot`), the requests the pair runs
    /// and the requests `waitingRequests` waiting for a lane, its
    /// reservation ledger, and its prefix cache (resident on both ranks,
    /// never persisted). Nil unless the slot serves a pair.
    func pairMetricsSample(model: String, waitingRequests: Int) -> MTPSlotMetricsSample? {
        guard let pair = ownedEngine as? DistributedCBv2Engine else { return nil }
        var capacity = capacitySnapshot()
        capacity.waitingRequests = max(capacity.waitingRequests, waitingRequests)
        return .init(model: model, snapshot: ProviderMTPStatusSnapshot(pair: pair.mtpTotalsSnapshot()), posture: .init(
            backend: kvBackendKind, capacity: capacity, pageSize: nil, prefix: prefixCacheModelStatus(),
            completeKeyPersistent: false, pairLedger: true))
    }
}

extension ProviderMTPStatusSnapshot {
    /// A cluster pair's MTP posture: its runtime drafts with the model's own
    /// NextN head on the decoding rank; `configured` once a request reported
    /// MTP counts, `active` once a round ran. No assistant artifact.
    init(pair totals: DistributedMTPTotals) {
        configured = totals.reported
        active = totals.rounds > 0
        verificationMode = nil
        acceptance = nil
        rectangularVerificationRounds = 0
        serialVerificationRounds = 0
        fallbackReason = nil
        assistantSource = nil
        assistantRevision = nil
        assistantSourceRevision = nil
        assistantArtifactBytes = 0
        assistantResidentBytes = 0
        selectedDepth = 0
        decodeRowBucket = 0
        rounds = totals.rounds
        seedRows = 0
        proposedTokens = totals.proposed
        acceptedDraftTokens = totals.accepted
        committedEmittedTokens = 0
        acceptanceByPosition = []
        skippedRows = [:]
        controllerFallbacks = [:]
    }
}

enum LocalServingPostureRenderer {
    static func render(_ samples: [MTPSlotMetricsSample]) -> String {
        var families: [String: [String]] = [:]
        func add(_ name: String, _ labels: String, _ value: Int) {
            families[name, default: []].append("\(name){\(labels)} \(value)")
        }
        for sample in samples {
            guard let posture = sample.posture else { continue }
            let model = "model=\"\(MTPPrometheusRenderer.escapeLabel(sample.model))\""
            add("kv_backend_info", model + ",backend=\"\(posture.backend.rawValue)\"", 1)
            add("kv_active_requests", model, posture.capacity.activeRequests)
            add("kv_waiting_requests", model, posture.capacity.waitingRequests)
            if posture.pairLedger {
                // The pair's equivalents, labelled as its ledger: the running
                // requests' reservations (granted and committed at admission),
                // the bytes they use now, and what the pair's live gate admits
                // for requests. Page size 0: the ranks' page geometry does not
                // reach the leader (each rank logs `paged_kv=` at load).
                let ledger = model + ",ledger=\"cluster_pair\""
                add("paged_kv_page_size", ledger, 0)
                add("paged_kv_live_bytes", ledger, posture.capacity.kvBytesInUse)
                add("paged_kv_reserved_bytes", ledger, posture.capacity.kvBytesReserved)
                add("paged_kv_grant_bytes", ledger, posture.capacity.kvBytesCapacity)
                add("paged_kv_committed_bytes", ledger, posture.capacity.kvBytesReserved)
            } else if posture.backend == .paged {
                if let pageSize = posture.pageSize { add("paged_kv_page_size", model, pageSize) }
                if let storage = posture.capacity.pagedStorage {
                    add("paged_kv_live_bytes", model, storage.livePageBytes)
                    add("paged_kv_reserved_bytes", model, storage.reservedPageBytes)
                    add("paged_kv_grant_bytes", model, storage.grantBytes)
                    add("paged_kv_committed_bytes", model, storage.committedBytes)
                }
            }
            let prefix = posture.prefix
            var prefixLabels = model + ",state=\"\(prefix.state.rawValue)\",reason=\"\(prefix.reason.rawValue)\""
            // `reason` keeps the coordinator's closed heartbeat vocabulary;
            // `detail` names the local typed refusal behind an error status.
            if prefix.state == .error, let failure = posture.prefixConstructionFailure {
                prefixLabels += ",detail=\"\(failure.rawValue)\""
            }
            add("prefix_cache_status", prefixLabels, 1)
            if let persistent = posture.completeKeyPersistent {
                add("complete_prefix_key_persistent", model, persistent ? 1 : 0)
            }
        }
        return families.keys.sorted().map { name in
            "# TYPE \(name) gauge\n" + families[name]!.joined(separator: "\n") + "\n"
        }.joined()
    }
}
