package registry

import (
	"context"
	"log/slog"
	"math"
	"math/rand"
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

const (
	// Coordinator-side defaults for request sizing. These are only used for
	// routing heuristics and queue admission, not billing or protocol limits.
	defaultRequestedMaxTokens = 256

	slotStatePenaltyRunning      = 0.0
	slotStatePenaltyUnknown      = 30_000.0
	slotStatePenaltyIdleShutdown = 20_000.0

	// Penalty constants. Phase 3 raised queueDepthPenaltyMs (1000→3000),
	// totalPendingPenaltyMs (250→750), and nearTieCostWindowMs (750→2500).
	// The old values let a fast provider with 1-2 in-flight requests
	// outscore an idle slow provider, because the per-request decode-cost
	// gap (~3-10 s) dwarfed the queue penalty (~1 s/request). The new
	// values make one queued request roughly equivalent to one
	// slow-provider decode, so the cost function actually spreads load
	// across the fleet. Wider tie window admits more candidates to the
	// queue-depth tie-break + random distribution.
	queueDepthPenaltyMs      = 3_000.0
	totalPendingPenaltyMs    = 750.0
	memoryPressurePenaltyMs  = 4_000.0
	cpuUsagePenaltyMs        = 1_500.0
	gpuUtilizationPenaltyMs  = 5_000.0
	thermalPenaltyFairMs     = 2_000.0
	thermalPenaltySeriousMs  = 8_000.0
	nearTieCostWindowMs      = 3_000.0
	challengeFreshnessMaxAge = 16 * time.Minute

	// kvCacheBytesPerToken is a per-token KV-cache size estimate used by
	// the free-memory admission gate.
	//
	// Measured on M4 Max (Qwen2.5-7B-4bit, prompt≈2330 + completion≈72):
	// 357,615 bytes/token (0.34 MB). Prior default of 0.5 MB was ~47%
	// too conservative — providers were being rejected for "no fit"
	// when they actually had room. Rounded up slightly to 400,000 to
	// leave headroom for larger models (70B class may be ~2x) without
	// re-running the gate per architecture. Refine per-model via
	// catalog metadata once more measurements exist.
	kvCacheBytesPerToken = 400_000 // ~0.38 MB; covers 7-8B with slack
	bytesPerGB           = 1 << 30

	// effectiveTPSLoadFactor controls how aggressively decode TPS
	// degrades as a provider takes on more concurrent requests. The
	// effective TPS used in cost is `decodeTPS / (1 + k * batchSize)`
	// where batchSize is the backend's currently-running request count.
	//
	// Measured on M4 Max against the CBv2 engine and a model this
	// coordinator actually serves — gemma-4-26b-qat-4bit, per-request
	// decode at B = 1/2/4/8 = 101.8 / 59.6 / 38.0 / 24.7 (v2 rows of
	// libs/mlx-swift-lm/benchmarks/reports/gemma4-26b-qat4bit-paged-gate-2026-07-09.md).
	// Method: median of the implied k over B = 2/4/8, solo pinned to the
	// B=1 measurement — 0.354 / 0.420 / 0.390 -> 0.39. A least-squares fit
	// of 1/rate against B agrees (0.3895). The SAME method reproduces the
	// previous 0.27 exactly from the legacy rows (Qwen2.5-7B-4bit on the
	// legacy engine: 92.8 / 69.5 / 35.9 / 29.6 -> 0.2669), so this is a
	// change of engine and model, not of method. Cross-checks: gemma
	// v2-paged 0.388, v2-compiled 0.419; gpt-oss-20b v2-eager 0.432,
	// v2-paged 0.325.
	//
	// 0.27 errs in the LENIENT direction against CBv2 — it UNDER-predicts
	// degradation, i.e. over-predicts the surviving rate, and the error
	// grows with batch:
	//
	//	B    measured    k=0.27 pred       k=0.39 pred
	//	2    59.6        66.1   (+10.9%)   57.2   (-4.1%)
	//	4    38.0        48.9   (+28.8%)   39.8   (+4.6%)
	//	8    24.7        32.2   (+30.4%)   24.7   (-0.0%)
	//	                 MAPE 23.4%        MAPE 2.9%
	//
	// B=1 is the model's INPUT (solo), not a prediction, so it is not
	// scored. Mind the SIGN: 0.27 is too SMALL, not too large. A reading
	// that it was wildly "too aggressive" comes from comparing a
	// prediction made with the coordinator's sqrt(memory_bandwidth) proxy
	// solo (16-28 tok/s) against a rate measured at the engine's real solo
	// (101.8) — that gap is a bad SOLO rate, not a bad k, and it has its
	// own lever (modelSoloTPSSeedEnv in concurrency_cap.go). Raising k
	// makes every derived cap TIGHTER, never looser.
	//
	// Four systems consume this and a too-small k over-states the quality
	// batch in all of them at once: the admission cap (concurrency_cap.go),
	// effectiveDecodeTPS and projectedPerRequestDecodeTPSAtBatch below, and
	// the warm-pool target (warm_pool_controller.go) — which then
	// under-warms the pool while admission packs batches that miss the
	// decode floor.
	// Set to 0 to disable load scaling.
	effectiveTPSLoadFactor = 0.39
)

type routingSnapshot struct {
	provider   *Provider
	model      string
	chipFamily string // hardware chip family (e.g. "M3"); keys the TTFT calibrator
	// binaryVersion is the provider's reported binary version (p.Version, read
	// under p.mu at snapshot time; empty = unreported/legacy). Feeds the
	// version-gated activation-reserve selection in the cold servability
	// estimate (servabilityActivationFloor) so a mixed-version fleet
	// is charged the reserve each binary actually holds.
	binaryVersion    string
	slotState        string
	hasHeadroom      bool
	totalPending     int
	pendingForModel  int
	pendingMaxTokens int
	// pendingMaxTokensAllModels is pendingMaxTokens WITHOUT the model filter:
	// the token budgets of every coordinator-pending request on this provider,
	// any model. Feeds the pooled-budget admission check (pooledBudgetAdmits)
	// so co-resident models cannot double-spend shared legacy headroom and do
	// not lose additive private-grant capacity on v0.7.5+ providers.
	pendingMaxTokensAllModels int
	// pendingMaxBytesAllModels is the byte-normalized analog: each pending
	// request's token budget × its model's reported KVBytesPerToken. Valid
	// only when pendingBytesKnown. A cold request without a reported model rate
	// is charged at the bounded conservative default (see
	// fillSnapshotPendingAndPool), so it cannot disable byte accounting for a
	// reconstructable pool. Co-resident models have different per-token byte
	// rates, so tokens are not a common unit across models (pooled_admission.go).
	pendingMaxBytesAllModels int64
	pendingBytesKnown        bool
	backendRunning           int
	backendWaiting           int
	maxTokensPotential       int64
	decodeTPS                float64
	prefillTPS               float64
	systemMetrics            protocol.SystemMetrics
	gpuMemoryActiveGB        float64
	totalMemoryGB            float64
	// freeForLoadGB is the provider-reported max additional model-weight (GB) it
	// can load right now (net of cap/reserve/headroom, idle models reclaimed).
	// When non-nil it is the authoritative cold-load gate; nil = legacy provider
	// (fall back to the total-memory heuristic). See protocol.BackendCapacity.
	freeForLoadGB   *float64
	modelSizeGB     float64 // catalog-reported weight footprint (0 = unknown, gate disabled)
	minRAMGb        int     // catalog authoritative min RAM (GB) to run the model (0 = unknown)
	modelLoaded     bool    // true when the requested model is resident (running or idle)
	availableOnDisk bool    // model is in provider's Models list but not currently loaded

	observedDecodeTPS     float64
	observedPrefillTPS    float64 // measured per-slot prefill EWMA; 0 = unreported (fall back to prefillTPS chain)
	activeTokenBudgetUsed int64
	activeTokenBudgetMax  int64
	queuedTokenBudget     int64
	// pooledTokenBudget is the provider's reconstructed whole-box token budget
	// (all budget slots; layout selected from the provider release version).
	// Zero value when the provider reports no backend capacity / no budget
	// slots, which disables the pooled admission check.
	pooledTokenBudget pooledTokenBudget
	// budgetClamped means the gray-box budget clamp (budget_clamp.go) is
	// active for this (provider, model) pair: a capacity-shaped 503 proved the
	// provider's LIVE admission gate is rejecting, so the heartbeat budget
	// above is stale-optimistic and admission must treat the slot as FULL
	// (freeMemoryAdmits rejects; providerBudgetFits reports zero live
	// headroom). The budget fields themselves stay RAW — cost/backlog math,
	// the structural servability ceiling (snapshotStructuralBudget), and
	// telemetry keep reading the provider-reported truth. Only set when the
	// slot reports a token budget (activeTokenBudgetMax > 0).
	budgetClamped bool
	// kvBytesPerToken is the provider-reported per-token KV-cache cost (bytes)
	// for THIS model's slot (BackendSlotCapacity.KVBytesPerToken). 0 = unreported
	// (callers fall back to the kvCacheBytesPerToken default). Used by the
	// servability predictor to estimate a cold provider's post-load token budget
	// the same way the provider does, instead of the fixed default.
	kvBytesPerToken    int64
	fleetMedianTPS     float64
	hasBackendCapacity bool // provider reports BackendCapacity; TTFT estimates are reliable

	// Engine-health (first-token wedge) signals, decoded from the slot's
	// BackendSlotCapacity (see docs/reports/2026-06-22-cancel-root-cause-and-fix.md
	// §C). MEASUREMENT ONLY: surfaced here so routing/observability code can read
	// a wedge ("admits climbing, first-tokens flat, steps frozen") — this PR does
	// NOT gate any routing decision on them. 0/false for legacy providers.
	stepsExecuted              int64
	admits                     int64
	firstTokensEmitted         int64
	secondsSinceLastStep       float64
	secondsSinceLastFirstToken float64
	wedgeSuspected             bool
	evalInFlightMs             int64
	idleClearInFlightMs        int64

	// hbAgeMs is the age of p.LastHeartbeat at snapshot time (now − LastHeartbeat,
	// clamped to int32), computed from the `now` the snapshot already reads — no
	// extra clock read. It is the "how stale were the routing inputs" signal of
	// the system-profiler routing record (RoutingDecision.SnapshotAgeMs for the
	// winner, CandidateSummary.HBAgeMs for the top candidates). Observability
	// only; routing is NOT gated on it.
	hbAgeMs int32
	// queuedPrefillTokens is the slot's provider-reported Σ prompt tokens of
	// requests whose engine submit has not returned (slice-2 SlotTelemetry
	// producer). 0 until the wire field exists: BackendSlotCapacity has no
	// telemetry sub-object at this compile point, so nothing populates it yet.
	queuedPrefillTokens int64
}

type routingCandidate struct {
	provider       *Provider
	snapshot       routingSnapshot
	costMs         float64
	effectiveQueue int
	breakdown      costBreakdown
	effectiveTPS   float64 // Phase 4 load-scaled TPS used in this candidate's cost
	// capacityRejectRate is the pair's windowed capacity-503 rate
	// (capacity_rate.go), captured at candidate build so the winning
	// RoutingDecision can expose it. 0 when no rejects are in the window.
	capacityRejectRate        float64
	cacheTier                 string
	cacheEstimatedTTFTSavedMs float64
	// calibrationRatio is the TTFT calibration ratio this candidate was
	// scored with (recorded on the RoutingDecision for the profiler).
	calibrationRatio float64
}

// candidateRejection enumerates why a provider that passed structural
// gates (status, trust, slot state, thermal) was nonetheless excluded
// from selection. Used to populate RoutingDecision counters so callers
// can distinguish "no provider serves this model" from "every fitting
// provider is full".
type candidateRejection int

const (
	rejectNone candidateRejection = iota
	rejectCapacity
	// rejectModelTooLarge means the model's resident footprint cannot fit in
	// this provider's total memory under any load state. Unlike rejectCapacity
	// (transient "full, retry later") this is permanent for this provider, so
	// it must NOT inflate the busy/429 signal.
	rejectModelTooLarge
	// rejectVisionUnsupported means the request carries image/video input but
	// this provider only advertises a text-only build of the model. Permanent for
	// this provider (until it loads a VLM build), so like rejectModelTooLarge it
	// must NOT inflate the transient busy/429 signal.
	rejectVisionUnsupported
)

// modelMemoryHeadroomFactor is the FALLBACK multiple of the on-disk weight size
// used to estimate a model's resident footprint ONLY when the catalog has no
// authoritative min_ram_gb. Prefer min_ram_gb (see modelFitsHardware): a
// synthetic multiple of the raw weight does not match what the operator
// published or what the provider actually loads, and at 2.x it wrongly rejected
// catalog-qualified nodes (e.g. gpt-oss-20b min_ram_gb=24 vs 12.1*2.x>24, and
// gemma-4-26b min_ram_gb=36 vs 28*2.x rejecting the whole 64 GB tier).
const modelMemoryHeadroomFactor = 2.0

// modelFitsHardware reports whether a model can run on a node with the given
// total unified memory (GB). It prefers the catalog's authoritative min_ram_gb
// (the operator-published requirement) and only falls back to a heuristic
// multiple of the on-disk weight size when min_ram_gb is unknown. Fails OPEN
// when nothing is known. The provider still performs the final precise check at
// load time; this gate only filters models that clearly cannot fit per the
// catalog's own contract.
func modelFitsHardware(minRAMGb int, modelSizeGB, totalMemoryGB float64) bool {
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

// costBreakdown decomposes the routing cost so callers can log or
// expose individual contributions. The numeric values match the terms
// added in buildCandidate; total should equal costMs (modulo float
// rounding).
type costBreakdown struct {
	StateMs   float64
	QueueMs   float64
	PendingMs float64
	BacklogMs float64
	ThisReqMs float64
	HealthMs  float64
	// CapacityRateMs is the gray-box capacity-503 rate penalty
	// (capacity_rate.go): rate × EIGENINFERENCE_CAPACITY_RATE_PENALTY_MS once
	// the pair's windowed reject rate clears the threshold with a minimum
	// sample. 0 for healthy pairs, so the cost is byte-for-byte unchanged.
	CapacityRateMs float64
	TTFTMs         float64 // calibrated TTFT estimate for this candidate (gate/ceiling input)
	// RawTTFTMs is the pre-calibration ttftMsFromSnapshot value. The calibrator
	// learns against it (see ttft_calibration.go) so the feedback loop converges
	// on the absolute actual/predicted ratio instead of compounding.
	RawTTFTMs float64
	// CacheDiscountMs is subtracted only after every normal eligibility and
	// admission gate has passed. It never reduces reservations or token budgets.
	CacheDiscountMs float64
	Total           float64
}

// RoutingDecision is the public, exportable record of a routing
// selection. Returned by ReserveProviderEx so callers can emit metrics
// and structured logs without reaching into registry internals.
type RoutingDecision struct {
	ProviderID string  // winning provider, empty if no selection
	Model      string  // requested model
	CostMs     float64 // total cost of the winning candidate
	StateMs    float64 // slot-state penalty contribution
	QueueMs    float64 // pendingForModel × queueDepthPenaltyMs
	PendingMs  float64 // totalPending × totalPendingPenaltyMs
	BacklogMs  float64 // tokens-ahead / decodeTPS contribution
	ThisReqMs  float64 // this request's prefill+decode contribution
	HealthMs   float64 // memory/CPU/thermal/GPU-util contribution
	// CapacityRateMs is the gray-box capacity-503 rate penalty added to the
	// winner's cost (capacity_rate.go); 0 for healthy pairs. In-memory
	// observability only — not persisted (inference_routes has no column and
	// the schema is not altered for it).
	CapacityRateMs float64
	// CapacityRejectRate is the winner's windowed capacity-503 rate at
	// selection time (rejects / (rejects + accepts)); 0 when no rejects are in
	// the window. Same persistence note as CapacityRateMs.
	CapacityRejectRate float64
	EffectiveQueue     int // max(pendingForModel, backendRunning+backendWaiting)
	CandidateCount     int // total candidates that passed all gates
	CapacityRejections int // candidates rejected by the free-memory admission gate (transient: full)
	// ModelTooLargeRejections counts providers that serve the model but whose
	// total memory can never fit it (permanent). Kept separate from
	// CapacityRejections so callers don't emit a 429/"over capacity, retry"
	// signal for a model that will never fit anywhere of this size.
	ModelTooLargeRejections int
	// VisionRejections counts providers that serve the model but only as a
	// text-only build, when the request requires vision. Lets the caller return a
	// precise "no vision-capable provider for this model" error instead of a
	// generic capacity/queue signal.
	VisionRejections int
	// TTFTRejections counts providers that passed all other gates but exceeded
	// the per-request MaxTTFTMs ceiling. Lets the caller fail fast with a 429
	// instead of queueing or routing to a provider that misses the SLA.
	TTFTRejections int
	EffectiveTPS   float64 // load-scaled decode TPS used in cost (Phase 4)
	StaticTPS      float64 // benchmarked decode TPS before load scaling
	// BestTTFTMs is the lowest TTFT estimate seen during selection, even if it
	// exceeded MaxTTFTMs. Used to compute an accurate Retry-After when all
	// candidates are too slow.
	BestTTFTMs float64
	// TTFTMs is the estimated time-to-first-token of the selected provider
	// (CALIBRATED: raw × learned ratio). RawTTFTMs is the pre-calibration
	// ttftMsFromSnapshot value the calibrator learns against; the api layer
	// persists the two side by side.
	TTFTMs          float64
	RawTTFTMs       float64
	CacheTier       string
	CacheDiscountMs float64
	// CacheEstimatedTTFTSavedMs is the uncapped estimated prefill-time benefit
	// net of SSD stage time. CacheDiscountMs remains separately bounded by the
	// routing cost safety caps.
	CacheEstimatedTTFTSavedMs float64

	// Phase-0 shadow TTFT admission/spread evaluation (see ttft_shadow.go).
	// Populated ONLY when EIGENINFERENCE_TTFT_ADMISSION_MODE != off and a
	// provider was selected. Purely observational — it never changes the
	// selection; the API layer emits routing.ttft_admission / routing.ttft_spread
	// from these fields so the spread-to-idle opportunity and the would-shed rate
	// can be measured before any enforce flips them on.
	ShadowEvaluated             bool
	ShadowMode                  string
	ShadowWouldShed             bool
	ShadowIdleAlternativeExists bool
	ShadowEstimateMs            float64
	ShadowDeadlineMs            float64
	ShadowOccupancy             int

	// ---- System-profiler routing context (Contract B). All of the fields
	// below are filled by value from fixed-size candidateScan fields under r.mu
	// with ZERO heap allocation (hot-path review C5); the api layer copies the
	// decision into the request profile AFTER ReserveProviderEx returns and
	// serialises it on the profile sink worker, never under the registry lock.

	// Scanned is the number of providers the candidate loop visited (the whole
	// registry); CandidateSetSize is the subset not ruled out for failing to
	// advertise the model (Scanned − GateNotServingModel rejections; providers
	// skipped by the exclude/allowlist filters, which run before the catalog
	// check, are counted as advertising).
	CandidateSetSize, Scanned int
	// GateRejections tallies, per closed GateReason, the providers dropped
	// before cost ranking. Index with GateReason; GateReason.String() is the
	// persisted JSON key.
	GateRejections [GateReasonCount]uint16
	// Top is the winner (Top[0], when a winner exists) followed by the
	// lowest-cost OTHER candidates of the narrowed pool in ascending cost.
	// Present=false marks unfilled slots.
	Top [4]CandidateSummary
	// RunnerUp is the lowest-cost candidate of the narrowed pool other than
	// the winner ("what we would have chosen instead"); Present=false when the
	// pool had a single candidate.
	RunnerUp CandidateSummary
	// BestIdle is the lowest-TTFT candidate whose slot was warm (model
	// resident) with backendRunning+backendWaiting == 0, computed
	// unconditionally over every candidate that passed the routing gates
	// (before pool narrowing). Present=false when no such candidate existed.
	BestIdle CandidateSummary
	// NearTiePoolSize is the number of candidates inside the near-tie cost
	// window of the minimum; SelectionPath says which branch chose the winner.
	NearTiePoolSize int
	SelectionPath   SelectionPath
	// SnapshotAgeMs is the winner's heartbeat age (now − LastHeartbeat) at the
	// moment its routing snapshot was taken.
	SnapshotAgeMs int
	// PredictedDecodeTPS is projectedPerRequestDecodeTPS(winner snapshot): the
	// per-request decode rate this request is predicted to receive once admitted.
	PredictedDecodeTPS float64
	// PendingForModel / TotalPending are the winner's coordinator-side pending
	// counts (this model / all models) at snapshot time, before this reservation.
	PendingForModel, TotalPending int
	// LockWaitUS / ScanUS / AdmitUS are the three phases of ReserveProviderEx:
	// waiting for r.mu, the candidate scan + selection (+ shadow evaluation),
	// and the admit re-check under p.mu. Microseconds.
	LockWaitUS, ScanUS, AdmitUS int64
	// TTFTCalibrationRatio is the ratio the TTFT calibrator applied to the
	// winner's (model, chip) raw estimate (1.0 = uncalibrated or kill switch off).
	// PrefillDecodeRatio is the decode→prefill fallback multiplier in effect.
	TTFTCalibrationRatio, PrefillDecodeRatio float64
	// Queue path only (filled by the drain from the QueuedRequest): position in
	// the model queue at enqueue (0 = head), queue depth at enqueue (before the
	// append), and the bounded trigger that ran the drain which reserved it.
	QueuePosition, QueueDepth int
	DrainTrigger              string
}

// ReserveProvider selects a hardware-routable provider for the request and
// atomically reserves capacity by registering the request in the provider's
// pending set before returning.
func (r *Registry) ReserveProvider(model string, pr *PendingRequest, excludeIDs ...string) *Provider {
	p, _ := r.ReserveProviderEx(model, pr, excludeIDs...)
	return p
}

// ReserveProviderEx is the metrics-aware variant of ReserveProvider. It
// returns the same Provider plus a RoutingDecision describing the cost
// breakdown of the winning candidate (or, on selection failure, an
// empty decision with CandidateCount=0). Callers wire the decision into
// Prometheus counters/histograms without the registry needing to import
// the metrics package.
func (r *Registry) ReserveProviderEx(model string, pr *PendingRequest, excludeIDs ...string) (*Provider, RoutingDecision) {
	p, decision, _ := r.reserveProvider(model, pr, false, excludeIDs...)
	return p, decision
}

type reservationCommitOutcome uint8

const (
	reservationCommitted reservationCommitOutcome = iota
	reservationNeedsRescan
	reservationCandidateRejected
	reservationDeadlineExpired
)

type providerReservationScan struct {
	selected     *routingCandidate
	candidates   candidateScan
	cacheTracker *cacheRoutingTracker
	cacheMode    string
	// Profiler stamps for the decision: time waiting for the scan RLock and
	// the scan+selection itself, in microseconds.
	lockWaitUS int64
	scanUS     int64
}

// reserveProvider is the single selection+reservation implementation behind
// ReserveProviderEx and ReserveProviderWithPlan (dispatch_plan.go). wantPlan
// additionally retains a bounded DispatchPlan of provisional alternates drawn
// from the SAME scan that picked the winner — the plan is a byproduct of the
// one existing pass, never a second scan — and is nil whenever no provider is
// reserved. Selection and reservation are identical in both modes;
// wantPlan=false skips plan construction entirely so legacy callers pay nothing.
//
// In-flight token-budget ledger: the reservation itself IS the debit. Expensive
// fleet scans share r.mu for reading; the winner is then re-snapshotted and
// committed inside a short r.mu WRITE section. addPendingLocked records the
// request before that section ends, so every later commit sees the debit through
// fillSnapshotPendingAndPool and freeMemoryAdmits (including the reconstructed
// whole-box pool) before it can reserve. Concurrent scans therefore do not
// double-spend reported headroom across models. Heartbeat re-sync remains safe:
// coordinatorExtra subtracts committedTokenBudget, so the coordinator-side
// charge shrinks as the provider begins reporting the admitted work. Completion
// and cancel credit through RemovePending; disconnect drops the whole pending
// set; the budget clamp remains the stale-optimistic backstop.
//
// The two-phase boundary preserves the canonical r.mu → p.mu order. A changed
// ranking or cache configuration requests a fresh shared scan. A candidate that
// became ineligible is excluded from this request's later scans, so reservation
// keeps progressing through untried providers until the scan truthfully finds
// none. The request-absolute first-content clock bounds the loop.
func (r *Registry) reserveProvider(model string, pr *PendingRequest, wantPlan bool, excludeIDs ...string) (*Provider, RoutingDecision, *DispatchPlan) {
	if pr == nil || pr.RequestID == "" {
		return nil, RoutingDecision{Model: model}, nil
	}
	if pr.Model == "" {
		pr.Model = model
	}
	if pr.RequestedMaxTokens <= 0 {
		pr.RequestedMaxTokens = defaultRequestedMaxTokens
	}

	excluded := append([]string(nil), excludeIDs...)
	carried := RoutingDecision{Model: model}
	var last providerReservationScan
	var admitUS int64
	failedDecision := func() RoutingDecision {
		decision := routingDecisionForFailedScan(model, last.candidates)
		addRoutingRejections(&decision, carried)
		decision.LockWaitUS, decision.ScanUS, decision.AdmitUS = last.lockWaitUS, last.scanUS, admitUS
		return decision
	}
	for pr.RefreshFirstContentBudget(time.Now()) {
		last = r.scanProviderReservation(model, pr, excluded...)
		if last.selected == nil {
			return nil, failedDecision(), nil
		}

		// AdmitUS covers the commit phase: the write-lock wait plus the
		// current-state re-check and the pending debit.
		tCommitStart := time.Now()
		provider, candidate, outcome, rejected := r.commitProviderReservation(
			model, pr, last, excluded...)
		admitUS = time.Since(tCommitStart).Microseconds()
		switch outcome {
		case reservationNeedsRescan:
			continue
		case reservationCandidateRejected:
			addRoutingRejections(&carried, rejected)
			excluded = append(excluded, last.selected.provider.ID)
			continue
		case reservationDeadlineExpired:
			return nil, failedDecision(), nil
		case reservationCommitted:
			decision := routingDecisionForCandidate(
				model, provider, candidate, last.candidates)
			addRoutingRejections(&decision, carried)
			decision.LockWaitUS, decision.ScanUS, decision.AdmitUS = last.lockWaitUS, last.scanUS, admitUS
			r.currentTTFTShadow(
				model, pr, candidate, excluded...).applyTo(&decision)
			var plan *DispatchPlan
			if wantPlan {
				// The scan pool is immutable value snapshots plus provider
				// identities. Plan consumption revalidates both before use.
				plan = newDispatchPlan(model, last.candidates, last.selected)
			}
			return provider, decision, plan
		}
	}

	return nil, failedDecision(), nil
}

// scanProviderReservation performs the expensive fleet walk under a shared
// registry lock. Concurrent requests may scan together; no provider capacity is
// consumed until commitProviderReservation acquires the short write section and
// revalidates the winner against current cross-model pending debits.
func (r *Registry) scanProviderReservation(model string, pr *PendingRequest, excludeIDs ...string) providerReservationScan {
	// Profiler stamps: scan-lock wait (from here to the scan RLock) and the
	// scan itself land on the decision as LockWaitUS / ScanUS; ~25 ns each.
	tScanStart := time.Now()
	// Snapshot receipt-confirmed cache hints before taking the registry scan lock.
	// The tracker has its own mutex and must never be nested under r.mu.
	r.mu.RLock()
	cacheTracker, cacheMode := r.cacheRouting, r.cacheRoutingMode
	cacheRouteKey := append([]byte(nil), r.cacheRouteKeys.route...)
	r.mu.RUnlock()
	cacheCapabilities := r.prefixCacheV2CapabilitiesForModel(model)
	pr.cacheRoutingHints = nil
	if cacheTracker != nil {
		pr.cacheRoutingHints = cacheTracker.hints(
			pr.CachePlan, cacheCapabilities, cacheRouteKey, cacheMode, time.Now())
	}
	pr.CacheSelectionMode = ""
	pr.CacheSelectionTier = ""
	pr.CacheSelectionDiscountMs = 0
	pr.CacheSelectionEstimatedTTFTSavedMs = 0
	pr.CacheSelectionSelected = false
	if pr.CachePlan.present() && cacheMode == CacheRoutingOn {
		pr.CacheSelectionMode = "active"
	}

	r.mu.RLock()
	tLocked := time.Now()
	// Configuration can change while tracker hints are computed outside r.mu.
	// Revalidate under the scan lock so an off/reconfigure transition is
	// linearizable and stale hints never affect selection.
	if cacheMode == CacheRoutingOff || r.cacheRoutingMode != cacheMode ||
		r.cacheRouting != cacheTracker {
		pr.cacheRoutingHints = nil
		pr.CacheSelectionMode = ""
	}
	selected, candidates := r.selectBestCandidateLockedFull(model, pr, excludeIDs...)
	if r.reservationAfterScan != nil {
		// Test-only deterministic barrier. Production never configures this hook.
		r.reservationAfterScan(model)
	}
	tScanned := time.Now()
	result := providerReservationScan{
		selected:     selected,
		candidates:   candidates,
		cacheTracker: r.cacheRouting,
		cacheMode:    r.cacheRoutingMode,
		lockWaitUS:   tLocked.Sub(tScanStart).Microseconds(),
		scanUS:       tScanned.Sub(tLocked).Microseconds(),
	}
	r.mu.RUnlock()
	return result
}

// commitProviderReservation is the short serialized phase. It repeats the full
// current-state capacity chain before adding the pending debit, so concurrent
// scans cannot double-spend a provider's shared cross-model token pool.
func (r *Registry) commitProviderReservation(
	model string,
	pr *PendingRequest,
	scan providerReservationScan,
	excludeIDs ...string,
) (*Provider, *routingCandidate, reservationCommitOutcome, RoutingDecision) {
	r.mu.Lock()
	defer r.mu.Unlock()

	// The shared scan and write-lock wait consume the same absolute request
	// clock as queueing and provider handoff. Never debit capacity for work whose
	// first-content budget is already gone.
	if !pr.RefreshFirstContentBudget(time.Now()) {
		return nil, nil, reservationDeadlineExpired, RoutingDecision{}
	}

	// Cache routing reconfiguration after the shared scan invalidates its cost
	// ordering. Retry from a new scan rather than committing a stale discount.
	if r.cacheRouting != scan.cacheTracker || r.cacheRoutingMode != scan.cacheMode {
		return nil, nil, reservationNeedsRescan, RoutingDecision{}
	}
	selected := scan.selected
	if selected == nil || selected.provider == nil {
		return nil, nil, reservationCandidateRejected, RoutingDecision{}
	}
	p := selected.provider
	if current, ok := r.providers[p.ID]; !ok || current != p {
		return nil, nil, reservationCandidateRejected, RoutingDecision{}
	}

	// A breaker bypass is valid only while breaker-open providers remain the
	// sole route. Re-run the normal pass at commit time; this rare emergency path
	// may scan under the write lock so a newly healthy provider cannot race the
	// fail-open decision.
	if scan.candidates.ignoreProviderBreaker {
		normalWinner, normal := r.selectBestCandidateScanLocked(
			model, pr, false, excludeIDs...)
		if normalWinner != nil || !shouldBypassBreakerFailOpen(
			normalWinner, normal.breakerRejected,
			normal.capacityRejections, normal.ttftRejections) {
			return nil, nil, reservationNeedsRescan, RoutingDecision{}
		}
	}

	owned := providerOwnedBy(p, pr.OwnerAccountID)
	if pr.SelfRouteOnly && !owned {
		return nil, nil, reservationCandidateRejected, RoutingDecision{}
	}
	if len(pr.AllowedProviderSerials) > 0 {
		allowed := make(map[string]struct{}, len(pr.AllowedProviderSerials))
		for _, serial := range pr.AllowedProviderSerials {
			allowed[serial] = struct{}{}
		}
		if !providerMatchesAllowedSerial(p, allowed) {
			return nil, nil, reservationCandidateRejected, RoutingDecision{}
		}
	}
	relaxTrust := owned && (pr.SelfRouteOnly || pr.PreferOwner)
	snapshot, ok := r.snapshotProviderLockedEx(
		p, model, pr.Traits, relaxTrust, scan.candidates.ignoreProviderBreaker)
	if !ok {
		return nil, nil, reservationCandidateRejected, RoutingDecision{}
	}
	if pr.RequiresVision {
		p.mu.Lock()
		servesVision := r.providerServesVisionModelLocked(p, model, relaxTrust)
		p.mu.Unlock()
		if !servesVision {
			return nil, nil, reservationCandidateRejected,
				routingDecisionForCommitRejection(model, rejectVisionUnsupported, false)
		}
	}
	candidate, reason, ok := r.buildCandidateWithReason(snapshot, pr)
	if !ok {
		return nil, nil, reservationCandidateRejected,
			routingDecisionForCommitRejection(model, reason, false)
	}
	if pr.MaxTTFTMs > 0 && !pr.RequiresVision && snapshot.hasBackendCapacity &&
		candidate.breakdown.TTFTMs > pr.MaxTTFTMs {
		return nil, nil, reservationCandidateRejected,
			routingDecisionForCommitRejection(model, rejectNone, true)
	}
	r.applyCacheRoutingDiscount(p, model, pr, snapshot, candidate)

	// Another reservation changed this winner after the shared scan. Re-scan the
	// fleet so cost ranking observes that debit instead of herding the whole scan
	// cohort onto the formerly-cheapest provider.
	if snapshot.pendingForModel != selected.snapshot.pendingForModel ||
		snapshot.totalPending != selected.snapshot.totalPending ||
		candidate.effectiveQueue != selected.effectiveQueue ||
		candidate.costMs != selected.costMs {
		return nil, nil, reservationNeedsRescan, RoutingDecision{}
	}

	p.mu.Lock()
	defer p.mu.Unlock()
	if !r.providerCanAdmitLockedEx(
		p, model, pr.Traits, relaxTrust, scan.candidates.ignoreProviderBreaker) ||
		(pr.RequiresVision && !r.providerServesVisionModelLocked(p, model, relaxTrust)) {
		return nil, nil, reservationCandidateRejected, RoutingDecision{}
	}

	pr.ProviderID = p.ID
	p.addPendingLocked(pr)
	r.claimCapacityProbeLocked(p.ID, model, time.Now())
	if p.Status != StatusUntrusted && p.Status != StatusOffline {
		p.Status = StatusServing
	}
	if !slotStateModelLoaded(candidate.snapshot.slotState) {
		r.RecordWarmPoolColdDispatch(model)
	}
	if !pr.RequiresVision && candidate.breakdown.RawTTFTMs > 0 && candidate.breakdown.StateMs == 0 {
		ttftCalibration.notePrediction(
			pr.RequestID, pr.Attempt, model, candidate.snapshot.chipFamily,
			candidate.breakdown.RawTTFTMs)
	}
	if candidate.breakdown.CacheDiscountMs > 0 {
		pr.CacheSelectionMode = "active"
		pr.CacheSelectionTier = candidate.cacheTier
		pr.CacheSelectionDiscountMs = candidate.breakdown.CacheDiscountMs
		pr.CacheSelectionEstimatedTTFTSavedMs = candidate.cacheEstimatedTTFTSavedMs
		pr.CacheSelectionSelected = true
	}
	return p, candidate, reservationCommitted, RoutingDecision{}
}

// currentTTFTShadow recomputes the observational signal from the winner's
// commit-time pre-reserve snapshot and a fresh, shared-lock candidate pool. It
// runs after the pending debit is committed, so concurrent reservations cannot
// leave occupancy and idle-alternative telemetry pinned to the original scan.
func (r *Registry) currentTTFTShadow(
	model string,
	pr *PendingRequest,
	winner *routingCandidate,
	excludeIDs ...string,
) ttftShadowEval {
	if TTFTAdmissionModeValue() == TTFTAdmissionOff || winner == nil || pr == nil {
		return ttftShadowEval{}
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	var current candidateScan
	if snapshotOccupancy(winner.snapshot) > 0 {
		current = r.scanCandidatesLocked(model, pr, false, excludeIDs...)
	}
	return r.evaluateTTFTShadowLocked(model, pr, winner, current)
}

func routingDecisionForCommitRejection(model string, reason candidateRejection, ttft bool) RoutingDecision {
	decision := RoutingDecision{Model: model}
	switch reason {
	case rejectCapacity:
		decision.CapacityRejections = 1
	case rejectModelTooLarge:
		decision.ModelTooLargeRejections = 1
	case rejectVisionUnsupported:
		decision.VisionRejections = 1
	}
	if ttft {
		decision.TTFTRejections = 1
	}
	return decision
}

func addRoutingRejections(dst *RoutingDecision, src RoutingDecision) {
	if dst == nil {
		return
	}
	dst.CapacityRejections += src.CapacityRejections
	dst.ModelTooLargeRejections += src.ModelTooLargeRejections
	dst.VisionRejections += src.VisionRejections
	dst.TTFTRejections += src.TTFTRejections
	if dst.BestTTFTMs == 0 {
		dst.BestTTFTMs = src.BestTTFTMs
	}
}

func routingDecisionForFailedScan(model string, scan candidateScan) RoutingDecision {
	return RoutingDecision{
		Model:                   model,
		CandidateCount:          scan.candidateCount,
		CapacityRejections:      scan.capacityRejections,
		ModelTooLargeRejections: scan.tooLargeRejections,
		VisionRejections:        scan.visionRejections,
		TTFTRejections:          scan.ttftRejections,
		BestTTFTMs:              scan.bestTTFTMs,
		// System-profiler routing context (by value, filled during the scan).
		CandidateSetSize:   scan.candidateSetSize,
		Scanned:            scan.scanned,
		GateRejections:     scan.gateRejections,
		Top:                scan.top,
		RunnerUp:           scan.runnerUp,
		BestIdle:           scan.bestIdle,
		NearTiePoolSize:    int(scan.nearTieSize),
		SelectionPath:      scan.path,
		PrefillDecodeRatio: prefillToDecodeRatio,
	}
}

func routingDecisionForCandidate(model string, provider *Provider, candidate *routingCandidate, scan candidateScan) RoutingDecision {
	bd := candidate.breakdown
	decision := routingDecisionForFailedScan(model, scan)
	decision.ProviderID = provider.ID
	decision.CostMs = bd.Total
	decision.StateMs = bd.StateMs
	decision.QueueMs = bd.QueueMs
	decision.PendingMs = bd.PendingMs
	decision.BacklogMs = bd.BacklogMs
	decision.ThisReqMs = bd.ThisReqMs
	decision.HealthMs = bd.HealthMs
	decision.CapacityRateMs = bd.CapacityRateMs
	decision.CapacityRejectRate = candidate.capacityRejectRate
	decision.EffectiveQueue = candidate.effectiveQueue
	decision.TTFTMs = bd.TTFTMs
	decision.RawTTFTMs = bd.RawTTFTMs
	decision.CacheTier = candidate.cacheTier
	decision.CacheDiscountMs = bd.CacheDiscountMs
	decision.CacheEstimatedTTFTSavedMs = candidate.cacheEstimatedTTFTSavedMs
	decision.EffectiveTPS = candidate.effectiveTPS
	decision.StaticTPS = candidate.snapshot.decodeTPS
	// Winner context for the system-profiler routing record: how stale the
	// winner's inputs were, what it was predicted to deliver, and what it was
	// already carrying — all from the pre-reserve snapshot, no extra locking.
	decision.SnapshotAgeMs = int(candidate.snapshot.hbAgeMs)
	decision.PredictedDecodeTPS = projectedPerRequestDecodeTPS(candidate.snapshot)
	decision.PendingForModel = candidate.snapshot.pendingForModel
	decision.TotalPending = candidate.snapshot.totalPending
	// The ratio this candidate was actually scored with (captured at build,
	// no second read of the mutable calibrator): the TTFTMs/RawTTFTMs
	// quotient would be wrong for cold slots (the state penalty is
	// deliberately unscaled).
	decision.TTFTCalibrationRatio = candidate.calibrationRatio
	return decision
}

func (r *Registry) applyCacheRoutingDiscount(p *Provider, model string, pr *PendingRequest, snapshot routingSnapshot, candidate *routingCandidate) {
	hint, ok := pr.cacheRoutingHints[p.ID]
	if !ok || !hint.currentForProvider(p, model) {
		return
	}
	prefillTPS := resolvePrefillTPS(snapshot)
	if prefillTPS <= 0 || math.IsNaN(prefillTPS) || math.IsInf(prefillTPS, 0) {
		return
	}
	netSavedMs := float64(hint.PrefillTokensSaved)/prefillTPS*1000 - hint.StageMs
	if netSavedMs <= 0 || math.IsNaN(netSavedMs) || math.IsInf(netSavedMs, 0) {
		return
	}
	capMs := math.Min(r.cacheRoutingMaxDiscountMs, candidate.costMs*r.cacheRoutingMaxCostFraction)
	discount := math.Min(netSavedMs, capMs)
	if discount <= 0 {
		return
	}
	candidate.breakdown.CacheDiscountMs = discount
	candidate.cacheTier = "ssd"
	candidate.cacheEstimatedTTFTSavedMs = netSavedMs
	candidate.costMs -= discount
	candidate.breakdown.Total = candidate.costMs
}

// selectBestCandidateLockedFull is the full-fidelity selection that
// also reports how many providers were rejected by capacity-style
// gates (memory). Capacity rejection count lets ReserveProviderEx
// distinguish "no provider serves this model" from "every fitting
// provider is over-subscribed", which is the difference between the
// no_provider and over_capacity outcome counters.
// Returns the winner plus the candidateScan of the pass that produced it, so
// the caller can read the rejection tallies AND (for plan retention) the
// ranked pool itself without a second scan.
//
// FAIL-OPEN SAFETY VALVE: selection runs in two passes. Pass 1 honors the
// per-provider node-health breaker. If pass 1 finds ZERO candidates AND the
// breaker is the SOLE reason — it rejected at least one provider AND no healthy
// provider was merely busy or too slow — pass 2 re-runs the whole scan with the
// breaker BYPASSED (ignoreProviderBreaker=true), so a bad fleet-wide rollout
// that fault-503s every node can never deroute the entire fleet. When healthy
// providers are simply over capacity or above the TTFT ceiling, pass 1's signal
// is returned instead, so the request queues / 429s and waits for a healthy node
// rather than being routed to a known-bad provider. Pass 2's result is used only
// when it yields a candidate, and its counters (not pass 1's) are returned so
// metrics are never double-counted. This mirrors servability.go's fail-open
// philosophy: when in doubt, keep serving.
func (r *Registry) selectBestCandidateLockedFull(model string, pr *PendingRequest, excludeIDs ...string) (*routingCandidate, candidateScan) {
	winner, scan := r.selectBestCandidateScanLocked(model, pr, false, excludeIDs...)
	if !shouldBypassBreakerFailOpen(winner, scan.breakerRejected, scan.capacityRejections, scan.ttftRejections) {
		return winner, scan
	}
	// The node-health breaker is the SOLE reason this request has no route: re-scan
	// with the breaker bypassed. Use pass 2 only when it actually finds a candidate,
	// so a genuinely empty fleet still reports pass 1's (accurate) counters.
	if w2, scan2 := r.selectBestCandidateScanLocked(model, pr, true, excludeIDs...); w2 != nil {
		return w2, scan2
	}
	return winner, scan
}

// shouldBypassBreakerFailOpen decides whether selection should retry with the
// node-health breaker bypassed (the fail-open safety valve). It fails open ONLY
// when the breaker is the SOLE reason no route was found:
//   - pass 1 produced no winner, AND
//   - the breaker rejected at least one provider, AND
//   - no healthy provider was merely busy (capacityRejections) or too slow
//     (ttftRejections).
//
// If a healthy provider was just over capacity or above the TTFT ceiling, we
// surface that signal (so the request queues / 429s and waits for a healthy
// node) rather than routing to a known-bad, breaker-open provider. Model-too-
// large and vision-unsupported rejections are deliberately NOT counted: those
// providers cannot serve this request at all, so they are not a healthy
// alternative to a fail-open probe.
func shouldBypassBreakerFailOpen(winner *routingCandidate, breakerRejected, capacityRejections, ttftRejections int) bool {
	return winner == nil && breakerRejected > 0 && capacityRejections == 0 && ttftRejections == 0
}

// candidateScan is the result of building the eligible candidate pool for a
// request: the cost-rankable pool (after every per-provider gate AND the
// post-candidate pool narrowing) plus the rejection tallies. It is the SINGLE
// SOURCE of routing eligibility, shared by
// the cost-ranking selector (selectBestCandidateScanLocked) and the Phase-0
// idle-spread shadow scan (loadedIdleAlternativeExistsLocked) so the two can
// never drift on which providers are routable.
type candidateScan struct {
	pool                  []*routingCandidate
	candidateCount        int
	capacityRejections    int
	tooLargeRejections    int
	visionRejections      int
	ttftRejections        int
	bestTTFTMs            float64
	breakerRejected       int
	ignoreProviderBreaker bool

	// System-profiler routing context — fixed-size value fields filled inside
	// the existing loops with ZERO heap allocation (hot-path review C5). See the
	// matching RoutingDecision fields for semantics.
	scanned          int
	candidateSetSize int
	gateRejections   [GateReasonCount]uint16
	top              [4]CandidateSummary
	runnerUp         CandidateSummary
	bestIdle         CandidateSummary
	nearTieSize      int32
	path             SelectionPath
}

// tallyGate records one gate rejection, saturating at the uint16 ceiling.
func (s *candidateScan) tallyGate(reason GateReason) {
	if reason >= GateReasonCount {
		return
	}
	if s.gateRejections[reason] < ^uint16(0) {
		s.gateRejections[reason]++
	}
}

// insertTop inserts a candidate summary into the fixed top-4 array, keeping it
// sorted by ascending cost. Allocation-free: at most 3 element moves.
func (s *candidateScan) insertTop(c *routingCandidate) {
	pos := len(s.top)
	id := ""
	if c.provider != nil {
		id = c.provider.ID
	}
	for i := range s.top {
		// Equal costs are ordered by provider id so the recorded top-4 is
		// deterministic regardless of map iteration order.
		if !s.top[i].Present || c.costMs < s.top[i].CostMs ||
			(c.costMs == s.top[i].CostMs && id < s.top[i].ProviderID) {
			pos = i
			break
		}
	}
	if pos >= len(s.top) {
		return
	}
	copy(s.top[pos+1:], s.top[pos:len(s.top)-1])
	s.top[pos] = candidateSummaryOf(c)
}

// promoteWinnerTop moves the winner to top[0] (contract: "winner is Top[0] when
// present"), keeping the remaining slots in ascending cost. When the winner is
// not among the top-4 by cost (possible after a random near-tie pick), it is
// inserted at the head and the last slot is dropped.
func (s *candidateScan) promoteWinnerTop(winner *routingCandidate) {
	if winner == nil || winner.provider == nil {
		return
	}
	id := winner.provider.ID
	for i := range s.top {
		if s.top[i].Present && s.top[i].ProviderID == id {
			if i == 0 {
				return
			}
			w := s.top[i]
			copy(s.top[1:i+1], s.top[0:i])
			s.top[0] = w
			return
		}
	}
	copy(s.top[1:], s.top[0:len(s.top)-1])
	s.top[0] = candidateSummaryOf(winner)
}

// noteBestIdle updates the best-idle slot: the lowest-TTFT candidate whose slot
// is warm (model resident) and whose backend reports zero running + waiting.
func (s *candidateScan) noteBestIdle(c *routingCandidate) {
	snap := &c.snapshot
	if !snap.modelLoaded || snap.backendRunning+snap.backendWaiting != 0 || !snap.hasBackendCapacity {
		return
	}
	ttft := c.breakdown.TTFTMs
	if s.bestIdle.Present {
		// Deterministic tie-break (lower cost, then provider id) so the record
		// does not depend on map iteration order.
		if ttft > s.bestIdle.TTFTMs {
			return
		}
		if ttft == s.bestIdle.TTFTMs {
			if c.costMs > s.bestIdle.CostMs {
				return
			}
			if c.costMs == s.bestIdle.CostMs && (c.provider == nil || c.provider.ID >= s.bestIdle.ProviderID) {
				return
			}
		}
	}
	s.bestIdle = candidateSummaryOf(c)
}

// scanCandidatesLocked builds the eligible candidate pool for a request — every
// per-provider gate (self-route, allowlist, exclude, structural/trait/trust via
// snapshotProviderLockedEx, vision, capacity via buildCandidateWithReason, plus
// the per-request TTFT ceiling) followed by the post-candidate pool narrowing
// (prefer-owner / AvoidVersion / MinDecodeTPS) — i.e. exactly the set the
// selector ranks by cost. When ignoreProviderBreaker is true the node-health
// breaker gate is skipped (every other gate still applies); breakerRejected is
// always 0 in that mode. Caller holds r.mu and no provider lock.
func (r *Registry) scanCandidatesLocked(model string, pr *PendingRequest, ignoreProviderBreaker bool, excludeIDs ...string) candidateScan {
	excludeSet := make(map[string]struct{}, len(excludeIDs)+len(pr.ExcludedProviderIDs))
	for _, id := range excludeIDs {
		excludeSet[id] = struct{}{}
	}
	for _, id := range pr.ExcludedProviderIDs {
		excludeSet[id] = struct{}{}
	}
	allowedSerials := make(map[string]struct{}, len(pr.AllowedProviderSerials))
	for _, serial := range pr.AllowedProviderSerials {
		allowedSerials[serial] = struct{}{}
	}

	// Two-pass selection: collect all eligible candidates first, then
	// compute best + tie pool. The single-pass approach was order-
	// dependent — when a new best replaced an older one within the tie
	// window, candidates near the OLD best (and still near the NEW
	// best) were dropped from the pool, making the queue-depth tie-
	// break flaky under map iteration randomness.
	candidates := make([]*routingCandidate, 0, len(r.providers))
	candidateCount := 0
	capacityRejections := 0
	tooLargeRejections := 0
	visionRejections := 0
	ttftRejections := 0
	bestTTFTMs := 0.0
	breakerRejected := 0
	// scan carries the fixed-size system-profiler context (gate-reason tallies,
	// best-idle, top-4) filled inside this loop with zero heap allocation; the
	// legacy counters above are assigned into it at the end, unchanged.
	var scan candidateScan
	now := time.Now()
	// Vision preparation is absent from the token-prefill projection, so media
	// estimates are advisory even if a caller accidentally supplies a ceiling.
	// The request-absolute first-content deadline remains authoritative.
	enforceTTFT := pr.MaxTTFTMs > 0 && !pr.RequiresVision
	for _, p := range r.providers {
		scan.scanned++
		owned := providerOwnedBy(p, pr.OwnerAccountID)
		// Exclusive self-route: restrict to the caller's own machines and never
		// fall back to the public fleet. Tallied as an allowlist drop: the caller
		// restricted routing to a set of providers this one is not in.
		if pr.SelfRouteOnly && !owned {
			scan.tallyGate(GateAllowlist)
			continue
		}
		if len(allowedSerials) > 0 {
			if !providerMatchesAllowedSerial(p, allowedSerials) {
				scan.tallyGate(GateAllowlist)
				continue
			}
		}
		if _, excluded := excludeSet[p.ID]; excluded {
			scan.tallyGate(GateExcluded)
			continue
		}
		// Relax the hardware-trust floor ONLY for the caller's own (possibly
		// un-enrolled) machine — whether exclusive self-route or prefer — never
		// for public providers.
		relaxTrust := owned && (pr.SelfRouteOnly || pr.PreferOwner)
		// snapshotProviderLocked applies every per-provider gate via the shared
		// providerPassesRoutingGatesLocked, INCLUDING the shape-keyed
		// inference-error cooldown and the trait gates (render-broken fences all
		// shapes; the tools version floor fences tool requests). A failing
		// provider is simply dropped here — the reason-returning twin names the
		// gate for the profiler tally without changing the verdict.
		snap, ok, gateReason := r.snapshotProviderReasonLockedEx(p, model, pr.Traits, relaxTrust, ignoreProviderBreaker)
		if !ok {
			scan.tallyGate(gateReason)
			// Count providers a breaker-bypassed fail-open re-scan COULD rescue: those
			// dropped by the node-health breaker OR the stable-identity health-ejection
			// gate (both are bypassed when ignoreProviderBreaker is set). Without
			// counting ejection here, ejecting EVERY provider for a model would leave
			// winner==nil with breakerRejected==0, so shouldBypassBreakerFailOpen would
			// NOT fire and the model would be zeroed out. Only meaningful on the normal pass.
			if !ignoreProviderBreaker {
				if r.providerBreakerOpenLocked(p.ID, now) {
					breakerRejected++
				} else if healthEjectionEnabled() {
					// p.mu is not held here (snapshot released it); take it for the
					// identity read (r.mu→p.mu is the established order).
					p.mu.Lock()
					sid := stableProviderIdentityLocked(p)
					p.mu.Unlock()
					if sid != "" && r.healthEjectionOpenLocked(sid, now) {
						breakerRejected++
					}
				}
			}
			// A pair dropped ONLY by the capacity-reject cooldown is TRANSIENT
			// capacity, not structural absence — count it as a capacityRejection
			// (mirroring quickCapacityCheck) so an all-cooled model classifies as
			// over_capacity (429/queue material) rather than no_provider. The
			// ignoreCapacityCooldown re-run of the shared gate keeps a pair that
			// ALSO fails a structural gate out of the count; both checks are
			// cheap and only run on the already-rare drop path.
			if r.capacityCooldownActiveLocked(p.ID, model, now) {
				p.mu.Lock()
				otherwiseRoutable := r.providerPassesRoutingGatesLockedEx(p, model, pr.Traits, relaxTrust, now, ignoreProviderBreaker, true)
				p.mu.Unlock()
				if otherwiseRoutable {
					capacityRejections++
				}
			}
			continue
		}
		// Vision gate: a media request must only go to a provider advertising a
		// vision-capable build of this model. Providers reach here only if they
		// already serve the model (snapshot ok), so a miss here means "serves it,
		// but text-only" — counted separately so the caller can return a precise
		// "no vision-capable provider" error rather than a busy/429. snapshot
		// released p.mu, so re-take it for the p.Models read.
		if pr.RequiresVision {
			p.mu.Lock()
			servesVision := r.providerServesVisionModelLocked(p, model, relaxTrust)
			p.mu.Unlock()
			if !servesVision {
				visionRejections++
				scan.tallyGate(GateVision)
				continue
			}
		}
		candidate, reason, gateReason, ok := r.buildCandidateGateLocked(snap, pr)
		if !ok {
			switch reason {
			case rejectCapacity:
				capacityRejections++
			case rejectModelTooLarge:
				tooLargeRejections++
			case rejectVisionUnsupported:
				visionRejections++
			}
			scan.tallyGate(gateReason)
			continue
		}

		// Track the best reliable TTFT seen among providers that passed all
		// structural and capacity gates. Even if this candidate is over the
		// ceiling, the value is used for Retry-After on the TTFT 429 path.
		// Providers without BackendCapacity do not contribute a reliable TTFT
		// estimate, so they are skipped here.
		if snap.hasBackendCapacity && (candidate.breakdown.TTFTMs < bestTTFTMs || bestTTFTMs == 0) {
			bestTTFTMs = candidate.breakdown.TTFTMs
		}

		// Enforce the per-request TTFT ceiling for public inference routes.
		// Providers above the threshold are counted as TTFT rejections and
		// excluded from cost-based selection so the router cannot pick a
		// provider that misses the OpenRouter SLA target. Providers without
		// BackendCapacity have no reliable TTFT estimate, so the ceiling is
		// not enforced on them (matching the preflight behavior).
		if enforceTTFT && snap.hasBackendCapacity && candidate.breakdown.TTFTMs > pr.MaxTTFTMs {
			ttftRejections++
			scan.tallyGate(GateTTFTCeiling)
			continue
		}

		r.applyCacheRoutingDiscount(p, model, pr, snap, candidate)
		// Best-idle is computed UNCONDITIONALLY over every routable candidate
		// (before pool narrowing) so the record can answer "was an idle warm box
		// available?" whether or not the shadow evaluator is on.
		scan.noteBestIdle(candidate)
		candidates = append(candidates, candidate)
		candidateCount++
	}
	scan.candidateSetSize = scan.scanned - int(scan.gateRejections[GateNotServingModel])

	// Prefer-with-fallback: if the caller asked to prefer their own machine and
	// at least one owned candidate can serve, choose among owned candidates
	// only; otherwise fall back to the full pool (a public provider, charged
	// normally). Exclusive self-route already filtered to owned above.
	pool := candidates
	if pr.PreferOwner {
		owned := make([]*routingCandidate, 0, len(candidates))
		for _, c := range candidates {
			if providerOwnedBy(c.provider, pr.OwnerAccountID) {
				owned = append(owned, c)
			}
		}
		if len(owned) > 0 {
			pool = owned
		}
	}

	// Version-diverse retry (SOFT): when a previous attempt failed on a given
	// binary version, prefer candidates running any OTHER version so a
	// deterministic per-version bug (e.g. a chat-template render crash) cannot
	// consume every retry on identical binaries. Diversity never fails closed:
	// when every candidate runs the avoided version, keep the full pool rather
	// than failing the request.
	if pr.Traits.AvoidVersion != "" {
		diverse := make([]*routingCandidate, 0, len(pool))
		for _, c := range pool {
			if providerVersion(c.provider) != pr.Traits.AvoidVersion {
				diverse = append(diverse, c)
			}
		}
		if len(diverse) > 0 {
			pool = diverse
		}
	}

	// Decode-floor quality preference (SOFT, Routing v2 W2): when a per-request
	// decode floor is set, prefer candidates that would still deliver
	// >= MinDecodeTPS to a newly admitted request, so the router does not overpack
	// a provider into a degraded (low tok/s) stream. Never fails closed — if no
	// candidate clears the floor, keep the full pool so the request is still
	// served (growing warm capacity / queueing to protect quality is handled
	// upstream, not by dropping the request here).
	if pr.MinDecodeTPS > 0 {
		quality := make([]*routingCandidate, 0, len(pool))
		for _, c := range pool {
			if projectedPerRequestDecodeTPS(c.snapshot) >= pr.MinDecodeTPS {
				quality = append(quality, c)
			}
		}
		if len(quality) > 0 {
			pool = quality
		}
	}

	// Top-4 by cost over the NARROWED pool (the set the selector ranks); the
	// winner is promoted to top[0] after selection. ≤ 4 compares per candidate,
	// fixed array, no allocation.
	for _, c := range pool {
		scan.insertTop(c)
	}

	scan.pool = pool
	scan.candidateCount = candidateCount
	scan.capacityRejections = capacityRejections
	scan.tooLargeRejections = tooLargeRejections
	scan.visionRejections = visionRejections
	scan.ttftRejections = ttftRejections
	scan.bestTTFTMs = bestTTFTMs
	scan.breakerRejected = breakerRejected
	scan.ignoreProviderBreaker = ignoreProviderBreaker
	return scan
}

// selectBestCandidateScanLocked is one pass of candidate selection: it builds the
// eligible pool (scanCandidatesLocked — the single source of eligibility) and
// ranks it by cost, returning the winner plus the whole scan (rejection tallies
// and the ranked pool). When ignoreProviderBreaker is true the node-health
// breaker gate is skipped; scan.breakerRejected (providers dropped while their
// breaker was OPEN) is the signal selectBestCandidateLockedFull uses to decide
// whether a breaker-bypassed fail-open re-scan could help, and is always 0 in
// that mode.
func (r *Registry) selectBestCandidateScanLocked(model string, pr *PendingRequest, ignoreProviderBreaker bool, excludeIDs ...string) (*routingCandidate, candidateScan) {
	scan := r.scanCandidatesLocked(model, pr, ignoreProviderBreaker, excludeIDs...)
	if len(scan.pool) == 0 {
		return nil, scan
	}

	winner, runnerUp, nearTieSize, path := selectRoutingCandidate(scan.pool, func(candidate *routingCandidate) float64 {
		return candidate.costMs
	})
	scan.runnerUp = candidateSummaryOf(runnerUp)
	scan.nearTieSize = clampInt32(nearTieSize)
	scan.path = path
	scan.promoteWinnerTop(winner)
	r.logRoutingDecision(model, pr, winner, scan.candidateCount)
	return winner, scan
}

// selectRoutingCandidate centralizes cost ranking, near-tie admission, and
// queue-depth tie-breaking. Besides the winner it reports the runner-up (the
// lowest-cost candidate other than the winner — "what we would have chosen
// instead"; nil for a single-candidate pool), the size of the near-tie pool,
// and WHICH branch chose the winner (SelectionPath). The selection itself is
// byte-for-byte the pre-profiler algorithm; the extra outputs are derived from
// state the algorithm already computes and add no heap allocation.
func selectRoutingCandidate(
	pool []*routingCandidate,
	cost func(*routingCandidate) float64,
) (winner, runnerUp *routingCandidate, nearTieSize int, path SelectionPath) {
	if len(pool) == 0 {
		return nil, nil, 0, SelectionNone
	}
	best := pool[0]
	for _, candidate := range pool[1:] {
		if cost(candidate) < cost(best) {
			best = candidate
		}
	}
	nearTies := make([]*routingCandidate, 0, len(pool))
	for _, candidate := range pool {
		if math.Abs(cost(candidate)-cost(best)) <= nearTieCostWindowMs {
			nearTies = append(nearTies, candidate)
		}
	}
	winner = nearTies[0]
	for _, candidate := range nearTies[1:] {
		if candidate.effectiveQueue < winner.effectiveQueue ||
			(candidate.effectiveQueue == winner.effectiveQueue && candidate.snapshot.totalPending < winner.snapshot.totalPending) {
			winner = candidate
		}
	}
	equivalent := make([]*routingCandidate, 0, len(nearTies))
	for _, candidate := range nearTies {
		if candidate.effectiveQueue == winner.effectiveQueue &&
			candidate.snapshot.totalPending == winner.snapshot.totalPending &&
			math.Abs(cost(candidate)-cost(winner)) <= nearTieCostWindowMs {
			equivalent = append(equivalent, candidate)
		}
	}
	nearTieSize = len(nearTies)
	// Normal near-tie spreading must not erase a bounded exact-cache discount
	// (the default 1s cap is intentionally smaller than the 3s spread window).
	// Once queue/backlog equivalence is established, exact evidence resolves the
	// tie by adjusted cost. A busier holder never reaches this set, and a holder
	// whose adjusted cost is still worse loses to the lower-cost cold provider.
	hasCacheDiscount := false
	for _, candidate := range equivalent {
		if candidate.breakdown.CacheDiscountMs > 0 {
			hasCacheDiscount = true
			break
		}
	}
	switch {
	case hasCacheDiscount:
		bestCost := cost(equivalent[0])
		best := equivalent[:1]
		for _, candidate := range equivalent[1:] {
			candidateCost := cost(candidate)
			switch {
			case candidateCost < bestCost:
				bestCost = candidateCost
				best = []*routingCandidate{candidate}
			case candidateCost == bestCost:
				best = append(best, candidate)
			}
		}
		switch {
		case len(best) > 1:
			winner = best[rand.Intn(len(best))]
			path = SelectionRandom
		case len(equivalent) > 1:
			winner = best[0]
			path = SelectionCacheTiebreak
		default:
			// A single equivalent candidate that happens to carry a discount:
			// the discount did not break any tie; the queue/pending tie-break
			// (or unique minimum) did.
			winner = best[0]
			path = tieBreakPath(nearTies, winner)
		}
	case len(equivalent) > 1:
		winner = equivalent[rand.Intn(len(equivalent))]
		path = SelectionRandom
	default:
		path = tieBreakPath(nearTies, winner)
	}
	runnerUp = lowestCostOther(pool, winner, cost)
	return winner, runnerUp, nearTieSize, path
}

// tieBreakPath names the deterministic branch that produced winner from the
// near-tie pool: unique minimum, lowest effectiveQueue, or (queue tied with
// another near-tie) lowest totalPending.
func tieBreakPath(nearTies []*routingCandidate, winner *routingCandidate) SelectionPath {
	if len(nearTies) <= 1 {
		return SelectionUniqueMin
	}
	for _, c := range nearTies {
		if c != winner && c.effectiveQueue == winner.effectiveQueue {
			return SelectionTiePending
		}
	}
	return SelectionTieQueue
}

// lowestCostOther returns the lowest-cost candidate in pool other than winner
// (nil when the pool has no other candidate). One pass, no allocation.
func lowestCostOther(pool []*routingCandidate, winner *routingCandidate, cost func(*routingCandidate) float64) *routingCandidate {
	var other *routingCandidate
	for _, c := range pool {
		if c == winner {
			continue
		}
		if other == nil || cost(c) < cost(other) {
			other = c
		}
	}
	return other
}

func providerMatchesAllowedSerial(p *Provider, allowed map[string]struct{}) bool {
	if p == nil || len(allowed) == 0 {
		return true
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.AttestationResult != nil {
		if _, ok := allowed[p.AttestationResult.SerialNumber]; ok && p.AttestationResult.SerialNumber != "" {
			return true
		}
	}
	if p.MDAResult != nil {
		if _, ok := allowed[p.MDAResult.DeviceSerial]; ok && p.MDAResult.DeviceSerial != "" {
			return true
		}
	}
	return false
}

// providerOwnedBy reports whether p is owned by accountID. Ownership is the
// coordinator-stamped Provider.AccountID (set at registration from the device
// auth token), never a client-supplied value — so it cannot be forged by a
// caller. An empty accountID never matches.
func providerOwnedBy(p *Provider, accountID string) bool {
	if p == nil || accountID == "" {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.AccountID != "" && p.AccountID == accountID
}

// providerVersion reads the provider's binary version under p.mu (set by the
// API layer after registration; p.mu guards provider field access — mirrors
// providerOwnedBy). Used by the version-diverse retry pool filter.
func providerVersion(p *Provider) string {
	if p == nil {
		return ""
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.Version
}

// OwnedProviderSummary reports, for the given account, how many of its
// currently-connected providers are online and how many can serve `model` for
// a request with the given traits/media shape. It powers self-route pre-flight
// error messaging: distinguishing "your machine is offline" from "your machine
// can't serve this request". The model-serving check applies the same
// privacy/runtime/challenge gates as routing but deliberately ignores the
// hardware-trust gate, which self-route relaxes for a caller's own machine.
// traits/requiresVision mirror the dispatch-time gates
// (providerEligibleForTraitsLocked, the vision gate): without them a tool call
// to an owned box below the tools floor — or a media request to a text-only
// build — would pass this preflight, queue for up to 120s, and die as
// machine_busy instead of failing fast with the real cause. Callers asking the
// base-shape question ("any owned box serves this model at all?") pass zero
// traits and requiresVision=false. "Linked but offline" providers are not
// counted here (they are not in the registry); callers detect zero linked
// machines via store.ListProvidersByAccount.
func (r *Registry) OwnedProviderSummary(accountID, model string, traits RequestTraits, requiresVision bool) (online, servesModel int) {
	if accountID == "" {
		return 0, 0
	}
	now := time.Now()
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, p := range r.providers {
		p.mu.Lock()
		if p.AccountID == "" || p.AccountID != accountID {
			p.mu.Unlock()
			continue
		}
		if p.Status == StatusOffline || p.Status == StatusUntrusted {
			p.mu.Unlock()
			continue
		}
		online++
		// Owner-servability (not bare advertisement) so the self-route error
		// messaging matches what routing would actually admit: an owned box
		// advertising a stale-hash catalog build reports "model not loaded"
		// instead of proceeding into a dispatch that can only be rejected.
		serves := r.providerServesOwnedRoutableModelLocked(p, model) &&
			r.providerEligibleForTraitsLocked(p, model, traits) &&
			(!requiresVision || r.providerServesVisionModelLocked(p, model, true)) &&
			p.RuntimeVerified &&
			r.providerSupportsPrivateTextLocked(p) &&
			!p.LastChallengeVerified.IsZero() &&
			now.Sub(p.LastChallengeVerified) <= challengeFreshnessMaxAge
		p.mu.Unlock()
		if serves {
			servesModel++
		}
	}
	return online, servesModel
}

// logRoutingDecision emits a structured debug-level record of the
// winning candidate and its cost breakdown. Cheap when the level is
// disabled, since slog short-circuits before formatting.
func (r *Registry) logRoutingDecision(model string, pr *PendingRequest, winner *routingCandidate, candidates int) {
	if r.logger == nil || winner == nil {
		return
	}
	// Level check BEFORE the variadic call: slog boxes every key/value pair
	// into `any` at the call site (≈15 heap allocations) even when the level
	// is disabled, and this runs under r.mu on every reserve.
	if !r.logger.Enabled(context.Background(), slog.LevelDebug) {
		return
	}
	bd := winner.breakdown
	r.logger.Debug("routing_decision",
		"request_id", pr.RequestID,
		"model", model,
		"winner", winner.provider.ID,
		"cost_ms", bd.Total,
		"state_ms", bd.StateMs,
		"queue_ms", bd.QueueMs,
		"pending_ms", bd.PendingMs,
		"backlog_ms", bd.BacklogMs,
		"this_req_ms", bd.ThisReqMs,
		"health_ms", bd.HealthMs,
		"cache_tier", winner.cacheTier,
		"cache_discount_ms", bd.CacheDiscountMs,
		"effective_tps", winner.effectiveTPS,
		"effective_queue", winner.effectiveQueue,
		"candidates", candidates,
	)
}

// providerPassesRoutingGatesLocked is the single source of truth for the
// per-provider structural/privacy/cooldown/trait gates a request must clear
// before a provider is eligible to serve it. snapshotProviderLocked (the
// production dispatch hot path) and QuickCapacityCheck (the preflight) BOTH call
// it so the two can never drift — a prior bug had QuickCapacityCheck silently
// missing the dispatch-load cooldown, the inference-error cooldown, and the
// trait gates, so the preflight reported capacity that routing then refused.
//
// Gates, in evaluation order:
//   - catalog membership (advertises an allowed build of the model)
//   - dispatch-load cooldown (pair instant-503'd on "insufficient memory")
//   - inference-error cooldown, SHAPE-KEYED to traits.CooldownShape() (pair
//     returning repeated provider-side 5xx for THIS request shape)
//   - capacity-reject cooldown (pair capacity-rejecting everything with ZERO
//     interleaved accepts — the black-hole signature)
//   - status not offline/untrusted
//   - private-only admission (only the owner's self-route may use it)
//   - hardware-trust floor (relaxed to TrustNone for the owner's own machine)
//   - runtime verified
//   - private-text support (E2E privacy backstop)
//   - challenge freshness
//   - trait eligibility: render-broken fences EVERY request shape; version
//     floors are trait-scoped (tools-only today)
//
// selfRouteOwner relaxes only the trust floor and private-only admission for a
// caller's own (possibly un-enrolled) machine; every privacy-critical gate
// still applies. Caller holds r.mu and p.mu.
func (r *Registry) providerPassesRoutingGatesLocked(p *Provider, model string, traits RequestTraits, selfRouteOwner bool, now time.Time) bool {
	return r.providerPassesRoutingGatesLockedEx(p, model, traits, selfRouteOwner, now, false, false)
}

// providerPassesRoutingGatesLockedEx is providerPassesRoutingGatesLocked with
// two explicit switches. ignoreProviderBreaker skips ONLY the per-provider
// node-health breaker (and health ejection); it exists solely for the
// selectBestCandidateLockedFull fail-open fallback pass, so a fleet-wide fault
// rollout that trips the breaker on every provider can never deroute the
// entire fleet. ignoreCapacityCooldown skips ONLY the capacity-reject cooldown;
// it exists solely for the "would this pair otherwise pass?" re-check that
// lets the candidate scan and the QuickCapacityCheck preflight count a
// capacity-cooled pair as a TRANSIENT capacityRejection (429/queue material)
// instead of structural absence (a "no providers" 503) — it must never be set
// on an actual routing/admission decision. Every other caller goes through the
// default wrapper above (both always honored). Caller holds r.mu and p.mu.
func (r *Registry) providerPassesRoutingGatesLockedEx(p *Provider, model string, traits RequestTraits, selfRouteOwner bool, now time.Time, ignoreProviderBreaker, ignoreCapacityCooldown bool) bool {
	ok, _ := r.providerRoutingGateReasonLockedEx(p, model, traits, selfRouteOwner, now, ignoreProviderBreaker, ignoreCapacityCooldown)
	return ok
}

// providerRoutingGateReasonLockedEx is providerPassesRoutingGatesLockedEx
// returning the FIRST failing gate as a closed GateReason (meaningful only when
// ok is false; GateReasonCount when ok). It IS the gate — the boolean form is a
// wrapper — so the verdict and the reason can never drift. Allocation-free.
// Caller holds r.mu and p.mu.
func (r *Registry) providerRoutingGateReasonLockedEx(p *Provider, model string, traits RequestTraits, selfRouteOwner bool, now time.Time, ignoreProviderBreaker, ignoreCapacityCooldown bool) (bool, GateReason) {
	// Catalog membership + dedicated-box isolation: a request for a dedicated
	// model family (e.g. Gemma 4) may ONLY route to a provider whose ENTIRE
	// advertised catalog is that family. This single gate is shared by the
	// dispatch hot path and the OpenRouter capacity preflight, so the filter
	// restricts the routing candidate set AND the shed (429) decision together
	// with no drift. A caller self-routing to its OWN machine is exempt — owners
	// may run mixed boxes.
	if ok, reason := r.providerServesRoutableModelReasonLocked(p, model, selfRouteOwner); !ok {
		return false, reason
	}
	// Skip a provider-model pair cooling down after a dispatch-time load
	// failure ("insufficient memory") — it would instant-503 again, burning a
	// dispatch attempt.
	if r.dispatchLoadCooldownActiveLocked(p.ID, model, now) {
		return false, GateDispatchLoadCooldown
	}
	// Skip a triple quarantined by the inference-error circuit breaker for THIS
	// request shape: repeated provider-side (5xx) failures — e.g. a deterministic
	// chat-template render crash on tool schemas — mean a retry here fails
	// identically, so routing must fall to a different provider. Shape-keyed so a
	// tool failure does not deroute clean text traffic. Cleared by
	// RecordInferenceSuccess (same shape) or by TTL expiry.
	if r.inferenceErrorCooldownActiveLocked(p.ID, model, traits.CooldownShape(), now) {
		return false, GateErrorCooldown
	}
	// Skip a (provider, model) pair quarantined by the capacity-reject cooldown:
	// it kept capacity-rejecting with ZERO interleaved accepts (the black-hole
	// signature — e.g. a box whose engine misreports its token budget), so a
	// dispatch here is a guaranteed bounce while its idle-looking heartbeats
	// keep winning the cost scheduler. A busy box that is also SERVING never
	// trips this (any accept resets the streak), and the pair is re-probed once
	// its TTL expires. See capacity_cooldown.go.
	if !ignoreCapacityCooldown && r.capacityCooldownActiveLocked(p.ID, model, now) {
		return false, GateCapacityCooldown
	}
	// Skip a provider quarantined by the per-provider node-health breaker: a
	// node returning GENUINE-FAULT errors (500/502/504 or a
	// fault-shaped 503) for ~all of its requests is sick regardless of model or
	// shape, so it is derouted fleet-wide. This catches the node that fault-503s
	// every request — invisible to the shape-keyed inference-error breaker above
	// (which skips 503 as a capacity signal). Honored on the normal routing
	// path; the selectBestCandidateLockedFull fail-open pass sets
	// ignoreProviderBreaker so a bad fleet-wide rollout can't deroute everyone.
	if !ignoreProviderBreaker && r.providerBreakerOpenLocked(p.ID, now) {
		return false, GateBreaker
	}
	// Skip a provider EJECTED by the stable-identity health breaker (health_ejection.go):
	// a node whose serial/SE-key/account has collapsed to a near-total served-fault
	// rate is derouted even across reconnects (the session breaker above is wiped on
	// every disconnect, which the constantly-disconnecting zombies exploit). Same
	// fail-open contract: skipped on the ignoreProviderBreaker rescan, and an
	// un-attestable provider (empty stable id) is never ejected.
	if !ignoreProviderBreaker && healthEjectionEnabled() {
		if sid := stableProviderIdentityLocked(p); sid != "" && r.healthEjectionOpenLocked(sid, now) {
			return false, GateEjection
		}
	}
	// Liveness/trust/privacy core. selfRouteOwner relaxes ONLY the hardware-trust
	// floor (to TrustNone) and private-only admission for a caller's own
	// (possibly un-enrolled) machine; every privacy-critical gate still applies.
	minTrust := r.MinTrustLevel
	if selfRouteOwner {
		minTrust = TrustNone
	}
	if ok, reason := r.providerLivenessGateReasonLocked(p, minTrust, selfRouteOwner, now); !ok {
		return false, reason
	}
	// Trait eligibility: a render-broken build is fenced for EVERY request shape
	// (a crashing chat template breaks plain text, tools, and multimodal alike),
	// while the capability version floors stay trait-scoped (tools-only today).
	if !r.providerEligibleForTraitsLocked(p, model, traits) {
		return false, GateTraitFloor
	}
	return true, GateReasonCount
}

// snapshotProviderLocked builds a routing snapshot for p, returning ok=false
// when p fails any structural/privacy/capacity/trait gate. selfRouteOwner is
// true when this is a self-route request and p is owned by the requesting
// account. It (1) drops the hardware-trust floor to TrustNone — a personal Mac
// will not be MDM/MDA enrolled, so without this it would be unroutable to its
// own owner — and (2) admits a private-only machine, which is otherwise
// excluded from the public fleet. Every privacy-critical gate (RuntimeVerified,
// private-text support, challenge freshness) still applies, so plaintext is
// never exposed and only the genuinely-signed provider binary serves. traits
// carry the request shape into the shape-keyed inference-error cooldown and the
// render-broken / version-floor eligibility gates.
func (r *Registry) snapshotProviderLocked(p *Provider, model string, traits RequestTraits, selfRouteOwner bool) (routingSnapshot, bool) {
	return r.snapshotProviderLockedEx(p, model, traits, selfRouteOwner, false)
}

// snapshotProviderLockedEx is snapshotProviderLocked with an explicit
// ignoreProviderBreaker switch threaded into the routing gate. Only the
// selectBestCandidateLockedFull fail-open fallback pass sets it true (to bypass
// the node-health breaker); every other caller uses the default
// (breaker-honored) wrapper above.
func (r *Registry) snapshotProviderLockedEx(p *Provider, model string, traits RequestTraits, selfRouteOwner bool, ignoreProviderBreaker bool) (routingSnapshot, bool) {
	snap, ok, _ := r.snapshotProviderReasonLockedEx(p, model, traits, selfRouteOwner, ignoreProviderBreaker)
	return snap, ok
}

// snapshotProviderReasonLockedEx is snapshotProviderLockedEx returning, when
// the provider fails the routing gate, WHICH gate dropped it (a closed
// GateReason; GateReasonCount when ok). The boolean form is a wrapper so every
// existing caller is byte-for-byte unchanged. It also stamps the snapshot's
// heartbeat age from the `now` it already reads.
func (r *Registry) snapshotProviderReasonLockedEx(p *Provider, model string, traits RequestTraits, selfRouteOwner bool, ignoreProviderBreaker bool) (routingSnapshot, bool, GateReason) {
	now := time.Now()

	p.mu.Lock()
	defer p.mu.Unlock()

	if ok, reason := r.providerRoutingGateReasonLockedEx(p, model, traits, selfRouteOwner, now, ignoreProviderBreaker, false); !ok {
		return routingSnapshot{}, false, reason
	}

	snap := routingSnapshot{
		provider:      p,
		model:         model,
		chipFamily:    p.Hardware.ChipFamily,
		binaryVersion: p.Version,
		slotState:     "unknown",
		totalPending:  p.pendingCount(),
		systemMetrics: p.SystemMetrics,
		decodeTPS:     resolvedDecodeTPS(p),
		prefillTPS:    resolvedPrefillTPS(p),
		totalMemoryGB: float64(p.Hardware.MemoryGB),
		modelSizeGB:   r.modelSizeGBForFitLocked(p, model),
		minRAMGb:      r.catalogMinRAMGbLocked(model),
		hbAgeMs:       heartbeatAgeMs(now, p.LastHeartbeat),
	}

	fillSnapshotPendingAndPool(&snap, p, model)
	// Concurrency headroom with the quality-concurrency cap: a slow model whose
	// quality batch is below the flat fallback (e.g. Gemma at ~14 tok/s solo →
	// batch 1-2) stops being admittable once it is at its quality cap, so load
	// spreads across boxes instead of collapsing a few. The cap resolves the
	// model's own static solo rate internally (solo median / seed → provider
	// benchmark fallback) — NOT snap.decodeTPS, which stays the provider-level
	// rate for TTFT/cost estimation, and NOT the observed-under-load value.
	// No-op (legacy flat cap) when the cap is disabled.
	snap.hasHeadroom = r.hasConcurrencyHeadroomForModelCapResolvedLocked(p, model)
	snap.hasBackendCapacity = p.BackendCapacity != nil

	if p.BackendCapacity != nil {
		snap.gpuMemoryActiveGB = p.BackendCapacity.GPUMemoryActiveGB
		snap.freeForLoadGB = p.BackendCapacity.FreeForLoadGB
		if p.BackendCapacity.TotalMemoryGB > 0 {
			snap.totalMemoryGB = p.BackendCapacity.TotalMemoryGB
		}
		for _, slot := range p.BackendCapacity.Slots {
			if slot.Model != model {
				continue
			}
			snap.slotState = slot.State
			snap.backendRunning = int(slot.NumRunning)
			snap.backendWaiting = int(slot.NumWaiting)
			snap.maxTokensPotential = slot.MaxTokensPotential
			snap.observedDecodeTPS = slot.ObservedDecodeTPS
			snap.observedPrefillTPS = slot.ObservedPrefillTPS
			snap.activeTokenBudgetUsed = slot.ActiveTokenBudgetUsed
			snap.activeTokenBudgetMax = slot.ActiveTokenBudgetMax
			snap.queuedTokenBudget = slot.QueuedTokenBudget
			snap.kvBytesPerToken = clampKVBytesPerToken(slot.KVBytesPerToken)
			snap.stepsExecuted = slot.StepsExecuted
			snap.admits = slot.Admits
			snap.firstTokensEmitted = slot.FirstTokensEmitted
			snap.secondsSinceLastStep = slot.SecondsSinceLastStep
			snap.secondsSinceLastFirstToken = slot.SecondsSinceLastFirstToken
			snap.wedgeSuspected = slot.WedgeSuspected
			snap.evalInFlightMs = slot.EvalInFlightMs
			snap.idleClearInFlightMs = slot.IdleClearInFlightMs
			break
		}
	}
	snap.modelLoaded = slotStateModelLoaded(snap.slotState)
	snap.availableOnDisk = !snap.modelLoaded
	snap.fleetMedianTPS = r.tpsRegistry.Median(model, p.Hardware.ChipFamily)

	// Gray-box budget clamp (budget_clamp.go): when a capacity-503 has proven
	// the pair's live gate is rejecting, admission must not believe the
	// stale-optimistic heartbeat budget. Evaluated for budgetless snapshots
	// too — a reconnected session has no BackendCapacity until its first
	// heartbeat, and a clamp armed on a budget-reporting pair must keep
	// holding through that window instead of shedding onto the legacy memory
	// path (never-budget-reporting legacy pairs stay exempt inside the check).
	// p.LastHeartbeat is when the CURRENT BackendCapacity was delivered
	// (Heartbeat stamps both in one critical section), which is what the
	// release-freshness check compares against the clamp time. p.mu and r.mu
	// are both held here (see lock discipline above).
	rawRemaining := snap.activeTokenBudgetMax - snap.activeTokenBudgetUsed - snap.queuedTokenBudget
	snap.budgetClamped = r.budgetClampActiveLocked(p.ID, model, p.LastHeartbeat, rawRemaining, snap.activeTokenBudgetMax > 0, now)

	return snap, true, GateReasonCount
}

// heartbeatAgeMs is now − lastHeartbeat in milliseconds, clamped to int32
// (a zero LastHeartbeat saturates rather than producing a nonsense value).
func heartbeatAgeMs(now, lastHeartbeat time.Time) int32 {
	if lastHeartbeat.IsZero() {
		return clampMsInt32(int64(^uint32(0) >> 1))
	}
	return clampMsInt32(now.Sub(lastHeartbeat).Milliseconds())
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

// backendFreeForLoadGB returns the provider-reported free_for_load_gb (nil-safe).
// Caller must hold the provider lock when passing p.BackendCapacity.
func backendFreeForLoadGB(bc *protocol.BackendCapacity) *float64 {
	if bc == nil {
		return nil
	}
	return bc.FreeForLoadGB
}

// reportedFreeForLoadAdmits reports whether a cold load of a model with the given
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
// only coldTokenBudgetEstimate — the POST-load arithmetic. binaryVersion
// and modelID are accepted for parity with that estimate's selection and
// for future load-peak measurements; today they are deliberately unused.
func reportedFreeForLoadAdmits(
	catalogSizeGB float64, freeForLoadGB *float64, binaryVersion, modelID string,
) (admit bool, reported bool) {
	_, _ = binaryVersion, modelID
	if freeForLoadGB == nil || catalogSizeGB <= 0 {
		return false, false
	}
	return catalogSizeGB*coldLoadCatalogGBToMemGiB <= *freeForLoadGB, true
}

// freeMemoryAdmits returns true when the provider has enough headroom.
// Providers that report a token budget use budget-based admission;
// legacy providers fall back to memory-based estimation.
func freeMemoryAdmits(snap routingSnapshot, reqPromptTokens, reqMaxTokens int) bool {
	// Gray-box budget clamp: a capacity-503 proved the provider's live gate
	// rejects while the heartbeat budget below still advertises headroom
	// (stale-optimistic). While the clamp holds, the slot is FULL — no
	// request fits — until the provider proves recovery (fresh heartbeat with
	// headroom + an accept) or the clamp TTL fail-opens. Checked BEFORE the
	// budget branch: a clamped budget-reporting pair whose current session
	// has no budget snapshot yet (reconnect before the first heartbeat) must
	// reject here, not fall through to the legacy memory path below. See
	// budget_clamp.go.
	if snap.budgetClamped {
		return false
	}
	requestTokens := int64(reqPromptTokens) + int64(reqMaxTokens)
	// Engine V2 keeps reporting a positive KV rate when its live fleet clamp
	// drives this model's budget to zero. That is authoritative known-full
	// capacity, not the legacy "budget unavailable" shape (both fields absent).
	// Bind it before consulting co-resident pooled headroom: another model's
	// positive budget cannot widen this model-local zero.
	if knownZeroTokenBudget(snap.activeTokenBudgetMax, snap.kvBytesPerToken) {
		return false
	}
	if snap.activeTokenBudgetMax > 0 {
		// Include coordinator-side pending tokens not yet reflected in the
		// provider's heartbeat. Avoid double-counting active/queued backend
		// budgets that are still present in the coordinator pending set until
		// completion/cancellation removes them.
		coordinatorExtra := int64(snap.pendingMaxTokens) - committedTokenBudget(snap)
		if coordinatorExtra < 0 {
			coordinatorExtra = 0
		}
		if snap.activeTokenBudgetUsed+snap.queuedTokenBudget+coordinatorExtra+requestTokens > snap.activeTokenBudgetMax {
			return false
		}
		// The per-slot max encodes this model's own context/KV ceiling. Through
		// v0.7.4 each slot embeds the same shared headroom; v0.7.5+ reports a
		// private re-sliced grant. The request must also fit the correctly
		// reconstructed whole-box pool with EVERY model's
		// coordinator-pending tokens charged — byte-normalized per slot KV rate
		// when reported, since co-resident models spend the pool at different
		// bytes/token (see pooled_admission.go). Reduces exactly to the per-slot
		// check for single-model providers.
		return pooledBudgetAdmits(snap, requestTokens)
	}

	// Cold-slot pooled gate: this model reports no budget slot (not loaded
	// here), but when ANY resident slot reports a token budget this request lands
	// in the same box after load. In-gap pending on a resident model must not be double-spendable
	// by a cold request that skips the budget branch above. The reconstructed
	// pool charges all-models coordinator pending plus this request; a cold
	// model has no reported KV rate (snap.kvBytesPerToken == 0), so on a
	// byte-reconstructable pool it is priced conservatively in bytes at the
	// bounded unknown-model default (resolvedPooledKVBytesPerToken),
	// falling to token units only when the pool is not byte-reconstructable.
	// No-op for legacy providers with neither budget nor KV-rate reports.
	if !pooledBudgetAdmits(snap, requestTokens) {
		return false
	}

	if !snap.modelLoaded {
		if fits, known := providerBudgetFits(snap, reqPromptTokens, reqMaxTokens); known && !fits {
			return false
		}
	}

	if snap.modelSizeGB <= 0 || snap.totalMemoryGB <= 0 {
		return true
	}
	required := snap.modelSizeGB
	if snap.modelLoaded {
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
	kvCacheGB := float64(tokens*kvCacheBytesPerToken) / float64(bytesPerGB)
	required += kvCacheGB

	// When the model is available on disk but not currently loaded, the
	// provider will evict idle models to make room (LRU eviction), so we check
	// whether the model can be loaded rather than requiring it to fit alongside
	// existing loaded models. The provider handles the swap autonomously.
	//
	// However, if the provider has in-flight requests (totalPending > 0), it
	// cannot evict the currently-serving model. In that case, fall through to the
	// standard free-memory check which requires room alongside active models.
	if snap.availableOnDisk && !snap.modelLoaded && snap.totalPending == 0 {
		// Preferred: the provider reports freeForLoadGB — the max model WEIGHT it
		// can load right now, already net of the 90% unified cap, OS/operator
		// reserve, activation+min-KV headroom, real OS-available memory, and
		// eviction of idle models. The single source of truth, normalized to the
		// provider's padded-GiB load basis so it exactly mirrors the provider's own
		// ModelLoadAdmission gate (no over-admit → OOM, no under-admit on evictable
		// weights).
		if admit, reported := reportedFreeForLoadAdmits(snap.modelSizeGB, snap.freeForLoadGB, snap.binaryVersion, snap.model); reported {
			return admit
		}
		// Fallback for legacy providers that don't report freeForLoadGB: the old
		// total-memory heuristic (provider evicts idle models, so compare against
		// total rather than free). Coarser — can't see the unified cap or OS
		// baseline — but only used until the fleet reports the field.
		const osReserveGB = 4.0
		return snap.modelSizeGB+kvCacheGB+osReserveGB <= snap.totalMemoryGB
	}

	free := snap.totalMemoryGB - snap.gpuMemoryActiveGB
	return free >= required
}

// fillSnapshotPendingAndPool populates snap's reconstructed pooled budget and
// its coordinator-pending aggregates — the per-model filtered pair
// (pendingForModel / pendingMaxTokens) and the all-models totals in token and,
// when normalizable, byte units. Byte normalization uses each resident model's
// reported KVBytesPerToken and the same bounded conservative default as
// incoming/capacity math for a cold model with no resident slot. Only a legacy
// pool that cannot be reconstructed in bytes leaves pendingBytesKnown false.
// Shared by the dispatch
// snapshot (snapshotProviderLockedEx) and the queue preflight
// (QuickCapacityCheck…) so the two admission paths cannot drift. Caller holds
// p.mu.
func fillSnapshotPendingAndPool(snap *routingSnapshot, p *Provider, model string) {
	if p.BackendCapacity != nil {
		snap.pooledTokenBudget = providerPooledTokenBudgetForVersion(
			p.BackendCapacity.Slots, p.Version)
	}
	bytesKnown := snap.pooledTokenBudget.byteMode
	for _, pr := range p.pendingReqs {
		tokens := pendingTokenBudget(pr)
		snap.pendingMaxTokensAllModels += tokens
		if bytesKnown {
			rate := resolvedPooledKVBytesPerToken(snap.pooledTokenBudget, snap.pooledTokenBudget.kvBytesPerToken[pr.Model])
			snap.pendingMaxBytesAllModels = addPooledKVByteCharge(snap.pendingMaxBytesAllModels, int64(tokens), rate)
		}
		if pr.Model != model {
			continue
		}
		snap.pendingForModel++
		snap.pendingMaxTokens += tokens
	}
	snap.pendingBytesKnown = bytesKnown
}

func pendingTokenBudget(pr *PendingRequest) int {
	if pr == nil {
		return 0
	}
	prompt := pr.EstimatedPromptTokens
	if prompt < 0 {
		prompt = 0
	}
	maxTok := pr.RequestedMaxTokens
	if maxTok <= 0 {
		maxTok = defaultRequestedMaxTokens
	}
	return prompt + maxTok
}

func committedTokenBudget(snap routingSnapshot) int64 {
	committed := snap.activeTokenBudgetUsed + snap.queuedTokenBudget
	if snap.maxTokensPotential > committed {
		committed = snap.maxTokensPotential
	}
	if committed < 0 {
		return 0
	}
	return committed
}

// buildCandidateGateLocked returns the cost-ranked candidate for a snapshot
// that passed the routing gates, or — on rejection — the candidateRejection
// class the legacy counters split on (capacity / model-too-large / vision) AND
// the closed GateReason naming the exact drop, including the drops the
// candidateRejection enum reports as rejectNone (crashed/reloading slot,
// thermal critical), so the system-profiler routing record can tally them.
// The counter semantics of candidateRejection are unchanged. Caller holds r.mu.
// buildCandidateWithReason is the pre-profiler shape of buildCandidateGateLocked
// (no GateReason) kept for the commit phase and the dispatch-plan revalidation.
func (r *Registry) buildCandidateWithReason(snap routingSnapshot, pr *PendingRequest) (*routingCandidate, candidateRejection, bool) {
	candidate, reason, _, ok := r.buildCandidateGateLocked(snap, pr)
	return candidate, reason, ok
}

func (r *Registry) buildCandidateGateLocked(snap routingSnapshot, pr *PendingRequest) (*routingCandidate, candidateRejection, GateReason, bool) {
	statePenalty, eligible := slotStatePenalty(snap.slotState)
	if !eligible {
		if snap.slotState == "crashed" {
			return nil, rejectNone, GateSlotCrashed, false
		}
		return nil, rejectNone, GateSlotReloading, false
	}
	if !snap.hasHeadroom {
		return nil, rejectCapacity, GateNoHeadroom, false
	}

	if snap.systemMetrics.ThermalState == "critical" {
		return nil, rejectNone, GateThermalCritical, false
	}

	reqMax := pr.RequestedMaxTokens
	if reqMax <= 0 {
		reqMax = defaultRequestedMaxTokens
	}
	reqPrompt := pr.EstimatedPromptTokens
	if reqPrompt < 0 {
		reqPrompt = 0
	}

	// Absolute hardware-fit gate (cold-load only, both admission modes). A model
	// whose footprint can never fit in this node's total memory must not be
	// routed here regardless of advertised token budget — otherwise the provider
	// 503s at load time ("Insufficient memory … need Y GB") and the request
	// bounces. This is the hole that let a 93.7 GB model get dispatched to 48/64
	// GB boxes: the token-budget admission path below never checked physical fit.
	//
	// Skip the gate whenever the model is already RESIDENT — a resident model has
	// demonstrably fit, so the heuristic must never reject it. The provider
	// reports "running" while actively serving and "idle" when loaded with no
	// in-flight requests (BatchScheduler+Telemetry: activeRequests>0 ? running :
	// idle); BOTH mean the weights are in GPU memory. `snap.modelLoaded` only
	// tracks "running", so we check the slot state directly here — otherwise an
	// idle-but-loaded provider would be wrongly excluded. Reported as
	// rejectModelTooLarge (permanent, not capacity).
	if !slotStateModelLoaded(snap.slotState) && !modelFitsHardware(snap.minRAMGb, snap.modelSizeGB, snap.totalMemoryGB) {
		return nil, rejectModelTooLarge, GateModelTooLarge, false
	}

	// Free-memory admission gate (Phase 1). A provider that claims to
	// serve the model but doesn't have headroom for weights + KV cache
	// is rejected here so we don't OOM the backend post-routing.
	if !freeMemoryAdmits(snap, reqPrompt, reqMax) {
		return nil, rejectCapacity, GateFreeMemory, false
	}

	effectiveQueue := snapshotOccupancy(snap)

	waitingBacklogTokens := float64(snap.backendWaiting * reqMax)
	unaccountedPendingTokens := float64(snap.pendingMaxTokens) - float64(snap.maxTokensPotential) - waitingBacklogTokens
	if unaccountedPendingTokens < 0 {
		unaccountedPendingTokens = 0
	}

	effectiveTPS := resolveEffectiveTPS(snap)

	queueMs := float64(effectiveQueue) * queueDepthPenaltyMs
	pendingMs := float64(snap.totalPending) * totalPendingPenaltyMs
	var backlogMs float64
	if snap.activeTokenBudgetMax > 0 {
		tokensAhead := float64(snap.activeTokenBudgetUsed) + float64(snap.queuedTokenBudget)
		backlogMs = tokensAhead / effectiveTPS * 1000.0
	} else {
		backlogMs = backlogTokenMs(snap.maxTokensPotential, waitingBacklogTokens, unaccountedPendingTokens, effectiveTPS)
	}
	// Prefill resolves through resolvePrefillTPS for BOTH the base cost term and
	// the long-prompt bias below, so provider ranking follows the live measured
	// prefill EWMA when a slot reports one and only falls back to the static
	// registration/x12 chain when it does not. Reading snap.prefillTPS directly
	// here pinned the dominant prefill term to the static rate, which left a box
	// whose measured prefill had degraded looking as cheap as its benchmark.
	prefillTPS := resolvePrefillTPS(snap)
	thisReqMs := float64(reqPrompt)/prefillTPS*1000.0 + float64(reqMax)/effectiveTPS*1000.0
	// Long-prompt fastest-tier preference: amplify the first-token-blocking time
	// for very long prompts so the provider that reaches first token soonest is
	// strongly preferred, reducing pre-first-token client_gone. The amplified
	// quantity is the FULL time-to-first-token (TTFT): prefill PLUS, for a COLD
	// provider, the model-load latency (statePenalty, ~30s). Prefill uses
	// resolvePrefillTPS (the live, observed-preferred prefill signal) — not the
	// static rate — so the bias follows real measured prefill and does not favor a
	// box whose static rate looks good but whose measured prefill is degraded.
	// Amplifying the full cold-load+prefill TTFT — not just prefill — prevents the
	// long-prompt bias from pulling a long prompt onto a cold box whose fast
	// prefill is dwarfed by the load and which is therefore slower end-to-end than
	// the fastest warm provider. Folded into thisReqMs so the cost breakdown
	// invariant (sum of terms == Total) holds. Returns 0 — and so leaves the cost
	// byte-for-byte unchanged — for short prompts and when the knob is off.
	prefillMs := float64(reqPrompt) / prefillTPS * 1000.0
	ttftBlockMs := prefillMs
	if !snap.modelLoaded {
		// A cold provider must load before it can prefill; amplify its full
		// first-token latency (load + prefill), not just prefill, so the long-
		// prompt bias does not pull a long prompt onto a cold box that is slower
		// end-to-end than the fastest warm provider.
		ttftBlockMs += statePenalty
	}
	thisReqMs += longPromptPenalty(reqPrompt, ttftBlockMs)
	healthMs := healthPenaltyMs(snap.systemMetrics, snap.gpuMemoryActiveGB, snap.totalMemoryGB)
	// Gray-box capacity-503 rate penalty (capacity_rate.go): a pair rejecting
	// a material fraction of dispatches with capacity 503s — while serving the
	// rest, so no zero-accepts breaker can see it — sinks in cost ranking
	// proportionally to its windowed reject rate. A soft derater, never an
	// ejection: the candidate stays in the pool, so a degraded-but-only fleet
	// still serves, and the penalty decays as outcomes age out of the window.
	capacityRateMs, capacityRejectRate := r.capacityRatePenaltyLocked(snap.provider.ID, snap.model, time.Now())
	cost := statePenalty + queueMs + pendingMs + backlogMs + thisReqMs + healthMs + capacityRateMs

	// Estimated time-to-first-token for this candidate. Used for the
	// OpenRouter TTFT ceiling: public routes only select providers whose
	// estimated TTFT is within the per-request threshold. Providers without
	// BackendCapacity get 0 (unreliable estimate) and are not rejected by the
	// ceiling, matching the preflight behavior. The gate/ceiling input is the
	// CALIBRATED estimate (raw × learned actual/predicted ratio, see
	// ttft_calibration.go); the raw value is kept alongside so the calibrator
	// learns against what the formula actually predicted.
	rawTTFTMs := ttftMsFromSnapshot(snap, reqPrompt)
	if rawTTFTMs <= 0 || math.IsNaN(rawTTFTMs) || math.IsInf(rawTTFTMs, 0) {
		rawTTFTMs = 0
	}
	// Read the calibration ratio once and score with it, so the ratio the
	// profiler records is exactly the one this candidate was gated on.
	calibrationRatio := ttftCalibration.appliedRatio(snap.model, snap.chipFamily)
	ttftMs := calibratedTTFTMsWithRatio(snap, rawTTFTMs, calibrationRatio)

	return &routingCandidate{
		provider:           snap.provider,
		calibrationRatio:   calibrationRatio,
		snapshot:           snap,
		costMs:             cost,
		effectiveQueue:     effectiveQueue,
		effectiveTPS:       effectiveTPS,
		capacityRejectRate: capacityRejectRate,
		breakdown: costBreakdown{
			StateMs:        statePenalty,
			QueueMs:        queueMs,
			PendingMs:      pendingMs,
			BacklogMs:      backlogMs,
			ThisReqMs:      thisReqMs,
			HealthMs:       healthMs,
			CapacityRateMs: capacityRateMs,
			TTFTMs:         ttftMs,
			RawTTFTMs:      rawTTFTMs,
			Total:          cost,
		},
	}, rejectNone, GateReasonCount, true
}

func slotStatePenalty(state string) (float64, bool) {
	switch state {
	case "", "running", "idle":
		return slotStatePenaltyRunning, true
	case "unknown":
		// Model is available but not loaded. The provider must evict the
		// current model and load this one — typically 15–60 seconds for
		// large models (depends on model size and disk speed). Warm
		// providers are strongly preferred but cold providers are still
		// eligible when no warm alternative exists.
		return slotStatePenaltyUnknown, true
	case "idle_shutdown":
		return slotStatePenaltyIdleShutdown, true
	case "reloading", "crashed":
		return math.Inf(1), false
	default:
		return slotStatePenaltyUnknown, true
	}
}

func slotStateModelLoaded(state string) bool {
	return state == "running" || state == "idle"
}

func backlogTokenMs(maxTokensPotential int64, waitingTokens, unaccountedPendingTokens, decodeTPS float64) float64 {
	if decodeTPS <= 0 {
		decodeTPS = 1.0
	}
	totalTokensAhead := float64(maxTokensPotential) + waitingTokens + unaccountedPendingTokens
	if totalTokensAhead < 0 {
		totalTokensAhead = 0
	}
	return totalTokensAhead / decodeTPS * 1000.0
}

func healthPenaltyMs(m protocol.SystemMetrics, gpuActiveGB, totalMemGB float64) float64 {
	penalty := m.MemoryPressure*memoryPressurePenaltyMs + m.CPUUsage*cpuUsagePenaltyMs
	switch m.ThermalState {
	case "fair":
		penalty += thermalPenaltyFairMs
	case "serious":
		penalty += thermalPenaltySeriousMs
	}
	if totalMemGB > 0 {
		gpuUtil := gpuActiveGB / totalMemGB
		if gpuUtil < 0 {
			gpuUtil = 0
		}
		if gpuUtil > 1 {
			gpuUtil = 1
		}
		penalty += gpuUtil * gpuUtilizationPenaltyMs
	}
	return penalty
}

// resolveEffectiveTPS returns the best available decode TPS estimate.
// Fallback chain: observed EWMA → fleet median → load-scaled benchmark.
func resolveEffectiveTPS(snap routingSnapshot) float64 {
	if snap.observedDecodeTPS > 0 {
		return snap.observedDecodeTPS
	}
	if snap.fleetMedianTPS > 0 {
		return snap.fleetMedianTPS
	}
	return effectiveDecodeTPS(snap.decodeTPS, snap.backendRunning)
}

// resolvePrefillTPS returns the best available prefill TPS estimate for TTFT.
// Fallback chain: measured per-slot observed prefill EWMA → snap.prefillTPS (the
// resolvedPrefillTPS chain: registration benchmark → decode×prefillToDecodeRatio
// ×12 fallback). This mirrors how resolveEffectiveTPS prefers the measured
// decode rate over the static estimate. The result is clamped to maxPrefillTPS
// so a single outlier heartbeat cannot collapse the TTFT estimate.
//
// observedPrefillTPS stays 0 until providers ship the W1 measurement, so on
// today's fleet this is a no-op that returns the existing ×12-chain value.
func resolvePrefillTPS(snap routingSnapshot) float64 {
	tps := snap.prefillTPS
	if snap.observedPrefillTPS > 0 {
		tps = snap.observedPrefillTPS
	}
	if tps > maxPrefillTPS {
		tps = maxPrefillTPS
	}
	return tps
}

// effectiveDecodeTPS scales the static decode TPS down by current
// backend batch size. Returns the static value when the load factor is
// disabled or batch is unknown. Floored at 1 token/s to avoid divide-
// by-zero.
//
// Note on the floor + large reqMax: when effectiveTPS bottoms out, the
// per-request decode cost (reqMax / effectiveTPS * 1000) can become
// very large for big reqMax values. This is intentional — a saturated
// provider should look strictly worse than less-saturated peers — and
// the maxConcurrency gate in snapshotProviderLocked already prevents
// us from getting here when batchSize exceeds the per-tier cap.
func effectiveDecodeTPS(staticTPS float64, backendRunning int) float64 {
	if staticTPS <= 0 {
		return 1.0
	}
	if effectiveTPSLoadFactor <= 0 || backendRunning <= 0 {
		return staticTPS
	}
	tps := staticTPS / (1.0 + effectiveTPSLoadFactor*float64(backendRunning))
	if tps < 1.0 {
		tps = 1.0
	}
	return tps
}

// snapshotOccupancy is the per-(provider,model) in-flight occupancy the
// coordinator already tracks: max(pendingForModel, backend_running +
// backend_waiting). pendingForModel is the coordinator's own dispatched-but-not-
// yet-terminal count (incremented at reserve, held the whole dark-time), so this
// is herd-aware even when the heartbeat gauge still reads backend_running=0 — no
// parallel reservation counter is needed. It is the same quantity the routing
// cost's effectiveQueue and the quality-concurrency cap consume; the Phase-0
// occupancy-aware TTFT term and the shadow admission/spread evaluator reuse it so
// every occupancy-keyed decision reads one signal.
func snapshotOccupancy(snap routingSnapshot) int {
	occ := snap.pendingForModel
	if backendDepth := snap.backendRunning + snap.backendWaiting; backendDepth > occ {
		occ = backendDepth
	}
	if occ < 0 {
		occ = 0
	}
	return occ
}

func resolvedDecodeTPS(p *Provider) float64 {
	if p.DecodeTPS > 0 {
		return p.DecodeTPS
	}
	bw := float64(p.Hardware.MemoryBandwidthGBs)
	if bw > 0 {
		return math.Sqrt(bw)
	}
	return 1.0
}

// resolvedModelTPSLocked returns the best per-model decode/prefill TPS samples
// for a provider. BackendCapacity.Slots is authoritative for Swift providers:
// when the matching slot reports observed EWMAs, prefer them over static
// registration benchmarks. Non-positive observed values are treated as missing.
// Caller must hold p.mu.
func resolvedModelTPSLocked(p *Provider, model string) (decodeTPS, prefillTPS float64) {
	decodeTPS = resolvedDecodeTPS(p)
	prefillTPS = resolvedPrefillTPS(p)
	if p.BackendCapacity == nil {
		return decodeTPS, prefillTPS
	}
	for _, slot := range p.BackendCapacity.Slots {
		if slot.Model != model {
			continue
		}
		if slot.ObservedDecodeTPS > 0 {
			decodeTPS = slot.ObservedDecodeTPS
		}
		if slot.ObservedPrefillTPS > 0 {
			prefillTPS = slot.ObservedPrefillTPS
		}
		break
	}
	return decodeTPS, prefillTPS
}

// defaultPrefillToDecodeRatio is the fallback multiplier applied to a provider's
// decode TPS to estimate its prefill TPS when the provider does not report a
// measured prefill rate (prefill_tps). Apple-Silicon MLX prefills the prompt in
// large parallel batches, so prefill throughput is roughly an order of magnitude
// above decode throughput. The historical 4x was far too conservative: combined
// with the 5s+1ms/token TTFT deadline it estimated ~100 tok/s prefill (vs the
// ~1000 tok/s the deadline implicitly assumes), so the TTFT gate wrongly
// rejected warm, capable providers on any prompt above ~550 tokens. No provider
// currently reports prefill_tps, so this fallback is the production path.
const defaultPrefillToDecodeRatio = 12.0

// prefillToDecodeRatio is configured once at startup (via SetPrefillToDecodeRatio,
// e.g. from EIGENINFERENCE_PREFILL_DECODE_RATIO) before the server begins
// serving, then only read on routing paths.
var prefillToDecodeRatio = defaultPrefillToDecodeRatio

// SetPrefillToDecodeRatio overrides the decode→prefill fallback multiplier.
// Values <= 0 are ignored. Must be called before serving starts (read-only after).
func SetPrefillToDecodeRatio(ratio float64) {
	if ratio > 0 {
		prefillToDecodeRatio = ratio
	}
}

// PrefillToDecodeRatio returns the current decode→prefill fallback multiplier
// (the value used by resolvedPrefillTPS when a provider does not report a
// measured prefill rate). Exposed for the routing simulation harness.
func PrefillToDecodeRatio() float64 {
	return prefillToDecodeRatio
}

// ttftOccupancyAlpha scales the Phase-0 occupancy term (see ttftOccupancyMs),
// which is added ONLY inside occupancyAwareTTFTMsFromSnapshot — the shadow
// evaluator's estimate — NEVER inside the live ttftMsFromSnapshot. It is the
// decode-token-times of head-of-line wait charged per occupying peer, divided by
// the per-request decode rate the new request would see. Because the term never
// reaches ttftMsFromSnapshot, the routing cost's TTFTMs, the candidate-loop
// MaxTTFTMs ceiling, and the preflight bestTTFT are occupancy-free at ANY alpha:
// raising alpha changes only the shadow signal, not the live routing decision
// (the HARD_REJECT safety invariant — see occupancyAwareTTFTMsFromSnapshot). 0
// (the default) also makes ttftOccupancyMs itself a no-op. Configured once at
// startup via SetTTFTOccupancyAlpha (EIGENINFERENCE_TTFT_OCCUPANCY_ALPHA),
// read-only on routing paths thereafter, mirroring prefillToDecodeRatio.
var ttftOccupancyAlpha = 0.0

// SetTTFTOccupancyAlpha overrides the occupancy-term coefficient. Negative
// values are clamped to 0 (term disabled). Must be called before serving starts.
func SetTTFTOccupancyAlpha(alpha float64) {
	if alpha < 0 {
		alpha = 0
	}
	ttftOccupancyAlpha = alpha
}

// TTFTOccupancyAlpha returns the configured occupancy-term coefficient.
func TTFTOccupancyAlpha() float64 {
	return ttftOccupancyAlpha
}

// defaultLongPromptThresholdTokens gates the long-prompt fastest-tier routing
// preference. 0 disables it entirely (behavior-neutral): the routing
// cost is unchanged for every request, short or long. A positive value turns the
// preference ON for requests whose estimated prompt is at or above the threshold.
const defaultLongPromptThresholdTokens = 0

// defaultLongPromptPrefillWeight is the multiplier applied to the prefill term of
// the routing cost for long prompts. 1.0 is behavior-neutral; >1 amplifies the
// prefill component so the fastest-prefill (== fastest chip tier) warm provider is
// strongly preferred once the prompt is long enough that prefill dominates TTFT.
const defaultLongPromptPrefillWeight = 2.0

// longPromptThresholdTokens / longPromptPrefillWeight are configured once at
// startup (via SetLongPromptThreshold / SetLongPromptPrefillWeight, e.g. from
// EIGENINFERENCE_LONG_PROMPT_TOKENS) before serving begins, then only read on the
// routing path. Default-off so the scheduler is byte-for-byte unchanged unless an
// operator opts in.
var (
	longPromptThresholdTokens = defaultLongPromptThresholdTokens
	longPromptPrefillWeight   = defaultLongPromptPrefillWeight
)

// SetLongPromptThreshold sets the estimated-prompt-token count at/above which the
// long-prompt fastest-tier routing preference activates. A value <= 0 disables the
// preference (behavior-neutral). Must be called before serving starts.
func SetLongPromptThreshold(tokens int) {
	if tokens < 0 {
		tokens = 0
	}
	longPromptThresholdTokens = tokens
}

// LongPromptThreshold returns the current long-prompt token threshold (0 = off).
func LongPromptThreshold() int {
	return longPromptThresholdTokens
}

// SetLongPromptPrefillWeight overrides the prefill-term multiplier used for long
// prompts. Non-finite values (NaN/±Inf — which slip through a naive `< 1` clamp
// because NaN comparisons are always false, then poison every candidate cost) are
// reset to the default. Values < 1 are clamped to 1.0 (no amplification). Must be
// called before serving starts.
func SetLongPromptPrefillWeight(w float64) {
	weight := w
	if math.IsNaN(weight) || math.IsInf(weight, 0) {
		weight = defaultLongPromptPrefillWeight
	}
	if weight < 1.0 {
		weight = 1.0
	}
	longPromptPrefillWeight = weight
}

// LongPromptPrefillWeight returns the current long-prompt prefill-term multiplier.
func LongPromptPrefillWeight() float64 {
	return longPromptPrefillWeight
}

// longPromptPenalty returns the EXTRA first-token-blocking cost (ms) added to a
// candidate's per-request cost so very long prompts prefer the provider that
// reaches first token soonest. It amplifies the supplied time-to-first-token
// (ttftBlockMs) by (weight-1). The caller passes the FULL TTFT: prefill for a warm
// provider, or model-load latency + prefill for a cold one. Amplifying the full
// TTFT (rather than prefill alone) means a cold box's fast prefill cannot win a
// long prompt when its ~30s load makes it slower end-to-end than the fastest warm
// provider, while a warm provider with twice the prefill throughput still sees
// half the penalty so the fastest chip-tier wins decisively.
//
// Returns 0 (fully behavior-preserving) when the preference is disabled
// (threshold <= 0), the prompt is below the threshold (short prompts unaffected),
// the weight is neutral (<= 1), or the blocking time is non-positive. It is a SOFT
// ranking bias only: no candidate is dropped and no TTFT 429 is introduced.
func longPromptPenalty(reqPromptTokens int, ttftBlockMs float64) float64 {
	if longPromptThresholdTokens <= 0 || reqPromptTokens < longPromptThresholdTokens {
		return 0
	}
	if ttftBlockMs <= 0 || longPromptPrefillWeight <= 1.0 {
		return 0
	}
	return (longPromptPrefillWeight - 1.0) * ttftBlockMs
}

func resolvedPrefillTPS(p *Provider) float64 {
	if p.PrefillTPS > 0 {
		return p.PrefillTPS
	}
	return resolvedDecodeTPS(p) * prefillToDecodeRatio
}

// projectedPerRequestDecodeTPS estimates the decode tokens/sec a NEWLY admitted
// request would receive on this snapshot's provider once it joins the batch
// (backendRunning+1 concurrent). Continuous batching is memory-bandwidth bound,
// so per-request decode degrades with batch size by the same effectiveTPSLoadFactor
// model used elsewhere: rate(b) = solo / (1 + k·b). The measured observed decode
// rate (when present) is unwound from the current batch to a solo rate and then
// reapplied at b+1; otherwise the static benchmark is the solo proxy. Used by the
// decode-floor quality preference (PendingRequest.MinDecodeTPS).
func projectedPerRequestDecodeTPS(snap routingSnapshot) float64 {
	return projectedPerRequestDecodeTPSAtBatch(snap, snap.backendRunning)
}

// projectedPerRequestDecodeTPSAtBatch is projectedPerRequestDecodeTPS with an
// EXPLICIT batch the new request would join, used when the heartbeat gauge
// (backend_running) understates real contention. The observed-rate UNWIND always
// uses the batch the observation was actually taken at (snap.backendRunning —
// the heartbeat's observedDecodeTPS pairs with that gauge), while the REAPPLY
// uses joinBatch. Passing joinBatch == snap.backendRunning reproduces the
// original result exactly, so the decode-floor caller is byte-for-byte unchanged;
// the occupancy term passes joinBatch == occ so a herd that has already reserved
// peers the heartbeat has not yet reflected (occ > backend_running) is charged at
// the contended rate it will actually see — not the idle/low-batch rate.
func projectedPerRequestDecodeTPSAtBatch(snap routingSnapshot, joinBatch int) float64 {
	k := effectiveTPSLoadFactor
	if k < 0 {
		k = 0
	}
	bObserved := snap.backendRunning
	if bObserved < 0 {
		bObserved = 0
	}
	if joinBatch < 0 {
		joinBatch = 0
	}
	// Solo (b=0) decode-rate base, durable 3-tier chain:
	solo := snap.decodeTPS // tier 3: static benchmark (last resort)
	switch {
	case snap.observedDecodeTPS > 0:
		// tier 1: this box's own LIVE measured rate, unwound from the batch it
		// was measured at (bObserved) to solo.
		solo = snap.observedDecodeTPS * (1 + k*float64(bObserved))
	case decodeFloorUseFleetMedian() && snap.fleetMedianTPS > 0:
		// tier 2: durable per-(model,chip) observed median from the tps registry.
		// Exists even when this box is IDLE, so a historically-slow chip (e.g. the
		// ~9 tok/s gemma boxes driving client_gone) is deprioritized BEFORE it gets
		// packed — the static benchmark (~23) otherwise made idle slow boxes look
		// fast. Conservative for a quality floor: a median that understates true
		// solo biases AWAY from borderline boxes (the safe direction).
		solo = snap.fleetMedianTPS
	}
	if solo <= 0 {
		return 0
	}
	return solo / (1 + k*float64(joinBatch+1))
}

// decodeFloorUseFleetMedian gates the tier-2 (fleet-median) solo-rate source in
// projectedPerRequestDecodeTPS. Read LIVE (no restart); default ON. Set
// EIGENINFERENCE_DECODE_FLOOR_USE_FLEET_MEDIAN=false for byte-for-byte pre-fix
// behavior (idle boxes fall straight to the static benchmark).
func decodeFloorUseFleetMedian() bool {
	return env.EnvBool(env.EnvPrefix+"_DECODE_FLOOR_USE_FLEET_MEDIAN", true)
}

func providerModelIDs(p *Provider) []string {
	if p == nil {
		return nil
	}
	// p.Models is replaced (copy-on-write) by UpdateModelWeightHashes when a
	// challenge response carries refreshed weight hashes, so the slice header
	// must be read under p.mu. All callers invoke this helper after releasing
	// p.mu (verified: Heartbeat, RecordChallengeSuccess, SetProviderIdle,
	// DrainQueuedRequestsForProvider), so taking the lock here cannot deadlock.
	p.mu.Lock()
	defer p.mu.Unlock()
	ids := make([]string, 0, len(p.Models))
	for _, m := range p.Models {
		ids = append(ids, m.ID)
	}
	return ids
}

// providerCanAdmitLockedEx is providerCanAdmitLocked with an explicit
// ignoreProviderBreaker switch. ReserveProviderEx sets it true ONLY when the
// selected winner is itself node-health-breaker-open — which can happen only
// because the selectBestCandidateLockedFull fail-open fallback pass chose it.
// Without this, the admit re-check would re-apply the breaker and reject the
// very candidate the fail-open valve just selected, derouting the fleet anyway.
// The default wrapper (breaker honored) is unchanged for every other caller.
// Caller holds r.mu and p.mu.
func (r *Registry) providerCanAdmitLockedEx(p *Provider, model string, traits RequestTraits, selfRouteOwner bool, ignoreProviderBreaker bool) bool {
	now := time.Now()
	if !r.providerPassesRoutingGatesLockedEx(p, model, traits, selfRouteOwner, now, ignoreProviderBreaker, false) {
		return false
	}
	// Apply the SAME quality-concurrency cap as the selection snapshot and the
	// preflight. This is the final admit re-check in ReserveProviderEx; if a
	// heartbeat bumped NumRunning after the snapshot was built, the legacy flat-cap
	// check here would let a box that just reached its quality cap be over-admitted.
	if !r.hasConcurrencyHeadroomForModelCapResolvedLocked(p, model) {
		return false
	}
	if p.BackendCapacity != nil {
		for _, slot := range p.BackendCapacity.Slots {
			if slot.Model != model {
				continue
			}
			switch slot.State {
			case "crashed", "reloading":
				return false
			}
			break
		}
	}
	return true
}

// QuickCapacityCheck performs a fast, read-only scan of the provider fleet to
// determine whether any provider could serve a request for the given model
// right now. It runs the SAME per-provider gates as the full routing path —
// via the shared providerPassesRoutingGatesLocked (status, trust, runtime,
// privacy, challenge freshness, dispatch-load + shape-keyed inference-error
// cooldowns, and the trait gates: render-broken fences every shape, the tools
// version floor fences tool requests) — plus the capacity gates (concurrency
// headroom, slot state, free memory) but does NOT reserve capacity or create
// pending requests. traits carry the request shape so the preflight excludes a
// provider for exactly the reasons routing would, instead of reporting phantom
// capacity that routing then refuses (the drift this consolidation closes).
//
// Returns:
//   - candidateCount: providers that passed ALL gates (could route right now)
//   - capacityRejections: providers that serve the model and passed structural
//     gates but were rejected for capacity reasons (full concurrency, no free
//     memory, etc.)
//
// This is used for the pre-flight 429 check: if candidateCount == 0 &&
// capacityRejections > 0, providers exist but are all at capacity (429).
// If candidateCount == 0 && capacityRejections == 0, no provider serves
// the model at all (404/503).
//
//   - modelTooLarge: providers that serve the model but whose memory can never
//     fit it. Kept separate from capacityRejections so the caller does NOT 429
//     a model that will never fit (the client would retry forever) — it should
//     surface model_too_large / 503 instead.
func (r *Registry) QuickCapacityCheck(model string, estimatedPromptTokens, requestedMaxTokens int, traits RequestTraits, allowedSerials ...string) (candidateCount, capacityRejections, modelTooLarge int) {
	candidateCount, capacityRejections, modelTooLarge, _, _ = r.quickCapacityCheck(model, estimatedPromptTokens, requestedMaxTokens, traits, false, allowedSerials...)
	return candidateCount, capacityRejections, modelTooLarge
}

func (r *Registry) QuickCapacityCheckForRequest(model string, estimatedPromptTokens, requestedMaxTokens int, traits RequestTraits, requiresVision bool, allowedSerials ...string) (candidateCount, capacityRejections, modelTooLarge int) {
	candidateCount, capacityRejections, modelTooLarge, _, _ = r.quickCapacityCheck(model, estimatedPromptTokens, requestedMaxTokens, traits, requiresVision, allowedSerials...)
	return candidateCount, capacityRejections, modelTooLarge
}

func (r *Registry) QuickCapacityCheckWithTTFTForRequest(model string, estimatedPromptTokens, requestedMaxTokens int, traits RequestTraits, requiresVision bool, allowedSerials ...string) (candidateCount, capacityRejections, modelTooLarge int, bestTTFT time.Duration, hasTTFT bool) {
	return r.quickCapacityCheck(model, estimatedPromptTokens, requestedMaxTokens, traits, requiresVision, allowedSerials...)
}

func (r *Registry) quickCapacityCheck(model string, estimatedPromptTokens, requestedMaxTokens int, traits RequestTraits, requiresVision bool, allowedSerials ...string) (candidateCount, capacityRejections, modelTooLarge int, bestTTFT time.Duration, hasTTFT bool) {
	// Use a dummy PendingRequest with the caller's actual token estimates
	// for the admission gate (freeMemoryAdmits).
	if estimatedPromptTokens <= 0 {
		estimatedPromptTokens = 500
	}
	if requestedMaxTokens <= 0 {
		requestedMaxTokens = defaultRequestedMaxTokens
	}
	dummyPR := &PendingRequest{
		RequestID:             "capacity-check",
		Model:                 model,
		EstimatedPromptTokens: estimatedPromptTokens,
		RequestedMaxTokens:    requestedMaxTokens,
	}

	// Build allowed serial set for optional provider filtering.
	allowedSet := make(map[string]struct{}, len(allowedSerials))
	for _, s := range allowedSerials {
		allowedSet[s] = struct{}{}
	}

	r.mu.RLock()
	defer r.mu.RUnlock()

	unknownTTFTCandidate := false
	now := time.Now()
	for _, p := range r.providers {
		// Filter by allowed serials before acquiring the provider lock
		// (providerMatchesAllowedSerial takes p.mu internally).
		if len(allowedSet) > 0 && !providerMatchesAllowedSerial(p, allowedSet) {
			continue
		}

		p.mu.Lock()

		// Per-provider routing gates (same source of truth as snapshotProviderLocked
		// and the admit re-check). This pre-flight only runs for public
		// (non-self-route) requests, so selfRouteOwner is false — private-only
		// machines are excluded unconditionally.
		//
		// ignoreProviderBreaker=true: the per-provider node-health
		// breaker is a SELECTION-time gate that fails open in the dispatch path
		// (selectBestCandidateScanLocked / ReserveProviderEx). The preflight must
		// fail open on it too — otherwise an all-breaker-open fleet reports 0
		// candidates AND 0 capacity-rejections here, and the consumer hard-503s
		// "no_provider" BEFORE dispatch's fail-open valve can serve a probe,
		// re-introducing the very model-wide outage the valve exists to prevent.
		// Every other gate (incl. the shape-keyed inference-error cooldown) is
		// still honored; the breaker still steers SELECTION away from bad nodes.
		if !r.providerPassesRoutingGatesLockedEx(p, model, traits, false, now, true, false) {
			// A pair blocked ONLY by the capacity-reject cooldown is TRANSIENT
			// capacity, not structural absence: the box exists, serves the model,
			// and will be re-probed when its TTL lapses. Count it as a
			// capacityRejection so an all-cooled model surfaces to the consumer
			// as capacity (429 + Retry-After / queue-before-shed) instead of a
			// "no providers" 503 — the cooldown must read as "busy fleet", never
			// as "the model vanished". The ignoreCapacityCooldown re-check keeps
			// a pair that ALSO fails a structural gate (offline, untrusted,
			// render-broken, …) out of the count. Structural filters applied
			// AFTER the gates on the main path must apply here too:
			// thermal-critical and vision-blind pairs are excluded outright
			// (same as the main path just below), and a pair whose model can
			// never fit the hardware counts as modelTooLarge — never as
			// transient capacity, or a fleet of undersized cooled boxes would
			// read as "busy, retry" for a model that will never fit.
			if r.capacityCooldownActiveLocked(p.ID, model, now) &&
				r.providerPassesRoutingGatesLockedEx(p, model, traits, false, now, true, true) &&
				p.SystemMetrics.ThermalState != "critical" &&
				(!requiresVision || r.providerServesVisionModelLocked(p, model, false)) {
				// Mirror the absolute hardware-fit gate (skipped for a
				// resident model, which has demonstrably fit).
				slotState := "unknown"
				totalMemGB := float64(p.Hardware.MemoryGB)
				if p.BackendCapacity != nil {
					if p.BackendCapacity.TotalMemoryGB > 0 {
						totalMemGB = p.BackendCapacity.TotalMemoryGB
					}
					for _, slot := range p.BackendCapacity.Slots {
						if slot.Model == model {
							slotState = slot.State
							break
						}
					}
				}
				if !slotStateModelLoaded(slotState) &&
					!modelFitsHardware(r.catalogMinRAMGbLocked(model), r.catalogSizeGBLocked(model), totalMemGB) {
					modelTooLarge++
				} else {
					capacityRejections++
				}
			}
			p.mu.Unlock()
			continue
		}
		if p.SystemMetrics.ThermalState == "critical" {
			p.mu.Unlock()
			continue
		}
		if requiresVision && !r.providerServesVisionModelLocked(p, model, false) {
			p.mu.Unlock()
			continue
		}

		// Concurrency gate (with the quality-concurrency cap, same as the dispatch
		// snapshot — resolves the model's own static solo rate internally so
		// routing and the shed preflight stay consistent and a slow model's
		// quality cap counts a saturated box as a capacity rejection here too).
		if !r.hasConcurrencyHeadroomForModelCapResolvedLocked(p, model) {
			p.mu.Unlock()
			capacityRejections++
			continue
		}

		// Build a snapshot for the admission gate (slot state + free memory).
		snap := routingSnapshot{
			provider:           p,
			model:              model,
			chipFamily:         p.Hardware.ChipFamily,
			binaryVersion:      p.Version,
			slotState:          "unknown",
			totalPending:       p.pendingCount(),
			systemMetrics:      p.SystemMetrics,
			decodeTPS:          resolvedDecodeTPS(p),
			prefillTPS:         resolvedPrefillTPS(p),
			totalMemoryGB:      float64(p.Hardware.MemoryGB),
			modelSizeGB:        r.modelSizeGBForFitLocked(p, model),
			minRAMGb:           r.catalogMinRAMGbLocked(model),
			hasBackendCapacity: p.BackendCapacity != nil,
		}
		fillSnapshotPendingAndPool(&snap, p, model)
		if snap.hasBackendCapacity {
			snap.gpuMemoryActiveGB = p.BackendCapacity.GPUMemoryActiveGB
			snap.freeForLoadGB = p.BackendCapacity.FreeForLoadGB
			if p.BackendCapacity.TotalMemoryGB > 0 {
				snap.totalMemoryGB = p.BackendCapacity.TotalMemoryGB
			}
			for _, slot := range p.BackendCapacity.Slots {
				if slot.Model != model {
					continue
				}
				snap.slotState = slot.State
				snap.backendRunning = int(slot.NumRunning)
				snap.backendWaiting = int(slot.NumWaiting)
				snap.observedDecodeTPS = slot.ObservedDecodeTPS
				snap.observedPrefillTPS = slot.ObservedPrefillTPS
				snap.activeTokenBudgetUsed = slot.ActiveTokenBudgetUsed
				snap.activeTokenBudgetMax = slot.ActiveTokenBudgetMax
				snap.queuedTokenBudget = slot.QueuedTokenBudget
				snap.maxTokensPotential = slot.MaxTokensPotential
				snap.kvBytesPerToken = clampKVBytesPerToken(slot.KVBytesPerToken)
				snap.stepsExecuted = slot.StepsExecuted
				snap.admits = slot.Admits
				snap.firstTokensEmitted = slot.FirstTokensEmitted
				snap.secondsSinceLastStep = slot.SecondsSinceLastStep
				snap.secondsSinceLastFirstToken = slot.SecondsSinceLastFirstToken
				snap.wedgeSuspected = slot.WedgeSuspected
				snap.evalInFlightMs = slot.EvalInFlightMs
				snap.idleClearInFlightMs = slot.IdleClearInFlightMs
				break
			}
		}
		snap.modelLoaded = slotStateModelLoaded(snap.slotState)
		snap.availableOnDisk = !snap.modelLoaded
		snap.fleetMedianTPS = r.tpsRegistry.Median(model, p.Hardware.ChipFamily)

		// Gray-box budget clamp — same evaluation as snapshotProviderLockedEx
		// (including the budgetless-snapshot hold for reconnecting sessions)
		// so the preflight cannot report capacity that routing then refuses.
		rawRemaining := snap.activeTokenBudgetMax - snap.activeTokenBudgetUsed - snap.queuedTokenBudget
		snap.budgetClamped = r.budgetClampActiveLocked(p.ID, model, p.LastHeartbeat, rawRemaining, snap.activeTokenBudgetMax > 0, now)

		p.mu.Unlock()

		// Absolute hardware-fit gate (mirrors buildCandidateWithReason). A model
		// that can never fit this node is a permanent miss, not transient
		// capacity pressure — count it separately so the caller never 429s it.
		// Skipped for a resident ("running"/"idle") model, which has demonstrably
		// fit.
		if !slotStateModelLoaded(snap.slotState) && !modelFitsHardware(snap.minRAMGb, snap.modelSizeGB, snap.totalMemoryGB) {
			modelTooLarge++
			continue
		}

		// Slot state gate (crashed/reloading are ineligible).
		if _, eligible := slotStatePenalty(snap.slotState); !eligible {
			continue
		}

		// Free memory / token budget admission gate.
		if !freeMemoryAdmits(snap, dummyPR.EstimatedPromptTokens, dummyPR.RequestedMaxTokens) {
			capacityRejections++
			continue
		}

		candidateCount++
		if snap.hasBackendCapacity {
			ttft := estimatedTTFTFromSnapshot(snap, estimatedPromptTokens)
			if !hasTTFT || ttft < bestTTFT {
				bestTTFT = ttft
				hasTTFT = true
			}
		} else {
			unknownTTFTCandidate = true
		}
	}
	if unknownTTFTCandidate {
		return candidateCount, capacityRejections, modelTooLarge, 0, false
	}
	return candidateCount, capacityRejections, modelTooLarge, bestTTFT, hasTTFT
}

func estimatedTTFTFromSnapshot(snap routingSnapshot, reqPromptTokens int) time.Duration {
	ttftMs := ttftMsFromSnapshot(snap, reqPromptTokens)
	if ttftMs <= 0 || math.IsNaN(ttftMs) || math.IsInf(ttftMs, 0) {
		return 0
	}
	// Same calibration as the scheduler's gate input (buildCandidateWithReason)
	// so the preflight bestTTFT and the hard-reject ceiling cannot drift.
	ttftMs = calibratedTTFTMs(snap, ttftMs)
	return time.Duration(ttftMs * float64(time.Millisecond))
}

// ttftMsFromSnapshot returns the estimated time-to-first-token in milliseconds
// for a candidate/provider snapshot. It is shared between the preflight
// (QuickCapacityCheckWithTTFTForRequest) and the scheduler
// (buildCandidateWithReason) so the two paths cannot drift on what "TTFT"
// means.
//
// Token-budget fields are admission/memory reservations, not decode work that
// must fully drain before this request can emit a first token. Continuous
// batching lets a newly-admitted request join the decode loop once its prefill
// completes; existing active max-output reservations only slow the next decode
// step, which is already reflected by effectiveTPS. Count waiting prefills ahead
// and this request's own prefill instead of treating active_token_budget_used as
// a serial decode backlog.
func ttftMsFromSnapshot(snap routingSnapshot, reqPromptTokens int) float64 {
	if !snap.hasBackendCapacity {
		return 0
	}
	statePenalty, _ := slotStatePenalty(snap.slotState)
	if reqPromptTokens < 0 {
		reqPromptTokens = 0
	}
	prefillTPS := resolvePrefillTPS(snap)
	if prefillTPS <= 0 {
		prefillTPS = 1.0
	}
	effectiveTPS := resolveEffectiveTPS(snap)
	if effectiveTPS <= 0 {
		effectiveTPS = 1.0
	}

	queuedPrefillMs := queuedPrefillTokensAhead(snap, reqPromptTokens) / prefillTPS * 1000.0
	thisPrefillMs := float64(reqPromptTokens) / prefillTPS * 1000.0
	firstDecodeMs := 1000.0 / effectiveTPS
	// NOTE: the Phase-0 occupancy term (ttftOccupancyMs) is deliberately NOT added
	// here. ttftMsFromSnapshot is the LIVE estimate consumed by the routing cost's
	// TTFTMs, the candidate-loop MaxTTFTMs ceiling, and the preflight bestTTFT — so
	// it must stay occupancy-FREE regardless of EIGENINFERENCE_TTFT_OCCUPANCY_ALPHA.
	// The occupancy-aware estimate (base + occupancy term) lives in
	// occupancyAwareTTFTMsFromSnapshot and is used ONLY by the shadow evaluator.
	return statePenalty + queuedPrefillMs + thisPrefillMs + firstDecodeMs
}

// occupancyAwareTTFTMsFromSnapshot is the occupancy-aware TTFT estimate: the base
// estimate (ttftMsFromSnapshot — what the LIVE cost / MaxTTFTMs ceiling / bestTTFT
// consume) PLUS the Phase-0 head-of-line occupancy term (ttftOccupancyMs, gated by
// EIGENINFERENCE_TTFT_OCCUPANCY_ALPHA).
//
// It is used ONLY by the shadow evaluator today; a future enforce step will wire
// it (against the verified ~10s base) into the live path. Keeping the occupancy
// term OUT of ttftMsFromSnapshot is a SAFETY INVARIANT: prod runs HARD_REJECT
// (pr.MaxTTFTMs set from the pinned request-local deadline), so if the term
// leaked into ttftMsFromSnapshot, raising alpha would tighten the live ceiling
// and over-shed ~2x (telemetry-db findings §2). The term may therefore only
// ever reach the shadow estimate, never breakdown.TTFTMs.
func occupancyAwareTTFTMsFromSnapshot(snap routingSnapshot, reqPromptTokens int) float64 {
	base := ttftMsFromSnapshot(snap, reqPromptTokens)
	if base <= 0 {
		// No reliable base (provider without BackendCapacity) → no occupancy-aware
		// estimate either, matching ttftMsFromSnapshot's contract.
		return base
	}
	return base + ttftOccupancyMs(snap)
}

// ttftOccupancyMs is the Phase-0 occupancy term: the head-of-line wait while the
// box's already-occupying work (the herd) clears enough for a newly admitted
// request to emit its first token. The base estimate (ttftMsFromSnapshot) counts
// only WAITING prefill and a single decode step, so it is flat in running
// occupancy — exactly where the ~11s of "dark time" lives. It is added ONLY in
// occupancyAwareTTFTMsFromSnapshot (the shadow estimate), never in the live
// ttftMsFromSnapshot.
//
// The term reuses the occupancy the snapshot ALREADY carries
// (snapshotOccupancy = max(pendingForModel, backend_running+backend_waiting)),
// not a new parallel counter, so it is herd-aware for free: a burst onto a box
// still reporting backend_running=0 shows up through pendingForModel. Magnitude
// per occupying peer is alpha decode-token-times divided by the per-request
// decode rate the new request will actually see — projected at the SAME occupancy
// (occ), not the stale backend_running gauge, so in the herd case (pendingForModel
// > backend_running) it is charged the contended rate, not an idle-batch rate.
// The rate itself shrinks with occ, making the term super-linear in occupancy.
//
// Returns 0 when EIGENINFERENCE_TTFT_OCCUPANCY_ALPHA is 0 (the default) or
// occupancy is 0 (an idle box never pays the term, so route-to-idle is
// preserved). The deadline this is gated against in the shadow evaluator is the
// model's upstream SLA (standard ~10s), not the shorter live coordinator cutoff.
// Conflating those clocks over-sheds (telemetry-db findings §2).
func ttftOccupancyMs(snap routingSnapshot) float64 {
	alpha := ttftOccupancyAlpha
	if alpha <= 0 {
		return 0
	}
	occ := snapshotOccupancy(snap)
	if occ <= 0 {
		return 0
	}
	// Project the per-request rate at the batch the request ACTUALLY joins (occ),
	// not the bare heartbeat backend_running: in the herd case the new request
	// waits behind occ peers, so charging the idle/low-batch rate would under-
	// state the term in exactly the case it exists to catch.
	perReqDecodeTPS := projectedPerRequestDecodeTPSAtBatch(snap, occ)
	if perReqDecodeTPS <= 0 {
		perReqDecodeTPS = 1.0
	}
	return alpha * float64(occ) * 1000.0 / perReqDecodeTPS
}

func queuedPrefillTokensAhead(snap routingSnapshot, reqPromptTokens int) float64 {
	if reqPromptTokens <= 0 {
		return 0
	}
	waiting := snap.backendWaiting
	reflected := snap.backendRunning + snap.backendWaiting
	if extraPending := snap.pendingForModel - reflected; extraPending > 0 {
		waiting += extraPending
	}
	if waiting <= 0 {
		return 0
	}
	return float64(waiting * reqPromptTokens)
}

// DrainQueuedRequestsForModel attempts to assign queued requests for a
// single model to available providers. Called when a load_model completes
// so requests don't have to wait for the next heartbeat cycle.
func (r *Registry) DrainQueuedRequestsForModel(model string) {
	r.DrainQueuedRequestsForModelWithReason(model, DrainTriggerUnknown)
}

// DrainQueuedRequestsForModelWithReason is DrainQueuedRequestsForModel with
// the bounded drain trigger (DrainTrigger* constants) the api layer knows at
// its call site — DrainTriggerLoad for a load_model success, for example — so
// the queued request's routing record names what unblocked it. Unknown values
// fold to DrainTriggerUnknown.
func (r *Registry) DrainQueuedRequestsForModelWithReason(model, reason string) {
	r.drainQueuedRequestsForModelsWithReason([]string{model}, reason)
}

// DrainQueuedRequestsForProvider attempts to assign queued requests for every
// model a provider serves. Called when a provider becomes newly eligible for
// routing (e.g. it just passed APNs code-identity attestation) so queued
// demand is satisfied immediately instead of waiting for the next heartbeat.
func (r *Registry) DrainQueuedRequestsForProvider(p *Provider) {
	r.DrainQueuedRequestsForProviderWithReason(p, DrainTriggerUnknown)
}

// DrainQueuedRequestsForProviderWithReason is DrainQueuedRequestsForProvider
// with the bounded drain trigger the api layer knows at its call site (e.g.
// DrainTriggerChallenge after an attestation pass). Unknown values fold to
// DrainTriggerUnknown.
func (r *Registry) DrainQueuedRequestsForProviderWithReason(p *Provider, reason string) {
	if p == nil {
		return
	}
	r.drainQueuedRequestsForModelsWithReason(providerModelIDs(p), reason)
}

// drainQueuedRequestsForModels is the legacy entry point (reason "unknown");
// callers should migrate to drainQueuedRequestsForModelsWithReason so the
// queued request's routing record names what unblocked it.
func (r *Registry) drainQueuedRequestsForModels(models []string) {
	r.drainQueuedRequestsForModelsWithReason(models, DrainTriggerUnknown)
}

// drainQueuedRequestsForModelsWithReason drains the per-model queues for
// models, stamping the bounded drain trigger (see DrainTrigger* constants) on
// every QueuedRequest whose routing decision this drain records, together with
// the request's enqueue position/depth, so the api layer can persist why and
// from where a queued request was dispatched.
func (r *Registry) drainQueuedRequestsForModelsWithReason(models []string, reason string) {
	reason = foldDrainTrigger(reason)
	queue := r.Queue()
	if queue == nil || len(models) == 0 {
		return
	}
	for _, model := range models {
		var skipped []*QueuedRequest
		requeueSkipped := func() {
			for i := len(skipped) - 1; i >= 0; i-- {
				queue.RequeueFront(skipped[i])
			}
			skipped = nil
		}
		for {
			req := queue.PopNextFresh(model)
			if req == nil {
				requeueSkipped()
				break
			}
			if req.Pending == nil {
				req.Pending = &PendingRequest{
					RequestID:          req.RequestID,
					Model:              model,
					RequestedMaxTokens: defaultRequestedMaxTokens,
				}
			}
			// Queue time spends the same absolute first-content clock as
			// parsing, admission, and provider dispatch. Refresh immediately
			// before reservation so hard TTFT admission never reuses the
			// enqueue-time ceiling.
			if !req.Pending.RefreshFirstContentBudget(time.Now()) {
				req.failWithReason(ErrQueueFirstContentDeadline)
				continue
			}
			provider, decision := r.ReserveProviderEx(model, req.Pending)
			// Queue context for the routing record: where the request sat at
			// enqueue and which event ran the drain that produced this decision.
			decision.QueuePosition = req.EnqueuePosition
			decision.QueueDepth = req.DepthAtEnqueue
			decision.DrainTrigger = reason
			if provider == nil {
				if req.Pending.Traits.RequiresToolConstraint &&
					!r.hasToolConstraintProviderForPending(model, req.Pending) {
					req.DrainTrigger = reason
					req.Decision = decision
					req.failWithReason(ErrQueueToolConstraintUnavailable)
					continue
				}
				// A pure-TTFT rejection (hard-reject mode, no capacity-rejected
				// provider that could free up) is deterministic for this pass:
				// requeueing would only make the waiter hang until maxWait for
				// the same answer. Fail it now; the API waiter turns
				// ErrQueueTTFTTooSlow into the standard ttft_too_slow 429 using
				// the decision's BestTTFTMs for Retry-After.
				if drainRejectionTTFTTerminal(req.Pending, decision) {
					req.DrainTrigger = reason
					req.Decision = decision
					req.failWithReason(ErrQueueTTFTTooSlow)
					continue
				}
				skipped = append(skipped, req)
				continue
			}
			req.DrainTrigger = reason
			req.Decision = decision
			requeueSkipped()

			releaseReservation := func() {
				provider.RemovePending(req.Pending.RequestID)
				r.SetProviderIdle(provider.ID)
			}
			if !req.offerAssignment(provider, releaseReservation) {
				releaseReservation()
				continue
			}
			if req.beforeAssignmentSend != nil {
				req.beforeAssignmentSend()
			}
			select {
			case req.ResponseCh <- provider:
				// The reservation remains scheduler-owned until the waiter
				// acknowledges it in WaitForProviderContext. Cancellation after
				// this buffered send rejects the published assignment and runs
				// releaseReservation exactly once.
			case <-req.Done():
				req.rejectAssignment()
				continue
			}
		}
	}
}
