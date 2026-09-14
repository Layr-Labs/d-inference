package protocol

// BackendSlotCapacity describes the capacity state of a single backend slot
// (one MLX-Swift in-process model serving one model).
type BackendSlotCapacity struct {
	Model              string `json:"model"`                     // model ID for this slot
	State              string `json:"state"`                     // "running", "idle_shutdown", "crashed", "reloading"
	NumRunning         int    `json:"num_running"`               // requests actively generating
	NumWaiting         int    `json:"num_waiting"`               // requests queued in backend scheduler
	MaxConcurrency     int    `json:"max_concurrency,omitempty"` // provider-reported concurrent request cap for this slot
	ActiveTokens       int64  `json:"active_tokens"`             // sum of (prompt_tokens + completion_tokens) across running requests
	MaxTokensPotential int64  `json:"max_tokens_potential"`      // sum of max_tokens across running requests (worst-case growth)

	ObservedDecodeTPS     float64 `json:"observed_decode_tps,omitempty"`      // EWMA of measured per-request decode TPS
	ObservedPrefillTPS    float64 `json:"observed_prefill_tps,omitempty"`     // EWMA of measured per-request prefill TPS (admission→first token); omitted when unmeasured
	ActiveTokenBudgetUsed int64   `json:"active_token_budget_used,omitempty"` // tokens reserved by active requests (prompt + max_output)
	ActiveTokenBudgetMax  int64   `json:"active_token_budget_max,omitempty"`  // maximum token budget for this slot
	QueuedTokenBudget     int64   `json:"queued_token_budget,omitempty"`      // tokens reserved by queued requests
	KVBytesPerToken       int64   `json:"kv_bytes_per_token,omitempty"`       // per-token KV cache memory cost in bytes (provider-side only)
	ModelLoadTimeMS       int64   `json:"model_load_time_ms,omitempty"`       // measured cold-start load time (ms) for the model in this slot; omitted when unmeasured

	// KVBackend names the KV-cache backend this slot's engine was actually
	// built with — the provider's `EngineV2Bridge.kvBackendKind`, i.e. the
	// RESOLVED kind after every veto and fallback, not the operator's
	// requested `engine_v2_kv_backend`. Values: "paged" | "contiguous".
	// This is the fleet's only per-slot, every-heartbeat record of the
	// v0.8.0 paged rollout; without it a mixed fleet cannot be A/B'd on
	// TTFT, decode TPS or error rate by backend, and a fleet-wide
	// regression cannot be attributed to the rollout at all.
	//
	// POINTER, deliberately. Pre-0.8.0 providers omit the key entirely and
	// nil MUST read as "unknown", never as "contiguous" — otherwise the
	// rollout dashboard books every legacy provider as a contiguous sample
	// and the comparison lies. A non-nil pointer to "" still marshals as
	// `"kv_backend":""` (omitempty tests the pointer, not the pointee), so
	// an authoritative "slot present, backend unnameable" stays distinct
	// from omission. Same idiom as FreeForLoadGB / PrefixCacheStatuses.
	//
	// MEASUREMENT ONLY — decoded for observability; routing is NOT gated on
	// it. Acting on the backend kind is a separate change.
	KVBackend *string `json:"kv_backend,omitempty"`

	// KVBackendFallbackReason says WHY this slot's engine ended up on
	// KVBackend instead of the backend it was asked for — the provider's
	// `EngineV2Factory.ProductionBuild.kvBackendFallbackReason`, verbatim:
	// "kill_switch", "kernel_preflight: …", "physical_capacity: …",
	// "ineligible: …", "pool_construction_capacity: …".
	//
	// KVBackend alone cannot answer the question the v0.8.0 rollout has to
	// ask. A slot reporting "contiguous" is either an operator who chose
	// contiguous or an operator who chose paged on a box where paged did not
	// happen — a choice and a regression, indistinguishable.
	//
	// `.auto` resolves CONTIGUOUS again as of v0.8.1 (see the provider's
	// EngineV2Factory.prepareProductionBackend), which INVERTS what a
	// populated value means: a stock slot now reports contiguous with NO
	// fallback reason, so any non-nil value identifies a box carrying an
	// explicit engine_v2_kv_backend = "paged". Every class stays decodable
	// — v0.8.0 providers are still in the fleet during rollout, and the
	// paged classes remain live on explicitly-paged boxes.
	// "kernel_preflight", "physical_capacity", "ineligible" and
	// "pool_construction_capacity" mean this box could not serve paged and
	// degraded — under v0.8.1 that combination is rare enough to alert on.
	// "kill_switch" means DARKBLOOM_CBV2_PAGED_KV=0 and is a deliberate
	// operator override that degrades rather than refuses by design. Do not
	// alert on the two the same way.
	//
	// ABSENT MEANS NO DEGRADE — deliberately the OPPOSITE of KVBackend,
	// where absent means unknown. Read the two as a pair: both keys ship in
	// v0.8.0, so a slot that named a KVBackend is running a build that also
	// names this whenever there is one. KVBackend present + this nil is an
	// authoritative "did not degrade"; only KVBackend nil is unknown. See
	// registry.KVBackendFallbackTag, which is the one place that mapping
	// lives.
	//
	// UNTRUSTED, UNBOUNDED-ISH free text. The provider caps it, but nothing
	// here may forward it to a metric tag: registry.KVBackendFallbackTag
	// folds it onto a bounded class vocabulary first.
	//
	// MEASUREMENT ONLY — decoded for observability; routing is NOT gated on
	// it, exactly like KVBackend above.
	KVBackendFallbackReason *string `json:"kv_backend_fallback_reason,omitempty"`

	// Engine-health (first-token wedge) signals — low-cardinality, NON-PRIVATE
	// diagnostics that let the coordinator SEE a wedged MLX/Metal first-token
	// path (provider emits the preamble, then the first blocking eval never
	// returns; see docs/reports/2026-06-22-cancel-root-cause-and-fix.md §C and
	// the Swift WedgeMonitor). All omitempty so legacy providers (and a
	// freshly-idle slot) keep the prior wire shape. MEASUREMENT ONLY — decoded
	// into the routing snapshot for observability; routing is NOT gated on them.
	StepsExecuted              int64   `json:"steps_executed,omitempty"`                 // cumulative EngineCore.stepsExecuted (engine-loop progress); flatlines under demand ⇒ wedge
	Admits                     int64   `json:"admits,omitempty"`                         // cumulative requests handed to the engine (preamble path)
	FirstTokensEmitted         int64   `json:"first_tokens_emitted,omitempty"`           // cumulative requests that produced a first content token
	SecondsSinceLastStep       float64 `json:"seconds_since_last_step,omitempty"`        // seconds since the step counter last advanced (large under demand ⇒ frozen loop)
	SecondsSinceLastFirstToken float64 `json:"seconds_since_last_first_token,omitempty"` // seconds since the last first content token (0 = none yet this load)
	WedgeSuspected             bool    `json:"wedge_suspected,omitempty"`                // provider-computed: ≥N consecutive admits, 0 first-tokens, ≥T seconds
	EvalInFlightMs             int64   `json:"eval_in_flight_ms,omitempty"`              // ms the current blocking eval has run (process-global, evalLock); seconds-range = wedge smoking gun
	IdleClearInFlightMs        int64   `json:"idle_clear_in_flight_ms,omitempty"`        // ms the current idle GPU drain+clearCache has run for this slot; seconds-range = clearCache/IOKit race

	// Telemetry is the system-profiler per-slot sub-object (nil on providers
	// that predate it; presence is the "new provider" sentinel). Pointer so
	// omission and an empty object stay distinct. Clamped by
	// registry.clampBackendCapacity, cloned by canonicalHeartbeatModelState.
	// MEASUREMENT ONLY — routing is NOT gated on it.
	Telemetry    *SlotTelemetry         `json:"telemetry,omitempty"`
	PrefixCache  *PrefixCacheTelemetry  `json:"prefix_cache,omitempty"`
	PagedStorage *PagedStorageTelemetry `json:"paged_storage,omitempty"`
}

