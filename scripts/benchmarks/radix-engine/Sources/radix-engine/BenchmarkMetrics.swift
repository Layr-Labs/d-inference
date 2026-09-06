import Foundation
import MLX
import MLXLMCommon
#if RADIX_CANDIDATE
@_spi(Benchmarking) import ProviderCore
#endif

enum BenchmarkMetrics {
    /// Call only after serial completion, all batch tasks, or full shutdown.
    /// Resident reproduction and archived backends retain their original metrics.
    static func idleSnapshot(_ loaded: Loaded, shutdown: Bool = false) async -> [String: Any] {
        #if RADIX_CANDIDATE
        if loaded.session != nil {
            return await BenchmarkIdleObservation.capture(paged: loaded.backend == "paged", shutdown: shutdown) {
                await snapshot(loaded)
            }
        }
        #endif
        return await snapshot(loaded)
    }

    static func snapshot(_ loaded: Loaded) async -> [String: Any] {
        var result = snapshot(loaded.engine)
        let usage = mlxMemory()
        result["mlx_memory"] = ["active_bytes": usage.active, "cache_bytes": usage.cached,
                                "peak_bytes": usage.peak]
        result["process_rss_bytes"] = processResidentBytes() as Any? ?? NSNull()
        #if RADIX_CANDIDATE
        if let session = loaded.session {
            let snapshot = await session.cacheSnapshot()
            if let memory = snapshot.processMemory { result["process_memory"] = processMemory(memory) }
            result["assistant_identity"] = snapshot.assistantIdentity
            result["cache_mode"] = snapshot.durableMode as Any? ?? NSNull()
            result["key_mode"] = snapshot.keyMode as Any? ?? NSNull()
            result["cache_status"] = ["state": snapshot.status.state.rawValue, "reason": snapshot.status.reason.rawValue]
            result["memory_cache_enabled"] = snapshot.memoryEnabled
            result["resident_bank_budget_bytes"] = snapshot.recurrentBankBudgetBytes
            result["engine_kv_capacity_bytes"] = snapshot.engineKVCapacityBytes
            result["physical_memory_bytes"] = snapshot.physicalMemoryBytes
            result["activation_reserve_bytes"] = snapshot.activationReserveBytes
            result["post_load_maximum_kv_bytes"] = snapshot.postLoadMaximumKVBytes
            result["post_load_maximum_scope"] = "Memory.active diagnostic; explicit-mode guard only; production grant uses loaded parameters"
            if let grant = snapshot.productionGrant {
                result["production_grant"] = [
                    "physical_bytes": grant.physicalBytes, "cap_fraction": grant.capFraction,
                    "hard_cap_bytes": grant.hardCapBytes, "effective_cap_bytes": grant.effectiveCapBytes,
                    "operator_reserve_bytes": grant.operatorReserveBytes,
                    "activation_reserve_bytes": grant.activationReserveBytes,
                    "target_weight_bytes": grant.targetWeightBytes, "assistant_weight_bytes": grant.assistantWeightBytes,
                    "resident_weight_bytes": grant.residentWeightBytes,
                    "ram_prefix_allowance_bytes": grant.ramPrefixAllowanceBytes,
                    "slot_count": grant.slotCount, "fleet_budget_bytes": grant.fleetBudgetBytes,
                    "grant_bytes": grant.grantBytes,
                ] as [String: Any]
            }
            if let headroom = snapshot.postBuildHeadroomBytes {
                result["post_build_headroom_bytes"] = headroom
            }
            if let stats = snapshot.attention {
                result["ssd_attention_cache"] = [
                    "hits": stats.hits, "misses": stats.misses, "tokens_saved": stats.tokensSaved,
                    "stages": stats.stages, "staged_bytes_in_use": stats.stagedBytesInUse,
                    "blocks_written": stats.blocksWritten, "bytes_written": stats.bytesWritten,
                    "donations_dropped": stats.donationsDropped, "corrupt_dropped": stats.corruptDropped,
                    "evictions": stats.evictions, "ttl_expired": stats.ttlExpired,
                    "entries": stats.entries, "bytes_on_disk": stats.bytesOnDisk,
                    "windows_restored": stats.windowsRestored,
                ]
            }
            if let stats = snapshot.checkpoints {
                result["ssd_cache"] = [
                    "stage_consumptions": stats.stageConsumptions, "consumed_prefix_tokens": stats.consumedPrefixTokens,
                    "misses": stats.misses, "stages": stats.stages,
                    "staged_bytes_in_use": stats.stagedBytesInUse,
                    "peak_staging_reservation_bytes": stats.peakStagingReservationBytes,
                    "maximum_segment_bytes": stats.maximumSegmentBytes,
                    "files_read": stats.filesRead, "bytes_read": stats.bytesRead,
                    "stage_read_bytes": stats.stageReadBytes, "donation_read_bytes": stats.donationReadBytes,
                    "files_written": stats.filesWritten, "bytes_written": stats.bytesWritten,
                    "writes_dropped": stats.writesDropped, "corrupt_dropped": stats.corruptDropped,
                    "entries": stats.entries, "bytes_on_disk": stats.bytesOnDisk,
                    "write_ms": stats.writeMilliseconds, "stage_ms": stats.stageMilliseconds,
                    "write_host_bytes_in_use": stats.writeHostBytesInUse,
                    "peak_write_host_bytes": stats.peakWriteHostBytes,
                    "write_host_capacity_refusals": stats.writeHostCapacityRefusals,
                ] as [String: Any]
            }
        }
        #endif
        return result
    }

