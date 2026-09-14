package registry

import (
	"context"
	"log/slog"

	"github.com/eigeninference/d-inference/coordinator/registry/routingcost"
)

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
	ThisReqMs  float64 // prefill+decode, including long-prompt and excess restore costs
	HealthMs   float64 // memory/CPU/thermal/GPU-util contribution
	// CapacityRateMs is the gray-box capacity-503 rate penalty added to the
	// winner's cost (faultstate/capacity_rate.go); 0 for healthy pairs. In-memory
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
	// PredictedDecodeTPS is projectedPerRequestDecodeTPS(winner snapshot): the
	// per-request decode rate this request is predicted to receive once admitted.
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
		PrefillDecodeRatio: routingPolicy.PrefillToDecodeRatio(),
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
	decision.StaticTPS = candidate.snapshot.DecodeTPS
	// Winner context for the system-profiler routing record: how stale the
	// winner's inputs were, what it was predicted to deliver, and what it was
	// already carrying — all from the pre-reserve snapshot, no extra locking.
	decision.SnapshotAgeMs = int(candidate.snapshot.HBAgeMs)
	decision.PredictedDecodeTPS = routingcost.ProjectedPerRequestDecodeTPS(&candidate.snapshot)
	decision.PendingForModel = candidate.snapshot.PendingForModel
	decision.TotalPending = candidate.snapshot.TotalPending
	// The ratio this candidate was actually scored with (captured at build,
	// no second read of the mutable calibrator): the TTFTMs/RawTTFTMs
	// quotient would be wrong for cold slots (the state penalty is
	// deliberately unscaled).
	decision.TTFTCalibrationRatio = candidate.calibrationRatio
	return decision
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
		"cache_estimated_ttft_saved_ms", winner.cacheEstimatedTTFTSavedMs,
		"effective_tps", winner.effectiveTPS,
		"effective_queue", winner.effectiveQueue,
		"candidates", candidates,
	)
}