// MLXCacheReclaimerTelemetry reports cumulative provider allocator-reclaim
// counters. Values reset on provider process restart. Reclaimed byte deltas are
// best-effort observations around MLX clearCache; active allocations are never
// included.
type MLXCacheReclaimerTelemetry struct {
	CacheLimitBytes       uint64 `json:"cache_limit_bytes"`
	SweepSignals          uint64 `json:"sweep_signals"`
	Reclaims              uint64 `json:"reclaims"`
	ReclaimedBytes        uint64 `json:"reclaimed_bytes"`
	LastReclaimedBytes    uint64 `json:"last_reclaimed_bytes"`
	LastReclaimDurationMS uint64 `json:"last_reclaim_duration_ms"`
}

// BackendCapacity describes the aggregate capacity across all backend slots
// on a provider. Reported in heartbeats so the coordinator can make informed
// routing decisions based on actual GPU utilization rather than hardcoded limits.
type BackendCapacity struct {
	Slots             []BackendSlotCapacity `json:"slots"`                // per-model slot capacity
	GPUMemoryActiveGB float64               `json:"gpu_memory_active_gb"` // Metal active memory (shared across all slots)
	GPUMemoryPeakGB   float64               `json:"gpu_memory_peak_gb"`   // Metal peak memory
	GPUMemoryCacheGB  float64               `json:"gpu_memory_cache_gb"`  // Metal cache memory (reclaimable)
	TotalMemoryGB     float64               `json:"total_memory_gb"`      // total system/GPU memory
	// FreeForLoadGB is the max additional model-WEIGHT footprint (GB) the
	// provider can load right now: net of the 90% unified-memory cap, OS/operator
	// reserve, and activation+min-KV load headroom, clamped to real OS-available
	// memory, and treating idle resident models as evictable. It is the single
	// source of truth for cold-load admission (the coordinator no longer
	// re-derives free memory). A pointer so a legacy provider that doesn't report
	// it is nil (→ coordinator falls back to the total-memory heuristic).
	FreeForLoadGB *float64 `json:"free_for_load_gb,omitempty"`
	// MLXCacheReclaimer is nil for providers predating allocator telemetry.
	MLXCacheReclaimer *MLXCacheReclaimerTelemetry `json:"mlx_cache_reclaimer,omitempty"`
	// CapacitySeq is a per-connection monotonically increasing sequence number
	// stamped on every capacity snapshot the provider publishes. The
	// coordinator applies snapshots by seq (stale/reordered seq → discard) so
	// event-triggered heartbeats can't regress the ledger, and a connection
	// that has reported any seq > 0 is thereby quote-capable
	// (capacity_probe/capacity_quote). Zero means a legacy provider: the field
	// is omitted from the wire and the coordinator keeps last-write-wins
	// heartbeat semantics.
	CapacitySeq uint64 `json:"capacity_seq,omitempty"`
	// Telemetry is the system-profiler machine-level sub-object (nil on
	// providers that predate it). Same rules as BackendSlotCapacity.Telemetry.
	Telemetry              *CapacityTelemetry               `json:"telemetry,omitempty"`
	PrefixCacheMaintenance *PrefixCacheMaintenanceTelemetry `json:"prefix_cache_maintenance,omitempty"`
}
