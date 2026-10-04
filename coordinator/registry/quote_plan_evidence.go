package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/forecast"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/shortlist"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Quote tiers prefer confirmed candidates, then unprobed candidates, then
// refusals. Refusals remain available to live reservation revalidation.
func planEntryRank(v PlanEntry) int {
	switch {
	case v.Demoted:
		return 2
	case v.Confirmed:
		return 0
	default:
		return 1
	}
}

// Caller holds the leaf mutex. Consumed candidates never enter this reorder.
func (dp *QuotePlan) resortTailLocked() {
	remaining := dp.pendingEntriesLocked()
	count := len(remaining)
	for i := range count {
		bestTier := 3
		for _, entry := range remaining {
			bestTier = min(bestTier, planEntryRank(entry.PlanEntry))
		}
		candidates := make([]*routingCandidate, 0, len(remaining))
		positions := make(map[*routingCandidate]int, len(remaining))
		for j, entry := range remaining {
			if planEntryRank(entry.PlanEntry) != bestTier {
				continue
			}
			forecast := entry.FirstContent
			if entry.Confirmed && entry.QuoteTTFTP50 > 0 {
				forecast.ExpectedMs = max(forecast.ExpectedMs, float64(entry.QuoteTTFTP50)/float64(time.Millisecond)+forecast.RestoreMs)
			}
			candidate := &routingCandidate{CandidateBinding: entry.CandidateBinding, costMs: entry.CostMs, firstContent: forecast,
				cacheEvidenceWeight: entry.CacheEvidenceWeight, cacheEstimatedTTFTSavedMs: entry.CacheEstimatedTTFTSavedMs, cacheAffinityEligible: entry.CacheAffinityEligible,
				breakdown: costBreakdown{HealthMs: entry.HealthMs, CapacityRateMs: entry.CapacityRateMs}}
			candidates = append(candidates, candidate)
			positions[candidate] = j
		}
		chosen, _, _, _ := selectRoutingCandidateWithAffinity(candidates, dp.affinity)
		j := positions[chosen]
		dp.alternates().Rank(remaining[j].ProviderID, i)
		remaining = append(remaining[:j], remaining[j+1:]...)
	}
}

// ConfirmEntry enriches an unconsumed candidate without replacing its original
// forecast. A late quote cannot resurrect a consumed candidate.
func (dp *QuotePlan) ConfirmEntry(providerID string, quote *protocol.CapacityQuoteMessage) {
	dp.confirmEntryAt(providerID, quote, time.Now())
}

func (dp *QuotePlan) confirmEntryAt(providerID string, quote *protocol.CapacityQuoteMessage, observedAt time.Time) {
	if dp == nil || quote == nil {
		return
	}
	dp.mu.Lock()
	defer dp.mu.Unlock()
	dp.alternates().Range(func(handle shortlist.Handle) bool {
		v := &dp.entries[handle.Index].PlanEntry
		if v.ProviderID != providerID {
			return true
		}
		v.Confirmed = true
		v.Demoted = false
		v.QuoteTTFTP50 = time.Duration(quote.TTFTP50MS * float64(time.Millisecond))
		v.QuoteTTFTP90 = time.Duration(quote.TTFTP90MS * float64(time.Millisecond))
		v.QuoteAvailableTokens = quote.AvailableTokenBudget
		v.QuoteConfidence = quote.Confidence
		v.QuoteObservedAt = observedAt
		v.QuoteCapacitySeq = quote.CapacitySeq
		dp.resortTailLocked()
		return false
	})
}

// DemoteEntry applies a refusal or transport failure to an unconsumed entry.
// The newer refusal takes precedence over an earlier confirmation.
func (dp *QuotePlan) DemoteEntry(providerID string) {
	if dp == nil {
		return
	}
	dp.mu.Lock()
	defer dp.mu.Unlock()
	dp.alternates().Range(func(handle shortlist.Handle) bool {
		v := &dp.entries[handle.Index].PlanEntry
		if v.ProviderID != providerID {
			return true
		}
		v.Demoted = true
		v.Confirmed = false
		dp.resortTailLocked()
		return false
	})
}

// BestConfirmedBackup reports fresh high-confidence evidence for hedge timing.
// Reservation independently revalidates its identity, sequence and capacity.
func (dp *QuotePlan) BestConfirmedBackup() (providerID string, ttftP90 time.Duration, ok bool) {
	if dp == nil {
		return "", 0, false
	}
	dp.mu.Lock()
	defer dp.mu.Unlock()
	now := time.Now()
	dp.alternates().Range(func(handle shortlist.Handle) bool {
		entry := dp.entries[handle.Index]
		v := entry.PlanEntry
		if p90, usable := forecast.BackupTiming(v.FirstContent, entry.EvidenceQualified, entry.ForecastAt, forecastQuote(v), now); usable {
			providerID, ttftP90, ok = v.ProviderID, p90, true
			return false
		}
		return true
	})
	return
}

// Probe fanout receives detached values without holding the plan's leaf lock.
func (dp *QuotePlan) probeTargets() []planEntry {
	if dp == nil {
		return nil
	}
	dp.mu.Lock()
	defer dp.mu.Unlock()
	targets := make([]planEntry, 0, dp.alternates().Remaining())
	dp.alternates().Range(func(handle shortlist.Handle) bool {
		e := dp.entries[handle.Index]
		if e.Confirmed || e.Demoted {
			return true
		}
		targets = append(targets, e)
		return true
	})
	return targets
}
