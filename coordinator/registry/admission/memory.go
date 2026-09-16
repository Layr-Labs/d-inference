package admission

// modelMemoryHeadroomFactor is the FALLBACK multiple of the on-disk weight size
// used to estimate a model's resident footprint ONLY when the catalog has no
// authoritative min_ram_gb. Prefer min_ram_gb (see ModelFitsHardware): a
// synthetic multiple of the raw weight does not match what the operator
// published or what the provider actually loads, and at 2.x it wrongly rejected
// catalog-qualified nodes (e.g. gpt-oss-20b min_ram_gb=24 vs 12.1*2.x>24, and
// gemma-4-26b min_ram_gb=36 vs 28*2.x rejecting the whole 64 GB tier).
const modelMemoryHeadroomFactor = 2.0

// ModelFitsHardware reports whether a model can run on a node with the given
// total unified memory (GB). It prefers the catalog's authoritative min_ram_gb
// (the operator-published requirement) and only falls back to a heuristic
// multiple of the on-disk weight size when min_ram_gb is unknown. Fails OPEN
// when nothing is known. The provider still performs the final precise check at
// load time; this gate only filters models that clearly cannot fit per the
// catalog's own contract.
func ModelFitsHardware(minRAMGb int, modelSizeGB, totalMemoryGB float64) bool {
	if totalMemoryGB <= 0 {
		return true
	}
	if minRAMGb > 0 {
		return float64(minRAMGb) <= totalMemoryGB
	}
	if modelSizeGB > 0 {
		return modelSizeGB*modelMemoryHeadroomFactor <= totalMemoryGB
	}
	return true
}

// coldLoadCatalogGBToMemGiB converts a model's catalog on-disk size (decimal GB,
// TotalSizeBytes/1e9, unpadded) into the provider's load-gate basis (padded GiB).
// The provider's ModelLoadAdmission.canLoad weighs estimatedMemoryGb = on-disk
// bytes × 1.2 (scanner memory-overhead) / 2^30, and free_for_load_gb is reported
// in that same padded-GiB basis. So a raw catalog size must be padded+converted
// the same way before comparing, or a near-threshold model whose RAW size fits
// but whose PADDED estimate doesn't would be admitted here and then 503'd at load
// (Codex #390). 1.2 mirrors the provider scanner's overhead factor; (1e9/2^30)
// converts decimal GB → GiB. Conservative: if the scanner's factor ever drops,
// this stays safe (slightly stricter); it must not be set BELOW the provider's.
const coldLoadCatalogGBToMemGiB = 1.2 * (1e9 / float64(int64(1)<<30)) // ≈ 1.1176

// ReportedFreeForLoadAdmits reports whether a cold load of a model with the given
// catalog size (decimal GB) fits the provider's reported free_for_load_gb (max
// loadable model weight, padded GiB — the provider's authoritative gate). The
// second return is whether the provider reported the value at all; false means
// the caller should fall back to its static hardware heuristic (legacy provider,
// or unknown catalog size that can't be normalized). Used by every cold-load
// decision path (direct admission, the swap planner, the warm pool, and the
// cold-spill predicate) so they cannot drift.
// The PADDED conversion on purpose, for every binary and model: this
// mirrors the provider's ADMIT gate, which deliberately charges the
// disk×1.2 load-transient figure (shard staging exceeds steady residency).
// Measured post-load residency (servabilityMeasuredResidentGiB) informs
// only ColdTokenBudgetEstimate — the POST-load arithmetic.
func ReportedFreeForLoadAdmits(catalogSizeGB float64, freeForLoadGB *float64) (admit bool, reported bool) {
	if freeForLoadGB == nil || catalogSizeGB <= 0 {
		return false, false
	}
	return catalogSizeGB*coldLoadCatalogGBToMemGiB <= *freeForLoadGB, true
}

