package registry

import (
	"math"
	"time"
)

// AccountAffinityObservation contains bounded selection diagnostics only. It
// must never contain the account, model, physical identity, or rendezvous hash.
// The caller supplies Applied and WouldChange using its already-selected
// legacy winner; evaluation itself never draws from the legacy selector's RNG.
type AccountAffinityObservation struct {
	Mode           string
	Reason         string
	Evaluated      bool
	Applied        bool
	WouldChange    bool
	Rank           int
	CandidateCount int
	// AddedTTFTMs is this machine's estimated load-induced delay above its
	// own idle baseline, never the speed difference from another provider.
	AddedTTFTMs float64
}

// evaluateAccountAffinity chooses from the existing, request-local candidate
// pool AFTER all hard gates and owner/version/decode preferences. Returning nil
// means ordinary cost routing, never rejection or waiting. Shadow and on do
// identical evaluation; only the caller decides whether to apply the result.
func evaluateAccountAffinity(pool []*routingCandidate, pr *PendingRequest, cfg AccountAffinityConfig) (*routingCandidate, AccountAffinityObservation) {
	return evaluateAccountAffinityAt(pool, pr, cfg, time.Now())
}

func evaluateAccountAffinityAt(pool []*routingCandidate, pr *PendingRequest, cfg AccountAffinityConfig, now time.Time) (*routingCandidate, AccountAffinityObservation) {
	observation := AccountAffinityObservation{Mode: normalizedAccountAffinityMode(cfg.Mode)}
	if observation.Mode == AccountAffinityOff {
		observation.Reason = "off"
		return nil, observation
	}
	if cfg.Check() != nil {
		observation.Mode, observation.Reason = AccountAffinityOff, "invalid_config"
		return nil, observation
	}
	if pr == nil || pr.ConsumerKey == "" {
		observation.Reason = "missing_account"
		return nil, observation
	}
	if pr.Model == "" {
		observation.Reason = "missing_model"
		return nil, observation
	}
	if pr.RequiresVision {
		observation.Reason = "vision"
		return nil, observation
	}
	if len(pool) == 0 {
		observation.Reason = "no_candidates"
		return nil, observation
	}
	observation.Evaluated = true

	// Rank identities independently of speed. Each candidate's busy check uses
	// only its own load estimate; a faster peer must not displace an idle home.
	hasKnownTTFT := false
	for _, candidate := range pool {
		if candidate == nil {
			continue
		}
		candidate.accountAffinityRanked, candidate.accountAffinityEligible = false, false
		hasKnownTTFT = hasKnownTTFT || accountAffinityHasKnownTTFT(candidate)
		if candidate.snapshot.affinityIdentity.valid() {
			candidate.accountAffinityScore = accountAffinityScore(pr.ConsumerKey, pr.Model, candidate.snapshot.affinityIdentity)
			candidate.accountAffinityRanked = true
			observation.CandidateCount++
		}
	}
	if observation.CandidateCount == 0 {
		observation.Reason = "no_identity"
		return nil, observation
	}
	if !hasKnownTTFT {
		observation.Reason = "no_known_ttft"
		return nil, observation
	}

	var winner *routingCandidate
	for _, candidate := range pool {
		if candidate == nil || !candidate.accountAffinityRanked || !accountAffinityFeasibleAt(candidate, pr, cfg, now) {
			continue
		}
		candidate.accountAffinityEligible = true
		if winner == nil || accountAffinityCandidateBefore(candidate, winner) {
			winner = candidate
		}
	}
	if winner == nil {
		observation.Reason = "no_eligible_candidate"
		return nil, observation
	}
	observation.Rank = 1
	for _, candidate := range pool {
		if candidate != nil && candidate.accountAffinityRanked && accountAffinityCandidateBefore(candidate, winner) {
			observation.Rank++
		}
	}
	observation.AddedTTFTMs = accountAffinityLoadDelayMs(winner)
	observation.Reason = "preferred"
	if observation.Rank > 1 {
		observation.Reason = "spill"
	}
	return winner, observation
}

// accountAffinityFeasible repeats the affinity-only busy check against the
// candidate's own idle baseline and the request's absolute deadline. Callers
// still enforce every hard admission gate before reserving.
func accountAffinityFeasible(candidate *routingCandidate, pr *PendingRequest, cfg AccountAffinityConfig) bool {
	return accountAffinityFeasibleAt(candidate, pr, cfg, time.Now())
}

func accountAffinityFeasibleAt(candidate *routingCandidate, pr *PendingRequest, cfg AccountAffinityConfig, now time.Time) bool {
	if candidate == nil || pr == nil || pr.RequiresVision || cfg.Check() != nil || !candidate.snapshot.affinityIdentity.valid() ||
		!accountAffinityQualityFits(candidate, pr) {
		return false
	}
	delayMs, loadedTTFTMs := accountAffinityLoadEstimate(candidate)
	if delayMs > cfg.MaxTTFTPenaltyMs {
		return false
	}
	ceiling := math.Inf(1)
	if pr.MaxTTFTMs > 0 {
		ceiling = math.Min(ceiling, pr.MaxTTFTMs)
	}
	if !pr.FirstContentDeadline.IsZero() {
		ceiling = math.Min(ceiling, float64(pr.FirstContentDeadline.Sub(now))/float64(time.Millisecond))
	}
	return accountAffinityFinitePositive(loadedTTFTMs) && loadedTTFTMs <= ceiling
}

func accountAffinityQualityFits(candidate *routingCandidate, pr *PendingRequest) bool {
	if !accountAffinityHasKnownTTFT(candidate) {
		return false
	}
	// Do not promote a known capacity-rejecting or thermally degraded machine
	// past the existing cost scheduler's health preference. Ordinary HealthMs
	// is not itself a fault: every resident model pays a GPU-memory term.
	if candidate.breakdown.CapacityRateMs > 0 {
		return false
	}
	switch candidate.snapshot.systemMetrics.ThermalState {
	case "fair", "serious", "critical":
		return false
	}
	// Calibrated live TTFT intentionally omits the shadow occupancy term.
	// Enforce the request's decode preference here using IMMEDIATE occupancy
	// instead, so unreflected reservations do not look like an idle batch.
	if pr.MinDecodeTPS > 0 {
		rate := projectedPerRequestDecodeTPSAtBatch(&candidate.snapshot, accountAffinityOccupancy(&candidate.snapshot))
		return accountAffinityFinitePositive(rate) && rate >= pr.MinDecodeTPS
	}
	return true
}

// accountAffinityOccupancy includes co-resident models sharing the same GPU.
// The coordinator and heartbeat counts describe overlapping work: use their
// maximum, not their sum. Applying the target model's degradation curve to
// this conservative whole-box count is an affinity preference only; ordinary
// scoring, hard admission, and the shadow TTFT estimator stay unchanged.
func accountAffinityOccupancy(snapshot *routingSnapshot) int {
	return max(snapshotOccupancy(snapshot), snapshot.totalPending, snapshot.affinityBackendOccupancy)
}

func accountAffinityHasKnownTTFT(candidate *routingCandidate) bool {
	return candidate.snapshot.modelLoaded && slotStateModelLoaded(candidate.snapshot.slotState) &&
		candidate.snapshot.hasBackendCapacity && accountAffinityFinitePositive(candidate.breakdown.TTFTMs)
}

func accountAffinityFinitePositive(value float64) bool {
	return value > 0 && !math.IsNaN(value) && !math.IsInf(value, 0)
}
