package registry

import (
	"math"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepolicy"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityvalue"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/forecast"
	kvbudget "github.com/eigeninference/d-inference/coordinator/internal/registry/kvbudget"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/longprompt"
	memorypolicy "github.com/eigeninference/d-inference/coordinator/internal/registry/memorypolicy"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/performance"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/quality"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/shortlist"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/ttftforecast"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/admission"
	"github.com/eigeninference/d-inference/coordinator/registry/selection"
)

const (
	// Coordinator-side defaults for request sizing. These are only used for
	// routing heuristics and queue admission, not billing or protocol limits.
	defaultRequestedMaxTokens = memorypolicy.DefaultRequestedMaxTokens

	// A changing fleet must not spin forever for deadline-exempt requests.
	maxReservationRescans = 32

	slotStatePenaltyRunning      = 0.0
	slotStatePenaltyUnknown      = 30_000.0
	slotStatePenaltyIdleShutdown = 20_000.0

	// Legacy cost diagnostics remain separate from first-content ranking.
	queueDepthPenaltyMs      = 3_000.0
	totalPendingPenaltyMs    = 750.0
	memoryPressurePenaltyMs  = 4_000.0
	cpuUsagePenaltyMs        = 1_500.0
	gpuUtilizationPenaltyMs  = 5_000.0
	thermalPenaltyFairMs     = 2_000.0
	thermalPenaltySeriousMs  = 8_000.0
	challengeFreshnessMaxAge = 16 * time.Minute

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
	// performance.Rates and candidateSnapshot.projectedDecodeTPS, and
	// the warm-pool target (warm_pool_controller.go) — which then
	// under-warms the pool while admission packs batches that miss the
	// decode floor.
	// Set to 0 to disable load scaling.
	effectiveTPSLoadFactor = warmplan.DecodeLoadFactor
)

