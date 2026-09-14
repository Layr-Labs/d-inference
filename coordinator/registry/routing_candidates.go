package registry

type routingCandidate struct {
	cacheAffinityEligible bool
	// Exact base-score work eligible for a cache credit; never includes load or decode.
	pricedPromptTokens int
	prefillCostMs      float64
	provider           *Provider
	snapshot           routingSnapshot
	costMs             float64
	effectiveQueue     int
	breakdown          costBreakdown
	effectiveTPS       float64 // Phase 4 load-scaled TPS used in this candidate's cost
	// capacityRejectRate is the pair's windowed capacity-503 rate
	// (faultstate/capacity_rate.go), captured at candidate build so the winning
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
	// (faultstate/capacity_rate.go): rate × EIGENINFERENCE_CAPACITY_RATE_PENALTY_MS once
	// the pair's windowed reject rate clears the threshold with a minimum
	// sample. 0 for healthy pairs, so the cost is byte-for-byte unchanged.
	CapacityRateMs float64
	TTFTMs         float64 // calibrated TTFT estimate for this candidate (gate/ceiling input)
	// RawTTFTMs is the pre-calibration ttftMsFromSnapshot value. The calibrator
	// learns against it (see routingcost/calibration.go) so the feedback loop converges
	// on the absolute actual/predicted ratio instead of compounding.
	RawTTFTMs float64
	// CacheDiscountMs is subtracted only after every normal eligibility and
	// admission gate has passed. It never reduces reservations or token budgets.
	CacheDiscountMs float64
	Total           float64
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
	if !snap.ModelLoaded || snap.BackendRunning+snap.BackendWaiting != 0 || !snap.HasBackendCapacity {
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
