package registry

// gate_reason.go — closed vocabularies for the routing-context record
// (system profiler, slice 1). Everything here is a fixed-size value type so the
// routing hot path can tally and copy it under r.mu with ZERO heap allocations
// (hot-path review C5). JSON encoding of these values happens later, in the
// api layer, never under the registry lock.

import (
	"regexp"
	"strings"
)

// GateReason is the closed enum of reasons a provider is dropped from a
// request's routing candidate set. The order is the tally index into
// RoutingDecision.GateRejections / candidateScan.gateRejections and must never
// be reordered once persisted rows exist; append new reasons BEFORE
// GateReasonCount. String() returns the snake_case name used as the JSON key of
// the persisted gate_rejections object.
type GateReason uint8

const (
	GateOffline GateReason = iota
	GateUntrusted
	GateTrustFloor
	GatePrivateOnly
	GateRuntimeUnverified
	GatePrivateText
	GateChallengeStale
	GateTraitFloor
	GateDedicated
	GateDispatchLoadCooldown
	GateErrorCooldown
	GateCapacityCooldown
	GateBreaker
	GateEjection
	GateSlotCrashed
	GateSlotReloading
	GateThermalCritical
	GateNoHeadroom
	GateModelTooLarge
	GateFreeMemory
	GateVision
	GateTTFTCeiling
	GateExcluded
	GateAllowlist
	GateNotServingModel
	// GateReasonCount is the number of reasons; it sizes the tally arrays and
	// is not itself a reason.
	GateReasonCount
)

// gateReasonNames is indexed by GateReason. Keep in lock-step with the const
// block above (TestGateReasonNamesComplete enforces it).
var gateReasonNames = [GateReasonCount]string{
	GateOffline:              "offline",
	GateUntrusted:            "untrusted",
	GateTrustFloor:           "trust_floor",
	GatePrivateOnly:          "private_only",
	GateRuntimeUnverified:    "runtime_unverified",
	GatePrivateText:          "private_text",
	GateChallengeStale:       "challenge_stale",
	GateTraitFloor:           "trait_floor",
	GateDedicated:            "dedicated",
	GateDispatchLoadCooldown: "dispatch_load_cooldown",
	GateErrorCooldown:        "error_cooldown",
	GateCapacityCooldown:     "capacity_cooldown",
	GateBreaker:              "breaker",
	GateEjection:             "ejection",
	GateSlotCrashed:          "slot_crashed",
	GateSlotReloading:        "slot_reloading",
	GateThermalCritical:      "thermal_critical",
	GateNoHeadroom:           "no_headroom",
	GateModelTooLarge:        "model_too_large",
	GateFreeMemory:           "free_memory",
	GateVision:               "vision",
	GateTTFTCeiling:          "ttft_ceiling",
	GateExcluded:             "excluded",
	GateAllowlist:            "allowlist",
	GateNotServingModel:      "not_serving_model",
}

// String returns the snake_case name of the reason ("unknown" for an
// out-of-range value, which cannot happen for values produced by this package).
func (g GateReason) String() string {
	if g < GateReasonCount {
		return gateReasonNames[g]
	}
	return "unknown"
}

// EligibilityReasonEligible is the FleetSnapshotRow.EligibilityReason value for
// a (provider, slot) that passes every routing gate for a plain text probe.
const EligibilityReasonEligible = "eligible"

// SelectionPath records which branch of selectRoutingCandidate produced the
// winner. Closed enum; String() is the persisted name.
type SelectionPath uint8

const (
	// SelectionNone: no winner (empty pool).
	SelectionNone SelectionPath = iota
	// SelectionUniqueMin: exactly one candidate inside the near-tie window of
	// the minimum cost.
	SelectionUniqueMin
	// SelectionTieQueue: several near-ties; the lowest effectiveQueue won.
	SelectionTieQueue
	// SelectionTiePending: several near-ties with equal effectiveQueue; the
	// lowest totalPending won.
	SelectionTiePending
	// SelectionCacheTiebreak: several queue/pending-equivalent candidates and a
	// bounded exact-cache discount resolved the tie by adjusted cost.
	SelectionCacheTiebreak
	// SelectionRandom: several queue/pending-equivalent candidates (and no
	// decisive cache discount); one was chosen uniformly at random.
	SelectionRandom
	selectionPathCount
)

var selectionPathNames = [selectionPathCount]string{
	SelectionNone:          "none",
	SelectionUniqueMin:     "unique_min",
	SelectionTieQueue:      "tie_queue",
	SelectionTiePending:    "tie_pending",
	SelectionCacheTiebreak: "cache_tiebreak",
	SelectionRandom:        "random",
}

// String returns the snake_case name of the path.
func (s SelectionPath) String() string {
	if s < selectionPathCount {
		return selectionPathNames[s]
	}
	return "unknown"
}

// SlotState is the closed, coordinator-owned vocabulary for a provider slot's
// state. Provider-reported strings (BackendSlotCapacity.State) are FOLDED onto
// it via SlotStateFold and never copied verbatim into a persisted record or a
// metric tag: the provider string is untrusted free text on the wire.
type SlotState string

const (
	SlotStateRunning      SlotState = "running"
	SlotStateIdle         SlotState = "idle"
	SlotStateIdleShutdown SlotState = "idle_shutdown"
	SlotStateCrashed      SlotState = "crashed"
	SlotStateReloading    SlotState = "reloading"
	// SlotStateOther covers every other value, including the coordinator's own
	// "unknown" (model advertised but no resident slot — a cold candidate) and
	// the empty string. A cold candidate is still distinguishable in the
	// routing record by its non-zero StateMs term.
	SlotStateOther SlotState = "other"
)