type routingSnapshot struct {
	performanceProfile *servingPerformanceProfile
	firstContentSnapshot
	CandidateBinding
	chipFamily       string // hardware chip family (e.g. "M3"); keys the TTFT calibrator
	slotState        string
	hasHeadroom      bool
	totalPending     int
	pendingForModel  int
	pendingMaxTokens int
	// Pending prompt work before first content, for the matching model. These
	// aggregates price reservations not yet reflected by an idle heartbeat.
	// Unknown sizes and cache participants retain the incoming-prompt proxy.
	// Token-budget reservations (including output) remain memory accounting.
	pendingPrefillTokens     float64
	pendingPrefillUnknown    int
	pendingPrefillKnown      bool
	firstContentPendingKnown bool
	pendingPrefill           forecast.PrefillQueue
	newestReservationAt      time.Time
	pendingPrefillRestoreMs  float64
	// pendingMaxTokensAllModels is pendingMaxTokens WITHOUT the model filter:
	// the token budgets of every coordinator-pending request on this provider,
	// any model. Feeds the pooled-budget admission check (pooledBudgetAdmits)
	// so a cold model or a shrunken grant cannot double-spend the box-wide sum
	// of private grants.
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
	freeForLoadGB              *float64
	modelSizeGB                float64 // catalog-reported weight footprint (0 = unknown, gate disabled)
	estimatedOffloadedMemoryGB float64 // validated padded native weights; zero preserves legacy policy
	minRAMGb                   int     // catalog authoritative min RAM (GB) to run the model (0 = unknown)
	modelLoaded                bool    // true when the requested model is resident (running or idle)
	availableOnDisk            bool    // model is in provider's Models list but not currently loaded

	observedDecodeTPS     float64
	observedPrefillTPS    float64 // measured per-slot prefill EWMA; 0 = unreported (fall back to prefillTPS chain)
	activeTokenBudgetUsed int64
	activeTokenBudgetMax  int64
	queuedTokenBudget     int64
	// pooledTokenBudget is the provider's reconstructed whole-box token budget
	// (Σ private grants over all budget slots).
	// Zero value when the provider reports no backend capacity / no budget
	// slots, which disables the pooled admission check.
	pooledTokenBudget kvbudget.Budget
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
	// A managed cold slot or a real placement transition cannot accept network
	// work. Kept separate from structural eligibility so planners still see
	// cached inventory and preflight reports temporary capacity, not absence.
	autopilotBlocked bool
	// kvBytesPerToken is the provider-reported per-token KV-cache cost (bytes)
	// for THIS model's slot (BackendSlotCapacity.KVBytesPerToken). 0 = unreported
	// (callers fall back to admission.KVCacheBytesPerToken). Used by the
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

// Candidate is an opaque, request-local evaluation. ProviderID is the identity
// ranked by the scan; the live provider and captured policy evidence stay private.
type Candidate struct {
	CandidateBinding              `json:"-"`
	ProviderID                    string
	firstContentEvidenceQualified bool
	firstContent                  FirstContentEstimate
	firstContentCachedTokens      float64
	firstContentRestoreMs         float64
	firstContentCacheWeight       float64
	firstContentCacheExpiresAt    time.Time
	cacheAffinityEligible         bool
	// Exact base-score work eligible for a cache credit; never includes load or decode.
	pricedPromptTokens int
	prefillCostMs      float64
	snapshot           candidateSnapshot
	costMs             float64
	effectiveQueue     int
	breakdown          costBreakdown
	effectiveTPS       float64 // Phase 4 load-scaled TPS used in this candidate's cost
	// capacityRejectRate is the pair's windowed capacity-503 rate
	// (capacity_rate.go), captured at candidate build so the winning
	// RoutingDecision can expose it. 0 when no rejects are in the window.
	capacityRejectRate        float64
	cacheTier                 string
	cacheEstimatedTTFTSavedMs float64
	// cacheEvidenceWeight is the age weight of the credited holder evidence,
	// captured with the hint so near-tie ranking and reservation agree.
	cacheEvidenceWeight float64
	// calibrationRatio is the TTFT calibration ratio this candidate was
	// scored with (recorded on the RoutingDecision for the profiler).
	calibrationRatio float64
}

type routingCandidate = Candidate

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

// modelFitsHardware reports whether a model can run on a node with the given
// total unified memory (GB). It prefers the catalog's authoritative min_ram_gb
// (the operator-published requirement) and only falls back to a heuristic
// multiple of the on-disk weight size when min_ram_gb is unknown. Fails OPEN
// when nothing is known. The provider still performs the final precise check at
// load time; this gate only filters models that clearly cannot fit per the
// catalog's own contract.
func modelFitsHardware(minRAMGb int, modelSizeGB, totalMemoryGB float64) bool {
	return admission.ModelFitsHardware(minRAMGb, modelSizeGB, totalMemoryGB)
}

// costBreakdown decomposes the routing cost so callers can log or
// expose individual contributions. The numeric values match the terms
// added in buildCandidate; total should equal costMs (modulo float
// rounding).
type costBreakdown = cachepolicy.ServiceBreakdown

// RoutingDecision is the public, exportable record of a routing
// selection. Returned by ReserveProviderEx so callers can emit metrics
// and structured logs without reaching into registry internals.
type RoutingDecision struct {
	FirstContent FirstContentEstimate
	ProviderID   string  // winning provider, empty if no selection
	Model        string  // requested model
	CostMs       float64 // total cost of the winning candidate
	StateMs      float64 // slot-state penalty contribution
	QueueMs      float64 // pendingForModel × queueDepthPenaltyMs
	PendingMs    float64 // totalPending × totalPendingPenaltyMs
	BacklogMs    float64 // tokens-ahead / decodeTPS contribution
	ThisReqMs    float64 // prefill+decode, including long-prompt and excess restore costs
	HealthMs     float64 // memory/CPU/thermal/GPU-util contribution
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
	// CacheEstimatedTTFTSavedMs is the signed, uncapped prefill-time saving
	// net of stage time. Negative values mean restore overhead, charged in
	// ThisReqMs. Positive CacheDiscountMs remains bounded by the safety caps.
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

	// Scanned is the number of providers the candidate loop visited.
	// Since the per-model provider index (model_index.go) the loop walks only
	// the providers ADVERTISING the requested model — so Scanned is the
	// advertising count, not the fleet size, and GateRejections[
	// GateNotServingModel] is 0 unless an advertiser still fails the catalog
	// rule (off-catalog model on a public route). CandidateSetSize is
	// Scanned − GateNotServingModel rejections either way; providers skipped by
	// the exclude/allowlist filters, which run before the catalog check, are
	// counted as advertising. The same applies to the GateAllowlist /
	// GateExcluded tallies themselves: they now count only advertisers (a
	// serial-allowlist miss used to tally ~fleet size per request). Pre-index
	// records have Scanned == fleet size.
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
	// PredictedDecodeTPS is the per-request decode rate the winning candidate
	// predicts this request will receive once admitted.
	PredictedDecodeTPS float64
	// PendingForModel / TotalPending are the winner's coordinator-side pending
	// counts (this model / all models) at snapshot time, before this reservation.
	PendingForModel, TotalPending int
	// ScanCount is how many candidate scans this reservation attempt ran —
	// one for a clean commit, more when a commit had to rescan (winner gone
	// or full between scan and commit, cache-routing reconfiguration). Zero
	// for a plan-based retry, which reuses the previous scan. The api layer
	// emits it as the routing.scans counter so scan CPU per attempt is
	// measured, not inferred from the profile.
	ScanCount int
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

type ReservationCommitOutcome uint8

type reservationCommitOutcome = ReservationCommitOutcome

const (
	reservationCommitted reservationCommitOutcome = iota
	reservationNeedsRescan
	reservationCandidateRejected
	reservationDeadlineExpired
)

const (
	ReservationCommitted         = reservationCommitted
	ReservationNeedsRescan       = reservationNeedsRescan
	ReservationCandidateRejected = reservationCandidateRejected
	ReservationDeadlineExpired   = reservationDeadlineExpired
)

type providerReservationScan struct {
	quote          *PlanEntry
	claimPlanEntry func(string) bool
	selected       *routingCandidate
	candidates     candidateScan
	cacheTracker   *cacheRoutingTracker
	cacheMode      string
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
// committed inside a short section under the winner's p.mu (r.mu is only read
// — see commitProviderReservation; the global mode is the kill switch).
// addPendingLocked records the request before that section ends, so every
// later commit on that provider sees the debit through
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

	// Decorated preparations and public scans keep their own candidate storage.
	var storage *reservationCandidateStorage
	if r.reservations == nil {
		storage = &reservationCandidateStorage{registry: r}
		defer storage.release()
	}
	excluded := append([]string(nil), excludeIDs...)
	carried := RoutingDecision{Model: model}
	var last ReservationSelection
	var admitUS int64
	scans := 0
	failedDecision := func() RoutingDecision {
		decision := routingDecisionForFailedScan(model, last.candidates)
		addRoutingRejections(&decision, carried)
		decision.LockWaitUS, decision.ScanUS, decision.AdmitUS = last.lockWaitUS, last.scanUS, admitUS
		decision.ScanCount = scans
		return decision
	}
	for scans < maxReservationRescans && pr.RefreshFirstContentBudget(time.Now()) {
		if r.reservations == nil {
			// Prior retry candidates have no escaping readers.
			if scans > 0 {
				storage.reset()
			}
			var prepared PreparedReservation
			r.prepareProviderReservationIntoStorage(&prepared, storage, model, pr, excluded...)
			last = prepared.Finish()
		} else {
			last = r.reservations.Prepare(model, pr, excluded...).Finish()
		}
		scans++
		if last.Provider == nil {
			return nil, failedDecision(), nil
		}

		// AdmitUS covers the commit phase: the lock waits plus the
		// current-state re-check and the pending debit.
		tCommitStart := time.Now()
		committed := last.Commit(model, pr, excluded...)
		provider, candidate, outcome, rejected := committed.Provider, committed.candidate, committed.Outcome, committed.Decision
		admitUS = time.Since(tCommitStart).Microseconds()
		switch outcome {
		case reservationNeedsRescan:
			continue
		case reservationCandidateRejected:
			addRoutingRejections(&carried, rejected)
			excluded = append(excluded, last.Provider.ID)
			continue
		case reservationDeadlineExpired:
			return nil, failedDecision(), nil
		case reservationCommitted:
			decision := routingDecisionForCandidate(
				model, provider, candidate, last.candidates)
			addRoutingRejections(&decision, carried)
			decision.LockWaitUS, decision.ScanUS, decision.AdmitUS = last.lockWaitUS, last.scanUS, admitUS
			decision.ScanCount = scans
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

func (r *Registry) prepareProviderReservation(model string, pr *PendingRequest, excludeIDs ...string) *PreparedReservation {
	prepared := &PreparedReservation{}
	r.prepareProviderReservationIntoStorage(prepared, nil, model, pr, excludeIDs...)
	return prepared
}

func (r *Registry) prepareProviderReservationIntoStorage(prepared *PreparedReservation, storage *reservationCandidateStorage, model string, pr *PendingRequest, excludeIDs ...string) {
	// Profiler stamps: scan-lock wait (from here to the scan RLock) and the
	// scan itself land on the decision as LockWaitUS / ScanUS; ~25 ns each.
	tScanStart := time.Now()
	cacheTracker, cacheMode := r.prepareRequestCacheHints(model, pr)

	r.mu.RLock()
	tLocked := time.Now()
	// Configuration can change while tracker hints are computed outside r.mu.
	// Revalidate under the scan lock so an off/reconfigure transition is
	// linearizable and stale hints never affect selection.
	if cacheMode == CacheRoutingOff || r.cacheRoutingMode != cacheMode ||
		r.cacheRouting != cacheTracker {
		pr.cacheRoutingHints = nil
		pr.CacheSelectionMode = ""
		pr.CacheOpportunity = CacheOpportunity{}
	}
	selected, candidates := r.selectBestCandidateLockedFullStorage(storage, model, pr, excludeIDs...)
	result := providerReservationScan{
		selected:     selected,
		candidates:   candidates,
		cacheTracker: r.cacheRouting,
		cacheMode:    r.cacheRoutingMode,
		lockWaitUS:   tLocked.Sub(tScanStart).Microseconds(),
	}
	prepared.registry = r
	prepared.scan = result
	prepared.lockedAt = tLocked
}

func (r *Registry) prepareRequestCacheHints(model string, pr *PendingRequest) (*cacheRoutingTracker, string) {
	// Snapshot receipt-confirmed cache hints before taking the registry scan lock.
	// Query holders outside the scan lock; the later candidate quarantine check
	// uses the same registry -> provider -> tracker order as receipt rejection.
	r.mu.RLock()
	cacheTracker, cacheMode := r.cacheRouting, r.cacheRoutingMode
	// Skip digest derivation and holder lookup unless the request can use them.
	// Only matching holders need a capability snapshot; cold providers are
	// visited once, by the ordinary eligibility scan below.
	preparation := CacheHintPreparation{Mode: cacheMode, RouteKey: r.cacheRouteKeys.route}
	wantHints := preparation.eligible(cacheTracker != nil, pr.CachePlan)
	if wantHints {
		preparation.Query = cacheTracker.hintQuery
		if preparation.Query == nil {
			preparation.Query = CacheHintQuery{registry: r, tracker: cacheTracker}
		}
		preparation.RouteKey = append([]byte(nil), r.cacheRouteKeys.route...)
	} else {
		preparation.RouteKey = nil
	}
	r.mu.RUnlock()
	pr.cacheRoutingHints = nil
	pr.CacheOpportunity = CacheOpportunity{}
	var now time.Time
	if wantHints {
		now = cacheTracker.now()
	}
	preparation.Prepare(model, pr.CachePlan, now).Apply(pr)

	return cacheTracker, cacheMode
}

// commitProviderReservation is the short commit phase. It repeats the full
// current-state capacity chain before adding the pending debit, so concurrent
// scans cannot double-spend a provider's cross-model token pool.
//
// Locking (reserveCommitShared, the default): r.mu is held for READING — the
// commit needs the provider identity, catalog and cache-routing configuration
// to be stable, not the fleet to be frozen — and everything that decides the
// reservation runs under the winner's p.mu in ONE section: the fresh snapshot,
// the cost rebuild, the "winner unchanged since scan" compare, the admit
// re-check, the probe claim and the pending debit. Double-booking is prevented
// where it always was (providerCanAdmitLockedEx + addPendingLocked under
// p.mu); the herd compare is exact because it compares the winner's own
// counters read under the same p.mu that debits them; the half-open probe
// claim is check-and-claim under gate.mu. Nothing here drains the fleet-scan
// reader batch, which is what each write acquisition cost before.
// reserveCommitGlobal takes r.mu for writing instead — the previous
// fleet-wide serialization, kept as the kill switch.
func (r *Registry) commitProviderReservation(
	model string,
	pr *PendingRequest,
	scan providerReservationScan,
	excludeIDs ...string,
) (*Provider, *routingCandidate, reservationCommitOutcome, RoutingDecision) {
	result := reservationSelection(r, scan).Commit(model, pr, excludeIDs...)
	return result.Provider, result.candidate, result.Outcome, result.Decision
}

func (s ReservationSelection) commit(
	model string,
	pr *PendingRequest,
	excludeIDs ...string,
) (*Provider, *routingCandidate, reservationCommitOutcome, RoutingDecision) {
	r, scan := s.registry, s.providerReservationScan
	site := "commit"
	if scan.claimPlanEntry != nil {
		site = "commit_plan"
	}
	lock := r.commitLock(site)
	lock.lock()
	defer lock.unlock()

	// The shared scan and any lock wait consume the same absolute request
	// clock as queueing and provider handoff. Never debit capacity for work whose
	// first-content budget is already gone. One clock read serves the whole
	// commit section (deadline, re-snapshot, cost, admit, probe claim).
	now := time.Now()
	if !pr.RefreshFirstContentBudget(now) {
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
	p := s.Provider
	if current, ok := r.providers[p.ID]; !ok || current != p {
		return nil, nil, reservationCandidateRejected, RoutingDecision{}
	}

	// A breaker bypass is valid only while breaker-open providers remain the
	// sole route. Re-run the normal pass at commit time; this rare emergency path
	// re-scans under the commit lock so a newly healthy provider is preferred
	// over the fail-open choice.
	if scan.candidates.ignoreProviderBreaker {
		normalWinner, normal := r.selectBestCandidateScanLocked(
			model, pr, false, excludeIDs...)
		if normalWinner != nil || !shouldBypassBreakerFailOpen(
			normalWinner, normal.BreakerRejected,
			normal.CapacityRejections, normal.TTFTRejections) {
			return nil, nil, reservationNeedsRescan, RoutingDecision{}
		}
	}

	// Ownership / serial filters take p.mu themselves — evaluate them before
	// the commit section below acquires it.
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

	// Commit section: snapshot, cost, compare, admit and debit under ONE p.mu
	// hold, so no other commit can change this provider between the compare
	// and the debit.
	p.mu.Lock()
	defer p.mu.Unlock()
	now = time.Now()
	if !pr.RefreshFirstContentBudget(now) {
		return nil, nil, reservationDeadlineExpired, RoutingDecision{}
	}
	var snapshot routingSnapshot
	if ok, _ := r.snapshotProviderIntoPLockedEx(
		&snapshot, p, model, pr.Traits, relaxTrust, scan.candidates.ignoreProviderBreaker, now); !ok {
		return nil, nil, reservationCandidateRejected, RoutingDecision{}
	}
	if pr.RequiresVision && !r.providerServesVisionModelLocked(p, model, relaxTrust) {
		return nil, nil, reservationCandidateRejected,
			routingDecisionForCommitRejection(model, rejectVisionUnsupported, false)
	}
	candidate, reason, ok := r.buildCandidateWithReason(&snapshot, pr, now)
	if !ok {
		return nil, nil, reservationCandidateRejected,
			routingDecisionForCommitRejection(model, reason, false)
	}
	r.applyCacheRoutingCostPLocked(p, model, pr, candidate, &snapshot)
	r.estimateFirstContent(candidate, &snapshot, pr, now)
	if scan.quote != nil {
		applyFirstContentQuote(candidate, &snapshot, pr, *scan.quote, now)
	}
	if !firstContentCandidateAllowed(candidate, pr) {
		return nil, nil, reservationCandidateRejected,
			routingDecisionForCommitRejection(model, rejectNone, true)
	}

	// Another reservation or cache quarantine changed this winner after the
	// shared scan. Re-scan before committing stale cost or affinity preference.
	// Quarantine can change affinity without changing any cost. The counters here
	// were read under the p.mu this section still holds, so a concurrent commit
	// on the same provider is either fully before (and visible) or fully after.
	if snapshot.capacitySeq != selected.snapshot.capacitySeq ||
		snapshot.pendingForModel != selected.snapshot.pendingForModel ||
		snapshot.totalPending != selected.snapshot.totalPending ||
		candidate.effectiveQueue != selected.effectiveQueue ||
		candidate.firstContent.ExpectedMs != selected.firstContent.ExpectedMs ||
		candidate.firstContent.ConservativeMs != selected.firstContent.ConservativeMs ||
		candidate.firstContent.Status != selected.firstContent.Status ||
		firstContentEvidenceExplorable(candidate) != firstContentEvidenceExplorable(selected) ||
		candidate.firstContent.ServiceMs != selected.firstContent.ServiceMs ||
		candidate.costMs != selected.costMs ||
		candidate.breakdown.CacheDiscountMs != selected.breakdown.CacheDiscountMs ||
		candidate.cacheAffinityEligible != s.CacheAffinityEligible {
		return nil, nil, reservationNeedsRescan, RoutingDecision{}
	}

	if !r.providerCanAdmitLockedEx(
		p, model, pr.Traits, relaxTrust, scan.candidates.ignoreProviderBreaker, now) ||
		(pr.RequiresVision && !r.providerServesVisionModelLocked(p, model, relaxTrust)) {
		return nil, nil, reservationCandidateRejected, RoutingDecision{}
	}
	if scan.claimPlanEntry != nil && !scan.claimPlanEntry(p.ID) {
		return nil, nil, reservationNeedsRescan, RoutingDecision{}
	}

	// Half-open capacity probe: check-and-claim under gate.mu (p.mu → gate.mu).
	// A pair whose expired cooldown was claimed by a concurrent commit for the
	// same identity is closed again; reject rather than leak a second probe.
	if !r.tryClaimCapacityProbe(p, model, now) {
		return nil, nil, reservationCandidateRejected,
			routingDecisionForCommitRejection(model, rejectCapacity, false)
	}

	pr.ProviderID = p.ID
	recordReservedPrefill(pr, candidate)
	p.addPendingLocked(pr)
	if p.Status != StatusUntrusted && p.Status != StatusOffline {
		p.Status = StatusServing
	}
	if !slotStateModelLoaded(candidate.snapshot.slotState) {
		r.RecordWarmPoolColdDispatch(model)
	}
	if !pr.RequiresVision && candidate.breakdown.RawTTFTMs > 0 && candidate.breakdown.StateMs == 0 {
		NoteTTFTPrediction(
			pr.RequestID, pr.Attempt, model, candidate.snapshot.chipFamily,
			candidate.breakdown.RawTTFTMs)
	}
	if candidate.breakdown.CacheDiscountMs > 0 {
		pr.CacheSelectionMode = "active"
		pr.CacheSelectionTier = candidate.cacheTier
		pr.CacheSelectionDiscountMs = candidate.breakdown.CacheDiscountMs
		pr.CacheSelectionEstimatedTTFTSavedMs = candidate.cacheEstimatedTTFTSavedMs
		pr.CacheSelectionSelected = true
		// The discount and the prediction come from the same provider hint.
		pr.cacheSelectionPredictedTokens = pr.cacheRoutingHints[p.ID].CachedTokens
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
	if winner.snapshot.occupancy() > 0 {
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
		CandidateCount:          scan.CandidateCount,
		CapacityRejections:      scan.CapacityRejections,
		ModelTooLargeRejections: scan.ModelTooLargeRejections,
		VisionRejections:        scan.VisionRejections,
		TTFTRejections:          scan.TTFTRejections,
		BestTTFTMs:              scan.BestTTFTMs,
		// System-profiler routing context (by value, filled during the scan).
		CandidateSetSize:   scan.candidateSetSize,
		Scanned:            scan.Scanned,
		GateRejections:     scan.GateRejections,
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
	decision.FirstContent = candidate.firstContent
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
	decision.PredictedDecodeTPS = candidate.snapshot.projectedDecodeTPS(candidate.snapshot.backendRunning)
	decision.PendingForModel = candidate.snapshot.pendingForModel
	decision.TotalPending = candidate.snapshot.totalPending
	// The ratio this candidate was actually scored with (captured at build,
	// no second read of the mutable calibrator): the TTFTMs/RawTTFTMs
	// quotient would be wrong for cold slots (the state penalty is
	// deliberately unscaled).
	decision.TTFTCalibrationRatio = candidate.calibrationRatio
	return decision
}

// applyCacheRoutingCost borrows the same transient snapshot used for the
// base score. The caller holds r.mu, but not p.mu;
// the hint currency and affinity quarantine checks take the provider lock.
func (r *Registry) applyCacheRoutingCost(p *Provider, model string, pr *PendingRequest, candidate *routingCandidate, snapshot *routingSnapshot) {
	_, present := pr.cacheRoutingHints[p.ID]
	if !present && pr.CachePlan.AffinityKey() == "" {
		return
	}
	p.mu.Lock()
	r.applyCacheRoutingCostPLocked(p, model, pr, candidate, snapshot)
	p.mu.Unlock()
}

// applyCacheRoutingCostPLocked is shared by scan and reservation; both hold
// r.mu and p.mu so capability/quarantine checks use the current provider state.
func (r *Registry) applyCacheRoutingCostPLocked(p *Provider, model string, pr *PendingRequest, candidate *routingCandidate, snapshot *routingSnapshot) {
	if pr.CachePlan.AffinityKey() != "" {
		candidate.cacheAffinityEligible = r.cacheAffinityEligibleLocked(p, model, pr.CachePlan)
	}
	r.applyCacheHintLocked(pr.cacheRoutingHints[p.ID], model, candidate, snapshot)
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
	return r.selectBestCandidateLockedFullStorage(nil, model, pr, excludeIDs...)
}

func (r *Registry) selectBestCandidateLockedFullStorage(storage *reservationCandidateStorage, model string, pr *PendingRequest, excludeIDs ...string) (*routingCandidate, candidateScan) {
	winner, scan := r.selectBestCandidateScanLockedStorage(storage, model, pr, false, excludeIDs...)
	if !shouldBypassBreakerFailOpen(winner, scan.BreakerRejected, scan.CapacityRejections, scan.TTFTRejections) {
		return winner, scan
	}
	// The node-health breaker is the SOLE reason this request has no route: re-scan
	// with the breaker bypassed. Use pass 2 only when it actually finds a candidate,
	// so a genuinely empty fleet still reports pass 1's (accurate) counters.
	if w2, scan2 := r.selectBestCandidateScanLockedStorage(storage, model, pr, true, excludeIDs...); w2 != nil {
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
	return selection.BypassBreaker(winner != nil, breakerRejected, capacityRejections, ttftRejections)
}

// candidateScan is the result of building the eligible candidate pool for a
// request: the cost-rankable pool (after every per-provider gate AND the
// post-candidate pool narrowing) plus the rejection tallies. It is the SINGLE
// SOURCE of routing eligibility, shared by
// the cost-ranking selector (selectBestCandidateScanLocked) and the Phase-0
// idle-spread shadow scan (loadedIdleAlternativeExistsLocked) so the two can
// never drift on which providers are routable.
// CandidateScan is the immutable result of one eligibility pass. The same
// candidates and tallies feed selection, alternate planning and preflight.
type CandidateScan struct {
	planOrderFactory        func() *shortlist.Order
	affinity                string
	Candidates              []*Candidate
	CandidateCount          int
	CapacityRejections      int
	ModelTooLargeRejections int
	VisionRejections        int
	TTFTRejections          int
	BestTTFTMs              float64
	BreakerRejected         int
	ignoreProviderBreaker   bool

	// System-profiler routing context — fixed-size value fields filled inside
	// the existing loops with ZERO heap allocation (hot-path review C5). See the
	// matching RoutingDecision fields for semantics.
	Scanned          int
	candidateSetSize int
	GateRejections   [GateReasonCount]uint16
	top              [4]CandidateSummary
	runnerUp         CandidateSummary
	bestIdle         CandidateSummary
	nearTieSize      int32
	path             SelectionPath
}

type candidateScan = CandidateScan

// tallyGate records one gate rejection, saturating at the uint16 ceiling.
func (s *candidateScan) tallyGate(reason GateReason) {
	if reason >= GateReasonCount {
		return
	}
	if s.GateRejections[reason] < ^uint16(0) {
		s.GateRejections[reason]++
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
	planner := r.reservationPlanner
	if planner == nil {
		planner = &ReservationPlanner{registry: r}
	}
	return planner.scanCandidatesLocked(model, pr, ignoreProviderBreaker, excludeIDs...)
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
	return r.selectBestCandidateScanLockedStorage(nil, model, pr, ignoreProviderBreaker, excludeIDs...)
}

func (r *Registry) selectBestCandidateScanLockedStorage(storage *reservationCandidateStorage, model string, pr *PendingRequest, ignoreProviderBreaker bool, excludeIDs ...string) (*routingCandidate, candidateScan) {
	planner := r.reservationPlanner
	if planner == nil {
		planner = &ReservationPlanner{registry: r}
	}
	scan := planner.scanCandidatesLockedStorage(storage, model, pr, ignoreProviderBreaker, excludeIDs...)
	if len(scan.Candidates) == 0 {
		return nil, scan
	}

	affinity := ""
	if pr.CacheSelectionMode == "active" && r.cacheRouting != nil &&
		pr.CachePlan.Authenticates(r.cacheRouting.generation) && r.cacheRouting.generation.Active() {
		affinity = pr.CachePlan.AffinityKey()
	}
	pr.CacheOpportunity.UsableCandidates = 0
	pr.CacheOpportunity.CreditedCandidates = 0
	for _, candidate := range scan.Candidates {
		if candidate.cacheTier != "" {
			pr.CacheOpportunity.UsableCandidates++
			if candidate.breakdown.CacheDiscountMs > 0 {
				pr.CacheOpportunity.CreditedCandidates++
			}
		}
	}
	scan.affinity = affinity
	winner, runnerUp, nearTieSize, path := selectRoutingCandidateWithAffinity(scan.Candidates, affinity)
	pr.CacheOpportunity.AffinityApplied = path == SelectionPrefixAffinity
	// The runner-up is the pool minimum whenever the winner is not; a credited
	// winner that costs more than it won only through the near-tie preference.
	pr.CacheOpportunity.CreditWonNearTie = path == SelectionCacheCredit &&
		runnerUp != nil && winner.costMs > runnerUp.costMs
	scan.runnerUp = candidateSummaryOf(runnerUp)
	scan.nearTieSize = clampInt32(nearTieSize)
	scan.path = path
	scan.promoteWinnerTop(winner)
	r.logRoutingDecision(model, pr, winner, scan.CandidateCount, scan.path)
	return winner, scan
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
// (providerEligibleForTraitsLocked, the vision gate): without them a
// constrained tool call to an owned box that does not advertise the tool
// constraint — or a media request to a text-only build — would pass this
// preflight, queue for up to 120s, and die as
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
			r.providerLivenessGateLocked(p, TrustNone, true, now)
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
func (r *Registry) logRoutingDecision(model string, pr *PendingRequest, winner *routingCandidate, candidates int, path SelectionPath) {
	if winner == nil {
		return
	}
	selection.LogDecision(r.logger, func() selection.DecisionLog {
		return selection.DecisionLog{RequestID: pr.RequestID, Model: model, Winner: winner.provider.ID,
			Breakdown: winner.breakdown, Path: path.String(), CacheTier: winner.cacheTier,
			CacheEstimatedTTFTSavedMs: winner.cacheEstimatedTTFTSavedMs,
			EffectiveTPS:              winner.effectiveTPS, EffectiveQueue: winner.effectiveQueue, Candidates: candidates}
	})
}

// providerPassesRoutingGatesLocked is the single source of truth for the
// per-provider structural/privacy/cooldown/trait gates a request must clear
// before a provider is eligible to serve it. snapshotProviderIntoLockedEx (the
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
	return (&ProviderEligibility{registry: r}).routingLocked(p, model, traits, selfRouteOwner, now, ignoreProviderBreaker, ignoreCapacityCooldown)
}

func (e *ProviderEligibility) routingLocked(p *Provider, model string, traits RequestTraits, selfRouteOwner bool, now time.Time, ignoreProviderBreaker, ignoreCapacityCooldown bool) (bool, GateReason) {
	// Catalog membership + dedicated-box isolation: a request for a dedicated
	// model family (e.g. Gemma 4) may ONLY route to a provider whose ENTIRE
	// advertised catalog is that family. This single gate is shared by the
	// dispatch hot path and the OpenRouter capacity preflight, so the filter
	// restricts the routing candidate set AND the shed (429) decision together
	// with no drift. A caller self-routing to its OWN machine is exempt — owners
	// may run mixed boxes.
	if ok, reason := e.catalogReasonLocked(p, model, selfRouteOwner); !ok {
		return false, reason
	}
	return e.postCatalogLocked(p, model, traits, selfRouteOwner, now, ignoreProviderBreaker, ignoreCapacityCooldown)
}

// Shared trust, liveness and request-shape checks. Autopilot planning supplies
// its separate inventory permission before entering here; it never changes a
// provider's ordinary routing permission to ask a hypothetical question.
func (e *ProviderEligibility) postCatalogLocked(p *Provider, model string, traits RequestTraits, selfRouteOwner bool, now time.Time, ignoreProviderBreaker, ignoreCapacityCooldown bool) (bool, GateReason) {
	r := e.registry
	// The identity's fault-tracker gates (gate_state.go): cached on the
	// connected provider, so the five reads are atomic loads for a provider
	// with no fault state and one short gate.mu section per tracker that has
	// state — and confirmed against p.gate afterwards (gateView), so a rebind
	// landing mid-read cannot hand the scan an emptied gate.
	if !ignoreCapacityCooldown && providerDrainingLocked(p, now) {
		return false, GateCapacityCooldown
	}
	view := r.gateViewOf(p)
	if ok, reason := r.gateStateReasonLocked(&view, model, traits, now, ignoreProviderBreaker, ignoreCapacityCooldown); !ok {
		return false, reason
	}
	// Liveness/trust/privacy core. selfRouteOwner relaxes ONLY the hardware-trust
	// floor (to TrustNone) and private-only admission for a caller's own
	// (possibly un-enrolled) machine; every privacy-critical gate still applies.
	minTrust := r.MinTrustLevel
	if selfRouteOwner {
		minTrust = TrustNone
	}
	if ok, reason := e.livenessLocked(p, minTrust, selfRouteOwner, now); !ok {
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

// snapshotProviderIntoLockedEx builds a routing snapshot for p into
// caller-owned storage, returning ok=false and the closed GateReason when p
// fails any structural/privacy/capacity/trait gate. selfRouteOwner is true
// when this is a self-route request and p is owned by the requesting account:
// it (1) drops the hardware-trust floor to TrustNone — a personal Mac will not
// be MDM/MDA enrolled, so without this it would be unroutable to its own owner
// — and (2) admits a private-only machine, which is otherwise excluded from
// the public fleet. Every privacy-critical gate (RuntimeVerified, private-text
// support, challenge freshness) still applies. traits carry the request shape
// into the shape-keyed inference-error cooldown and the render-broken /
// version-floor eligibility gates. ignoreProviderBreaker is threaded into the
// routing gate: only the selectBestCandidateLockedFull fail-open fallback pass
// sets it true. now is the scan clock: hot-path callers walk the whole fleet
// and must read the wall clock ONCE per scan, not once per provider; every
// time-keyed gate (challenge freshness, cooldowns, breaker, clamp) evaluates
// against that single instant.
//
// Writes into caller-owned evaluation storage and names WHICH gate dropped
// a failing provider. Fleet walks and the fleet sampler reuse stack storage;
// only the evidence needed after evaluation is retained in a candidate.
// On a gate failure it returns (false, the
// closed GateReason that dropped p) WITHOUT touching *dst; on success *dst is
// fully overwritten — including hbAgeMs, stamped from the threaded now so the
// system-profiler record carries the heartbeat age the scan actually saw —
// and the reason is GateReasonCount.
func (r *Registry) snapshotProviderIntoLockedEx(dst *routingSnapshot, p *Provider, model string, traits RequestTraits, selfRouteOwner bool, ignoreProviderBreaker bool, now time.Time) (bool, GateReason) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return r.snapshotProviderIntoPLockedEx(dst, p, model, traits, selfRouteOwner, ignoreProviderBreaker, now)
}

// snapshotProviderIntoPLockedEx is snapshotProviderIntoLockedEx for a caller
// that ALREADY holds p.mu — the reservation commit and the plan consumption,
// which take the snapshot, rebuild the cost, compare and debit inside one p.mu
// section so nothing can change the provider in between. Caller holds r.mu
// (either mode) and p.mu.
func (r *Registry) snapshotProviderIntoPLockedEx(dst *routingSnapshot, p *Provider, model string, traits RequestTraits, selfRouteOwner bool, ignoreProviderBreaker bool, now time.Time) (bool, GateReason) {
	if ok, reason := r.providerRoutingGateReasonLockedEx(p, model, traits, selfRouteOwner, now, ignoreProviderBreaker, false); !ok {
		return false, reason
	}

	serviceReport := capacityvalue.NewServiceReport(p.BackendCapacity)
	r.fillRoutingSnapshotPLocked(dst, p, model, now, serviceReport)
	// Heartbeat age from the scan clock (system-profiler record); a zero
	// LastHeartbeat saturates rather than reading as "fresh".
	dst.hbAgeMs = heartbeatAgeMs(now, p.LastHeartbeat)

	// Concurrency headroom with the quality-concurrency cap: a slow model whose
	// quality batch is below the flat fallback (e.g. Gemma at ~14 tok/s solo →
	// batch 1-2) stops being admittable once it is at its quality cap, so load
	// spreads across boxes instead of collapsing a few. The cap resolves the
	// model's own static solo rate internally (solo median / seed → provider
	// benchmark fallback) — NOT dst.decodeTPS, which stays the provider-level
	// rate for TTFT/cost estimation, and NOT the observed-under-load value.
	// No-op (legacy flat cap) when the cap is disabled.
	dst.hasHeadroom = r.hasConcurrencyHeadroomWithReportLocked(p, model, serviceReport)
	return true, GateReasonCount
}

// heartbeatAgeMs is now − lastHeartbeat in milliseconds, clamped to int32
// (a zero LastHeartbeat saturates rather than producing a nonsense value).
func heartbeatAgeMs(now, lastHeartbeat time.Time) int32 {
	return selection.HeartbeatAgeMs(now, lastHeartbeat)
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
const coldLoadCatalogGBToMemGiB = admission.ColdLoadCatalogGBToMemGiB

// backendFreeForLoadGB returns the provider-reported free_for_load_gb (nil-safe).
// Caller must hold the provider lock when passing p.BackendCapacity.
func backendFreeForLoadGB(bc *protocol.BackendCapacity) *float64 {
	if bc == nil {
		return nil
	}
	return bc.FreeForLoadGB
}

func pendingTokenBudget(pr *PendingRequest) int {
	if pr == nil {
		return 0
	}
	return admission.PendingTokenBudget(pr.EstimatedPromptTokens, pr.RequestedMaxTokens, defaultRequestedMaxTokens)
}

// buildCandidateWithReason returns the candidate plus, on rejection,
// the reason so callers can split metrics by failure mode.
// now is the caller's scan clock (see snapshotProviderLockedEx). This is the
// allocation form for cold callers (commit and plan revalidation); the fleet
// scan passes an arena slot and its separate stack snapshot to buildCandidateInto.
func (r *Registry) buildCandidateWithReason(snap *routingSnapshot, pr *PendingRequest, now time.Time) (*routingCandidate, candidateRejection, bool) {
	c := &routingCandidate{}
	reason, _, ok := r.buildCandidateInto(c, snap, pr, now)
	if !ok {
		return nil, reason, false
	}
	return c, rejectNone, true
}

// buildCandidateInto computes routing cost from the transient snapshot and
// retains only the evidence consumed after evaluation in c.
// On rejection it returns the candidateRejection class the legacy counters
// split on (capacity / model-too-large / vision) AND the closed GateReason
// naming the exact drop, including the drops the candidateRejection enum
// reports as rejectNone (crashed/reloading slot, thermal critical), so the
// system-profiler routing record can tally them; c is then left partially
// written and must be discarded by the caller (the arena releases the slot).
// The counter semantics of candidateRejection are unchanged. Caller holds r.mu.
func (r *Registry) buildCandidateInto(c *routingCandidate, snap *routingSnapshot, pr *PendingRequest, now time.Time) (candidateRejection, GateReason, bool) {
	statePenalty, eligible := slotStatePenalty(snap.slotState)
	if !eligible {
		if snap.slotState == "crashed" {
			return rejectNone, GateSlotCrashed, false
		}
		return rejectNone, GateSlotReloading, false
	}
	if !snap.hasHeadroom {
		return rejectCapacity, GateNoHeadroom, false
	}

	if snap.systemMetrics.ThermalState == "critical" {
		return rejectNone, GateThermalCritical, false
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
		return rejectModelTooLarge, GateModelTooLarge, false
	}

	// Free-memory admission gate (Phase 1). A provider that claims to
	// serve the model but doesn't have headroom for weights + KV cache
	// is rejected here so we don't OOM the backend post-routing.
	if !memorypolicy.Admits(memoryPolicySnapshot(snap), reqPrompt, reqMax) {
		return rejectCapacity, GateFreeMemory, false
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
	// Both the base cost and long-prompt bias use the qualified width's prefill
	// rate when available, then the live EWMA and static registration/x12 chain.
	// Reading snap.prefillTPS directly would bypass that shared rate policy.
	prefillTPS := resolvePrefillTPS(snap)
	thisReqMs := float64(reqPrompt)/prefillTPS*1000.0 + float64(reqMax)/effectiveTPS*1000.0
	// Long-prompt fastest-tier preference: amplify the first-token-blocking time
	// for very long prompts so the provider that reaches first token soonest is
	// strongly preferred, reducing pre-first-token client_gone. The amplified
	// quantity is the FULL time-to-first-token (TTFT): prefill PLUS, for a COLD
	// provider, the model-load latency (statePenalty, ~30s). Prefill uses
	// resolvePrefillTPS so the bias follows the same qualified/observed fallback
	// policy as the base prefill cost.
	// Amplifying the full cold-load+prefill TTFT — not just prefill — prevents the
	// long-prompt bias from pulling a long prompt onto a cold box whose fast
	// prefill is dwarfed by the load and which is therefore slower end-to-end than
	// the fastest warm provider. Folded into thisReqMs so the cost breakdown
	// invariant (sum of terms == Total) holds. Returns 0 — and so leaves the cost
	// byte-for-byte unchanged — for short prompts and when the knob is off.
	prefillMs := float64(reqPrompt) / prefillTPS * 1000.0
	c.pricedPromptTokens = reqPrompt
	c.prefillCostMs = prefillMs + longPromptPenalty(reqPrompt, prefillMs)
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
	capacityRateMs, capacityRejectRate := r.capacityRatePenaltyFor(snap.provider, snap.model, now)
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

	c.snapshot = retainCandidateSnapshot(snap)
	c.CandidateBinding = snap.CandidateBinding
	if c.provider != nil {
		c.ProviderID = c.provider.ID
	}
	// The ratio the profiler records is exactly the one this candidate was
	// gated on (TTFTCalibrationRatio on the decision).
	c.calibrationRatio = calibrationRatio
	c.costMs = cost
	c.effectiveQueue = effectiveQueue
	c.effectiveTPS = effectiveTPS
	c.capacityRejectRate = capacityRejectRate
	c.breakdown = costBreakdown{
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
	}
	return rejectNone, GateReasonCount, true
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
// Qualified curves use their measured conservative width point; unmatched
// configurations fall back through observed EWMA, fleet median and benchmark.
func resolveEffectiveTPS(snap *routingSnapshot) float64 {
	return (performance.Rates{Profile: (*performance.Profile)(snap.performanceProfile),
		StaticDecode: snap.decodeTPS, ObservedDecode: snap.observedDecodeTPS,
		FleetMedian: snap.fleetMedianTPS, ObservedBatch: snap.backendRunning,
		Occupancy: snapshotOccupancy(snap)}).EffectiveDecode(effectiveTPSLoadFactor)
}

// resolvePrefillTPS uses the qualified conservative width point for TTFT,
// matching resolveEffectiveTPS. A workload-specific live EWMA cannot replace
// that reviewed rate. Without a fitting point, prefer observed prefill EWMA,
// then snap.prefillTPS (registration benchmark or decode×prefillToDecodeRatio).
// The fallback is clamped to maxPrefillTPS; profile validation enforces the same
// bound for reviewed points.
func resolvePrefillTPS(snap *routingSnapshot) float64 {
	return (performance.Rates{Profile: (*performance.Profile)(snap.performanceProfile),
		StaticPrefill: snap.prefillTPS, ObservedPrefill: snap.observedPrefillTPS,
		Occupancy: snapshotOccupancy(snap)}).Prefill()
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
func snapshotOccupancy(snap *routingSnapshot) int {
	return ttftWork(snap).Occupancy()
}

func resolvedDecodeTPS(p *Provider) float64 {
	return quality.DecodeFallback(p.DecodeTPS, p.Hardware)
}

// resolvedModelTPSLocked returns the best per-model decode/prefill TPS samples
// for a provider. BackendCapacity.Slots is authoritative for Swift providers:
// when the matching slot reports observed EWMAs, prefer them over static
// registration benchmarks. Non-positive observed values are treated as missing.
// Caller must hold p.mu.
func resolvedModelTPSLocked(p *Provider, model string) (decodeTPS, prefillTPS float64) {
	decodeTPS = resolvedDecodeTPS(p)
	prefillTPS = resolvedPrefillTPS(p)
	return quality.ModelRates(model, p.BackendCapacity, decodeTPS, prefillTPS)
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

// ttftOccupancyAlpha scales the Phase-0 head-of-line occupancy term in
// candidateSnapshot.shadowTTFT. The term never reaches the live
// ttftMsFromSnapshot, routing cost, MaxTTFTMs ceiling or preflight bestTTFT;
// raising alpha changes only the shadow signal. Zero disables the term.
// Configured once at startup via SetTTFTOccupancyAlpha
// (EIGENINFERENCE_TTFT_OCCUPANCY_ALPHA), read-only on routing paths thereafter.
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
const defaultLongPromptThresholdTokens = longprompt.DefaultThresholdTokens

// defaultLongPromptPrefillWeight is the multiplier applied to the prefill term of
// the routing cost for long prompts. 1.0 is behavior-neutral; >1 amplifies the
// prefill component so the fastest-prefill (== fastest chip tier) warm provider is
// strongly preferred once the prompt is long enough that prefill dominates TTFT.
const defaultLongPromptPrefillWeight = longprompt.DefaultPrefillWeight

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
	return longprompt.Penalty(reqPromptTokens, ttftBlockMs, longPromptThresholdTokens, longPromptPrefillWeight)
}

func resolvedPrefillTPS(p *Provider) float64 {
	return quality.PrefillFallback(p.PrefillTPS, resolvedDecodeTPS(p), prefillToDecodeRatio)
}

// decodeFloorUseFleetMedian gates the tier-2 (fleet-median) solo-rate source in
// candidateSnapshot.projectedDecodeTPS. Read LIVE (no restart); default ON. Set
// EIGENINFERENCE_DECODE_FLOOR_USE_FLEET_MEDIAN=false for byte-for-byte pre-fix
// behavior (idle boxes fall straight to the static benchmark).
func decodeFloorUseFleetMedian() bool {
	return quality.DecodeFloorUseFleetMedian()
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
func (r *Registry) providerCanAdmitLockedEx(p *Provider, model string, traits RequestTraits, selfRouteOwner bool, ignoreProviderBreaker bool, now time.Time) bool {
	return (&ProviderEligibility{registry: r}).admitLocked(p, model, traits, selfRouteOwner, ignoreProviderBreaker, now)
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

// QuickCapacityCheckWithTTFTForRequest retains the historical calibrated TTFT
// diagnostic for telemetry and calibration replay. Live request preflight uses
// QuickFirstContentCapacityForRequest with request clocks and cache evidence.
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
	// Per-model index: visit only providers advertising the model (gates
	// unchanged; see model_index.go).
	for _, p := range r.providersForModelLocked(model) {
		// Filter by allowed serials before acquiring the provider lock
		// (providerMatchesAllowedSerial takes p.mu internally).
		if len(allowedSet) > 0 && !providerMatchesAllowedSerial(p, allowedSet) {
			continue
		}

		p.mu.Lock()

		// Per-provider routing gates (same source of truth as snapshotProviderIntoLockedEx
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
			if (r.gateOf(p).capacityCooled(model, now) || providerDrainingLocked(p, now)) &&
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
		serviceReport, hasHeadroom := r.concurrencyHeadroomReportLocked(p, model)
		if !hasHeadroom {
			p.mu.Unlock()
			capacityRejections++
			continue
		}

		// Project the same locked provider state used by reservation scoring.
		var snap routingSnapshot
		r.fillRoutingSnapshotPLocked(&snap, p, model, now, serviceReport)

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
		if !memorypolicy.Admits(memoryPolicySnapshot(&snap), dummyPR.EstimatedPromptTokens, dummyPR.RequestedMaxTokens) {
			capacityRejections++
			continue
		}

		candidateCount++
		if snap.hasBackendCapacity {
			ttft := estimatedTTFTFromSnapshot(&snap, estimatedPromptTokens)
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

func estimatedTTFTFromSnapshot(snap *routingSnapshot, reqPromptTokens int) time.Duration {
	ttftMs := ttftMsFromSnapshot(snap, reqPromptTokens)
	if ttftMs <= 0 || math.IsNaN(ttftMs) || math.IsInf(ttftMs, 0) {
		return 0
	}
	// Keep this historical capacity diagnostic aligned with the legacy
	// candidate cost breakdown. It is not a first-content confidence bound.
	ttftMs = calibratedTTFTMs(snap, ttftMs)
	return time.Duration(ttftMs * float64(time.Millisecond))
}

// ttftMsFromSnapshot returns the estimated time-to-first-token in milliseconds
// for historical candidate and capacity diagnostics. Live request selection
// and feasibility use estimateFirstContent; calibration of this diagnostic
// cannot establish confidence for stale or missing performance evidence.
//
// Token-budget fields are admission/memory reservations, not decode work that
// must fully drain before this request can emit a first token. Continuous
// batching lets a newly-admitted request join the decode loop once its prefill
// completes; existing active max-output reservations only slow the next decode
// step, which is already reflected by effectiveTPS. Count waiting prefills ahead
// and this request's own prefill instead of treating active_token_budget_used as
// a serial decode backlog.
func ttftMsFromSnapshot(snap *routingSnapshot, reqPromptTokens int) float64 {
	if !snap.hasBackendCapacity {
		return 0
	}
	statePenalty, _ := slotStatePenalty(snap.slotState)
	return (ttftforecast.Estimate{HasCapacity: true, StatePenalty: statePenalty,
		PrefillTPS: resolvePrefillTPS(snap), DecodeTPS: resolveEffectiveTPS(snap),
		Work: ttftWork(snap)}).Base(reqPromptTokens)
}

func queuedPrefillTokensAhead(snap *routingSnapshot, reqPromptTokens int) float64 {
	return ttftWork(snap).QueuedPrefill(reqPromptTokens)
}

func ttftWork(snap *routingSnapshot) ttftforecast.Work {
	return ttftforecast.Work{Running: snap.backendRunning, Waiting: snap.backendWaiting,
		Pending: snap.pendingForModel, PrefillKnown: snap.pendingPrefillKnown,
		PrefillTokens: snap.pendingPrefillTokens, PrefillUnknown: snap.pendingPrefillUnknown}
}