// FreeMemoryAdmits returns true when the provider has enough headroom.
// Providers that report a token budget use budget-based admission;
// legacy providers fall back to memory-based estimation.
func (p Policy) FreeMemoryAdmits(snap *Snapshot, reqPromptTokens, reqMaxTokens int) bool {
	// Gray-box budget clamp: a capacity-503 proved the provider's live gate
	// rejects while the heartbeat budget below still advertises headroom
	// (stale-optimistic). While the clamp holds, the slot is FULL — no
	// request fits — until the provider proves recovery (fresh heartbeat with
	// headroom + an accept) or the clamp TTL fail-opens. Checked BEFORE the
	// budget branch: a clamped budget-reporting pair whose current session
	// has no budget snapshot yet (reconnect before the first heartbeat) must
	// reject here, not fall through to the legacy memory path below. See
	// faultstate/budget_clamp.go.
	if snap.BudgetClamped {
		return false
	}
	requestTokens := int64(reqPromptTokens) + int64(reqMaxTokens)
	// Engine V2 keeps reporting a positive KV rate when its live fleet clamp
	// drives this model's budget to zero. That is authoritative known-full
	// capacity, not the legacy "budget unavailable" shape (both fields absent).
	// Bind it before consulting co-resident pooled headroom: another model's
	// positive budget cannot widen this model-local zero.
	if KnownZeroTokenBudget(snap.ActiveTokenBudgetMax, snap.KVBytesPerToken) {
		return false
	}
	if snap.ActiveTokenBudgetMax > 0 {
		// Include coordinator-side pending tokens not yet reflected in the
		// provider's heartbeat. Avoid double-counting active/queued backend
		// budgets that are still present in the coordinator pending set until
		// completion/cancellation removes them.
		coordinatorExtra := int64(snap.PendingMaxTokens) - CommittedTokenBudget(snap)
		if coordinatorExtra < 0 {
			coordinatorExtra = 0
		}
		if snap.ActiveTokenBudgetUsed+snap.QueuedTokenBudget+coordinatorExtra+requestTokens > snap.ActiveTokenBudgetMax {
			return false
		}
		// The per-slot max encodes this model's own context/KV ceiling. Through
		// v0.7.4 each slot embeds the same shared headroom; v0.7.5+ reports a
		// private re-sliced grant. The request must also fit the correctly
		// reconstructed whole-box pool with EVERY model's
		// coordinator-pending tokens charged — byte-normalized per slot KV rate
		// when reported, since co-resident models spend the pool at different
		// bytes/token (see pool.go). Reduces exactly to the per-slot
		// check for single-model providers.
		return PoolAdmits(snap, requestTokens)
	}

	// Cold-slot pooled gate: this model reports no budget slot (not loaded
	// here), but when ANY resident slot reports a token budget this request lands
	// in the same box after load. In-gap pending on a resident model must not be double-spendable
	// by a cold request that skips the budget branch above. The reconstructed
	// pool charges all-models coordinator pending plus this request; a cold
	// model has no reported KV rate (snap.kvBytesPerToken == 0), so on a
	// byte-reconstructable pool it is priced conservatively in bytes at the
	// bounded unknown-model default (ResolvedKVBytesPerToken),
	// falling to token units only when the pool is not byte-reconstructable.
	// No-op for legacy providers with neither budget nor KV-rate reports.
	if !PoolAdmits(snap, requestTokens) {
		return false
	}

	if !snap.ModelLoaded {
		if fits, known := p.ProviderBudgetFits(snap, reqPromptTokens, reqMaxTokens); known && !fits {
			return false
		}
	}

	if snap.ModelSizeGB <= 0 || snap.TotalMemoryGB <= 0 {
		return true
	}
	required := snap.ModelSizeGB
	if snap.ModelLoaded {
		required = 0
	}
	tokens := int64(reqPromptTokens) + int64(reqMaxTokens)
	if tokens < 0 {
		tokens = 0
	}
	const maxTokensForCalc = 16 << 20
	if tokens > maxTokensForCalc {
		tokens = maxTokensForCalc
	}
	kvCacheGB := float64(tokens*DefaultKVBytesPerToken) / float64(BytesPerGiB)
	required += kvCacheGB

	// When the model is available on disk but not currently loaded, the
	// provider will evict idle models to make room (LRU eviction), so we check
	// whether the model can be loaded rather than requiring it to fit alongside
	// existing loaded models. The provider handles the swap autonomously.
	//
	// However, if the provider has in-flight requests (totalPending > 0), it
	// cannot evict the currently-serving model. In that case, fall through to the
	// standard free-memory check which requires room alongside active models.
	if snap.AvailableOnDisk && !snap.ModelLoaded && snap.TotalPending == 0 {
		// Preferred: the provider reports freeForLoadGB — the max model WEIGHT it
		// can load right now, already net of the 90% unified cap, OS/operator
		// reserve, activation+min-KV headroom, real OS-available memory, and
		// eviction of idle models. The single source of truth, normalized to the
		// provider's padded-GiB load basis so it exactly mirrors the provider's own
		// ModelLoadAdmission gate (no over-admit → OOM, no under-admit on evictable
		// weights).
		if admit, reported := ReportedFreeForLoadAdmits(snap.ModelSizeGB, snap.FreeForLoadGB); reported {
			return admit
		}
		// Fallback for legacy providers that don't report freeForLoadGB: the old
		// total-memory heuristic (provider evicts idle models, so compare against
		// total rather than free). Coarser — can't see the unified cap or OS
		// baseline — but only used until the fleet reports the field.
		const osReserveGB = 4.0
		return snap.ModelSizeGB+kvCacheGB+osReserveGB <= snap.TotalMemoryGB
	}

	free := snap.TotalMemoryGB - snap.GPUMemoryActiveGB
	return free >= required
}

func CommittedTokenBudget(snap *Snapshot) int64 {
	committed := snap.ActiveTokenBudgetUsed + snap.QueuedTokenBudget
	if snap.MaxTokensPotential > committed {
		committed = snap.MaxTokensPotential
	}
	if committed < 0 {
		return 0
	}
	return committed
}