// SlotStateFold maps a raw provider-reported slot state onto the closed
// SlotState vocabulary. It never returns the input string itself.
func SlotStateFold(raw string) SlotState {
	switch raw {
	case "running":
		return SlotStateRunning
	case "idle":
		return SlotStateIdle
	case "idle_shutdown":
		return SlotStateIdleShutdown
	case "crashed":
		return SlotStateCrashed
	case "reloading":
		return SlotStateReloading
	default:
		return SlotStateOther
	}
}

// ThermalStateFold maps a raw provider-reported thermal state onto the closed
// {nominal, fair, serious, critical, other} vocabulary. Same rationale as
// SlotStateFold: the wire string is never copied verbatim into a record.
func ThermalStateFold(raw string) string {
	switch raw {
	case "nominal", "fair", "serious", "critical":
		return raw
	default:
		return "other"
	}
}

// ProviderVersionUnparseable is the sentinel ProviderVersionFold returns for a
// non-empty provider version that is not semver-shaped.
const ProviderVersionUnparseable = "invalid"

// providerVersionPattern bounds a persisted provider version: MAJOR.MINOR.PATCH
// digits with an optional short pre-release tag, at most 29 bytes in total.
var providerVersionPattern = regexp.MustCompile(`^\d{1,3}\.\d{1,3}\.\d{1,4}(-[a-z0-9.]{1,16})?$`)

// ProviderVersionFold bounds a provider-reported binary version before it is
// persisted (request_profiles.provider_version, fleet_snapshots.provider_version).
// It returns "" for an unreported version, the trimmed version itself when it
// is semver-shaped (so CompareVersions can rank it against the capability
// floors), and ProviderVersionUnparseable otherwise. Like the other folds
// here it never copies an arbitrary wire string into a record.
func ProviderVersionFold(raw string) string {
	v := strings.TrimSpace(raw)
	if v == "" {
		return ""
	}
	if providerVersionPattern.MatchString(v) {
		return v
	}
	return ProviderVersionUnparseable
}

// CandidateSummary is a fixed-size, allocation-free summary of one scanned
// routing candidate. It is filled inside the candidate scan under r.mu and
// copied by value onto RoutingDecision (Top / RunnerUp / BestIdle); the api
// layer serialises it later. No slices, maps, or pointers: ProviderID is a
// string-header copy of the immutable Provider.ID.
type CandidateSummary struct {
	ProviderID string

	CostMs, StateMs, QueueMs, PendingMs, BacklogMs, ThisReqMs, HealthMs, CapacityRateMs, CacheDiscountMs float64
	TTFTMs, EffectiveTPS                                                                                 float64

	EffectiveQueue, TotalPending, BackendRunning, BackendWaiting int32

	ActiveTokenBudgetUsed, ActiveTokenBudgetMax, QueuedPrefillTokens int64

	// SlotState is the folded (closed) slot state of the candidate's slot for
	// the requested model at snapshot time.
	SlotState SlotState
	// HBAgeMs is the age of the candidate's last heartbeat at snapshot time
	// (clamped to int32).
	HBAgeMs int32
	// Present is false for an unfilled slot (fewer candidates than the array).
	Present bool
}

// candidateSummaryOf builds the fixed-size summary of a scanned candidate.
// Allocation-free: every field is a value copy.
func candidateSummaryOf(c *routingCandidate) CandidateSummary {
	if c == nil || c.provider == nil {
		return CandidateSummary{}
	}
	bd := c.breakdown
	snap := &c.snapshot
	return CandidateSummary{
		ProviderID:            c.provider.ID,
		CostMs:                c.costMs,
		StateMs:               bd.StateMs,
		QueueMs:               bd.QueueMs,
		PendingMs:             bd.PendingMs,
		BacklogMs:             bd.BacklogMs,
		ThisReqMs:             bd.ThisReqMs,
		HealthMs:              bd.HealthMs,
		CapacityRateMs:        bd.CapacityRateMs,
		CacheDiscountMs:       bd.CacheDiscountMs,
		TTFTMs:                bd.TTFTMs,
		EffectiveTPS:          c.effectiveTPS,
		EffectiveQueue:        clampInt32(c.effectiveQueue),
		TotalPending:          clampInt32(snap.totalPending),
		BackendRunning:        clampInt32(snap.backendRunning),
		BackendWaiting:        clampInt32(snap.backendWaiting),
		ActiveTokenBudgetUsed: snap.activeTokenBudgetUsed,
		ActiveTokenBudgetMax:  snap.activeTokenBudgetMax,
		QueuedPrefillTokens:   snap.queuedPrefillTokens,
		SlotState:             SlotStateFold(snap.slotState),
		HBAgeMs:               snap.hbAgeMs,
		Present:               true,
	}
}

// clampInt32 narrows an int to int32, saturating at the bounds.
func clampInt32(v int) int32 {
	const maxI32, minI32 = int(^uint32(0) >> 1), -int(^uint32(0)>>1) - 1
	if v > maxI32 {
		return int32(maxI32)
	}
	if v < minI32 {
		return int32(minI32)
	}
	return int32(v)
}

// clampMsInt32 narrows a millisecond count (int64) to int32, saturating.
func clampMsInt32(ms int64) int32 {
	const maxI32 = int64(^uint32(0) >> 1)
	if ms > maxI32 {
		return int32(maxI32)
	}
	if ms < 0 {
		return 0
	}
	return int32(ms)
}
