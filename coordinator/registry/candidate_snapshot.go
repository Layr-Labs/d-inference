package registry

import (
	"github.com/eigeninference/d-inference/coordinator/internal/registry/performance"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/ttftforecast"
)

// candidateSnapshot retains only evidence consumed after evaluation. Full
// admission and forecast snapshots stay in caller-owned evaluation storage;
// retained candidates never point into that storage or back into live capacity.
// Performance profiles are immutable catalogs, configured before serving.
type candidateSnapshot struct {
	performanceProfile *servingPerformanceProfile
	chipFamily         string
	slotState          string
	capacitySeq        uint64
	totalPending       int
	pendingForModel    int
	backendRunning     int
	backendWaiting     int
	decodeTPS          float64
	observedDecodeTPS  float64
	fleetMedianTPS     float64
	prefillTPS         float64
	observedPrefillTPS float64

	pendingPrefillTokens  float64
	pendingPrefillUnknown int
	pendingPrefillKnown   bool
	modelLoaded           bool
	hasBackendCapacity    bool
	wholeMacBusy          bool
	wholeMacWorkKnown     bool
	partialPrefillRows    int
	evidenceGapAgeMs      int32
	hbAgeMs               int32
	activeTokenBudgetUsed int64
	activeTokenBudgetMax  int64
	queuedPrefillTokens   int64
}

func retainCandidateSnapshot(s *routingSnapshot) candidateSnapshot {
	return candidateSnapshot{
		performanceProfile: s.performanceProfile,
		chipFamily:         s.chipFamily, slotState: s.slotState, capacitySeq: s.capacitySeq,
		totalPending: s.totalPending, pendingForModel: s.pendingForModel,
		backendRunning: s.backendRunning, backendWaiting: s.backendWaiting,
		decodeTPS: s.decodeTPS, observedDecodeTPS: s.observedDecodeTPS, fleetMedianTPS: s.fleetMedianTPS,
		prefillTPS: s.prefillTPS, observedPrefillTPS: s.observedPrefillTPS,
		pendingPrefillTokens: s.pendingPrefillTokens, pendingPrefillUnknown: s.pendingPrefillUnknown,
		pendingPrefillKnown: s.pendingPrefillKnown, modelLoaded: s.modelLoaded,
		hasBackendCapacity: s.hasBackendCapacity, wholeMacBusy: s.wholeMacBusy,
		wholeMacWorkKnown: s.wholeMacWorkKnown, partialPrefillRows: s.partialPrefillRows,
		evidenceGapAgeMs: s.evidenceGapAgeMs, hbAgeMs: s.hbAgeMs,
		activeTokenBudgetUsed: s.activeTokenBudgetUsed, activeTokenBudgetMax: s.activeTokenBudgetMax,
		queuedPrefillTokens: s.queuedPrefillTokens,
	}
}

func (s *candidateSnapshot) work() ttftforecast.Work {
	return ttftforecast.Work{Running: s.backendRunning, Waiting: s.backendWaiting,
		Pending: s.pendingForModel, PrefillKnown: s.pendingPrefillKnown,
		PrefillTokens: s.pendingPrefillTokens, PrefillUnknown: s.pendingPrefillUnknown}
}

func (s *candidateSnapshot) occupancy() int {
	return s.work().Occupancy()
}

func (s *candidateSnapshot) rates() performance.Rates {
	return performance.Rates{Profile: (*performance.Profile)(s.performanceProfile),
		StaticDecode: s.decodeTPS, ObservedDecode: s.observedDecodeTPS, FleetMedian: s.fleetMedianTPS,
		StaticPrefill: s.prefillTPS, ObservedPrefill: s.observedPrefillTPS,
		ObservedBatch: s.backendRunning, Occupancy: s.occupancy()}
}

// projectedDecodeTPS unwinds the observed rate at backendRunning, then projects
// the new request at joinBatch+1. Shadow estimates pass occupancy as joinBatch
// to include pending peers not yet reflected in the heartbeat.
func (s *candidateSnapshot) projectedDecodeTPS(joinBatch int) float64 {
	useFleetMedian := !(s.observedDecodeTPS > 0) && decodeFloorUseFleetMedian()
	return s.rates().ProjectedDecode(joinBatch, effectiveTPSLoadFactor, useFleetMedian)
}

// shadowTTFT adds occupancy delay only to the shadow estimate, never to the live
// cost or deadline ceiling. An unknown base stays unknown even when occupied.
func (s *candidateSnapshot) shadowTTFT(prompt int) float64 {
	statePenalty, _ := slotStatePenalty(s.slotState)
	rates := s.rates()
	base := (ttftforecast.Estimate{HasCapacity: s.hasBackendCapacity, StatePenalty: statePenalty,
		PrefillTPS: rates.Prefill(), DecodeTPS: rates.EffectiveDecode(effectiveTPSLoadFactor), Work: s.work()}).Base(prompt)
	if base <= 0 || ttftOccupancyAlpha <= 0 {
		return base
	}
	occupancy := s.occupancy()
	if occupancy <= 0 {
		return base
	}
	return ttftforecast.Shadow(base, ttftforecast.OccupancyDelay(ttftOccupancyAlpha, occupancy, s.projectedDecodeTPS(occupancy)))
}