    static func mlxMemory() -> (active: Int, cached: Int, peak: Int) {
        #if RADIX_CANDIDATE
        let usage = Memory.snapshot()
        return (usage.activeMemory, usage.cacheMemory, usage.peakMemory)
        #else
        // Archived dependencies expose separate, non-coherent observations.
        return (Memory.activeMemory, Memory.cacheMemory, Memory.peakMemory)
        #endif
    }

    #if RADIX_CANDIDATE
    static func processMemory(_ value: ProcessMemoryTelemetry) -> [String: Any] {
        ["generation": value.generation, "sample_seq": value.sampleSeq,
         "sample_age_ms": value.sampleAgeMs, "policy_epoch": value.policyEpoch, "cap_bytes": value.capBytes,
         "activation_reserve_bytes": value.activationReserveBytes,
         "active_bytes": value.activeBytes, "cache_bytes": value.cacheBytes,
         "charged_bytes": value.chargedBytes, "materialized_bytes": value.materializedBytes,
         "unmaterialized_bytes": value.unmaterializedBytes, "remaining_bytes": value.remainingBytes,
         "commitment_debt_bytes": value.commitmentDebtBytes,
         "owner_count": value.ownerCount, "closing_owner_count": value.closingOwnerCount,
         "system_available_bytes": value.systemAvailableBytes as Any? ?? NSNull()]
    }
    #endif

    // Read after the terminal event. Counters are cumulative so the exact
    // request deltas remain reconstructable without timing serialization.
    static func snapshot(_ engine: any CBv2Engine) -> [String: Any] {
        guard let engine = engine as? EngineV2 else { return [:] }
        let capacity = engine.capacity()
        var result: [String: Any] = ["capacity": [
            "active_requests": capacity.activeRequests, "waiting_requests": capacity.waitingRequests,
            "kv_in_use_bytes": capacity.kvBytesInUse, "kv_reserved_bytes": capacity.kvBytesReserved,
            "kv_capacity_bytes": capacity.kvBytesCapacity,
            "kv_backend_capacity_bytes": capacity.kvBytesBackendCapacity,
            "active_tokens": capacity.activeTokens, "steps_executed": capacity.stepsExecuted,
            "step_wall_nanos_total": capacity.stepWallNanosTotal,
            "decode_rows_total": capacity.decodeRowsTotal,
        ] as [String: Any]]
        if let storage = pagedStorage(capacity) {
            result["paged_storage"] = storage
        }
        if let mtp = engine.mtpMetricsSnapshot() {
            result["mtp"] = [
                "active": mtp.active, "verification_mode": String(describing: mtp.verificationMode),
                "rounds": mtp.rounds, "seed_steps": mtp.seedSteps,
                "proposed_tokens": mtp.proposedTokens, "accepted_tokens": mtp.acceptedTokens,
                "emitted_tokens": mtp.emittedTokens, "selected_depth": mtp.selectedDepth,
                "serial_rounds": mtp.serialVerificationRounds,
                "rectangular_rounds": mtp.rectangularVerificationRounds,
                "max_rectangular_tokens": mtp.maxAutomaticRectangularTokens,
                "skipped_rows": mtp.skippedRows, "depth_selections": mtp.depthSelections.mapKeysToStrings(),
                "controller_fallbacks": mtp.controllerFallbacks,
            ] as [String: Any]
        }
        #if RADIX_CANDIDATE
        if let stats = engine.hybridPrefixCache?.stats {
            result["hybrid_cache"] = [
                "resident_bytes": stats.residentBytes, "staged_bytes": stats.stagedBytes,
                "publishing_bytes": stats.publishingBytes, "retained_bytes": stats.retainedBytes,
                "entries": stats.entries, "checkpoints": stats.checkpoints,
                "lookup_matches": stats.lookupMatches, "misses": stats.misses,
                "adoptions": stats.adoptions, "tokens_saved": stats.tokensSaved,
                "capacity_refusals": stats.capacityRefusals, "evictions": stats.evictions,
                "kv_compactions": stats.kvCompactions, "kv_compaction_bytes": stats.kvCompactionBytes,
            ]
        }
        #endif
        return result
    }

    // The engine captured this value on its owner queue. Never read mutable
    // page-pool metadata directly from the benchmark's sampling task.
    static func pagedStorage(_ capacity: CBv2CapacitySnapshot) -> [String: Int]? {
        #if RADIX_CANDIDATE
        guard let storage = capacity.pagedStorage else { return nil }
        return [
            "grant_bytes": storage.grantBytes, "committed_bytes": storage.committedBytes,
            "reserved_page_bytes": storage.reservedPageBytes, "live_page_bytes": storage.livePageBytes,
            "poison_bytes": storage.poisonBytes, "slack_bytes": storage.slackBytes,
            "segment_count": storage.segmentCount, "address_pages": storage.addressPages,
            "over_grant_bytes": storage.overGrantBytes,
            "allocator_padding_bytes": storage.allocatorPaddingBytes,
            "last_allocation_allowance_bytes": storage.lastAllocationAllowanceBytes,
        ]
        #else
        return nil
        #endif
    }
}

private extension Dictionary where Key == Int, Value == Int {
    func mapKeysToStrings() -> [String: Int] {
        Dictionary<String, Int>(uniqueKeysWithValues: map { (String($0.key), $0.value) })
    }
}
