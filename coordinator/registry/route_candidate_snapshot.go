package registry

import (
	"sort"
)

const (
	maxPersistedCandidates = 24
	maxPersistedRejected   = 8
)

// RouteCandidateSnapshot is the lock-copied, public view of one provider the
// scheduler considered. It is safe to persist asynchronously: it holds no
// pointers and no prompt content.
type RouteCandidateSnapshot struct {
	ProviderID          string
	Rank                int
	Selected            bool
	Eligible            bool
	RejectionReason     string
	CostMs              float64
	StateMs             float64
	QueueMs             float64
	PendingMs           float64
	BacklogMs           float64
	ThisReqMs           float64
	HealthMs            float64
	CapacityRateMs      float64
	TTFTMs              float64
	EffectiveQueue      int
	EffectiveTPS        float64
	StaticTPS           float64
	EffectivePrefillTPS float64
	StaticPrefillTPS    float64
	BatchSize           int
	ChipFamily          string
	HardwareTier        string
	MemoryGB            int
	SlotState           string
	MemoryPressure      float64
	ThermalState        string
	GPUMemoryActiveGB   float64
	FreeForLoadGB       float64
	WedgeSuspected      bool
	AffinityApplied     bool
	AffinityDiscountMs  float64
	CapacityRejectRate  float64
}

func appendRejected(dst []rejectedCandidate, rec rejectedCandidate) []rejectedCandidate {
	if len(dst) >= maxPersistedRejected*2 {
		return dst
	}
	return append(dst, rec)
}

func snapshotRouteCandidates(winner *routingCandidate, scan candidateScan, reserved bool) []RouteCandidateSnapshot {
	winnerID := providerIDOf(winner)
	seen := make(map[string]struct{}, len(scan.pool)+len(scan.rejected))

	eligible := make([]RouteCandidateSnapshot, 0, len(scan.pool))
	for _, c := range scan.pool {
		id := providerIDOf(c)
		if id == "" {
			continue
		}
		seen[id] = struct{}{}
		eligible = append(eligible, candidateToSnapshot(c, "", true))
	}
	sort.SliceStable(eligible, func(i, j int) bool {
		if eligible[i].CostMs == eligible[j].CostMs {
			return eligible[i].ProviderID < eligible[j].ProviderID
		}
		return eligible[i].CostMs < eligible[j].CostMs
	})

	rejected := make([]RouteCandidateSnapshot, 0, len(scan.rejected))
	for _, rec := range scan.rejected {
		id := rejectedProviderID(rec)
		if id == "" {
			continue
		}
		if _, ok := seen[id]; ok {
			continue
		}
		seen[id] = struct{}{}
		if rec.candidate != nil {
			rejected = append(rejected, candidateToSnapshot(rec.candidate, rec.reason, false))
			continue
		}
		rejected = append(rejected, rejectedSnapToSnapshot(rec.snap, rec.reason))
	}
	if len(rejected) > maxPersistedRejected {
		rejected = rejected[:maxPersistedRejected]
	}

	eligibleCap := maxPersistedCandidates - len(rejected)
	if eligibleCap < 1 {
		eligibleCap = 1
	}
	if len(eligible) > eligibleCap {
		// Keep the winner even if it is not among the cheapest eligibleCap
		// after a later admit re-check (reserved=false still ranks it).
		kept := eligible[:eligibleCap]
		if winnerID != "" {
			found := false
			for i := range kept {
				if kept[i].ProviderID == winnerID {
					found = true
					break
				}
			}
			if !found {
				for i := range eligible {
					if eligible[i].ProviderID == winnerID {
						kept[len(kept)-1] = eligible[i]
						break
					}
				}
			}
		}
		eligible = kept
	}

	out := make([]RouteCandidateSnapshot, 0, len(eligible)+len(rejected))
	for i := range eligible {
		row := eligible[i]
		row.Rank = i
		if reserved && winnerID != "" && row.ProviderID == winnerID {
			row.Selected = true
		}
		out = append(out, row)
	}
	for i := range rejected {
		row := rejected[i]
		row.Rank = -1
		out = append(out, row)
	}
	return out
}

func providerIDOf(c *routingCandidate) string {
	if c == nil || c.provider == nil {
		return ""
	}
	return c.provider.ID
}

func rejectedProviderID(rec rejectedCandidate) string {
	if id := providerIDOf(rec.candidate); id != "" {
		return id
	}
	if rec.snap.provider != nil {
		return rec.snap.provider.ID
	}
	return ""
}

func candidateToSnapshot(c *routingCandidate, reason string, eligible bool) RouteCandidateSnapshot {
	snap := rejectedSnapToSnapshot(c.snapshot, reason)
	snap.Eligible = eligible
	snap.CostMs = c.costMs
	snap.StateMs = c.breakdown.StateMs
	snap.QueueMs = c.breakdown.QueueMs
	snap.PendingMs = c.breakdown.PendingMs
	snap.BacklogMs = c.breakdown.BacklogMs
	snap.ThisReqMs = c.breakdown.ThisReqMs
	snap.HealthMs = c.breakdown.HealthMs
	snap.CapacityRateMs = c.breakdown.CapacityRateMs
	snap.TTFTMs = c.breakdown.TTFTMs
	snap.EffectiveQueue = c.effectiveQueue
	snap.EffectiveTPS = c.effectiveTPS
	snap.StaticTPS = c.snapshot.decodeTPS
	snap.EffectivePrefillTPS = resolvePrefillTPS(c.snapshot)
	snap.StaticPrefillTPS = c.snapshot.prefillTPS
	snap.AffinityDiscountMs = c.breakdown.CacheDiscountMs
	snap.AffinityApplied = c.breakdown.CacheDiscountMs > 0
	snap.CapacityRejectRate = c.capacityRejectRate
	if c.provider != nil {
		snap.ProviderID = c.provider.ID
	}
	return snap
}

func rejectedSnapToSnapshot(snap routingSnapshot, reason string) RouteCandidateSnapshot {
	out := RouteCandidateSnapshot{
		Eligible:          false,
		RejectionReason:   reason,
		ChipFamily:        snap.chipFamily,
		HardwareTier:      snap.hardwareTier,
		MemoryGB:          snap.memoryGB,
		SlotState:         snap.slotState,
		MemoryPressure:    snap.systemMetrics.MemoryPressure,
		ThermalState:      snap.systemMetrics.ThermalState,
		GPUMemoryActiveGB: snap.gpuMemoryActiveGB,
		BatchSize:         snap.backendRunning,
		WedgeSuspected:    snap.wedgeSuspected,
	}
	if snap.provider != nil {
		out.ProviderID = snap.provider.ID
	}
	if snap.freeForLoadGB != nil {
		out.FreeForLoadGB = *snap.freeForLoadGB
	}
	if snap.memoryGB == 0 && snap.totalMemoryGB > 0 {
		out.MemoryGB = int(snap.totalMemoryGB)
	}
	return out
}
