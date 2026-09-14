package dispatchplan

// probeTargets snapshots the unconsumed, not-yet-quoted entries for the probe
// fanout (ProbePlanCandidates). Copies of the Retained pairs, taken under
// dp.mu, so the fanout can inspect providers and mint probes without holding
// the plan lock while entries concurrently re-rank.
func (dp *Plan[C]) probeTargets() []Retained[C] {
	if dp == nil {
		return nil
	}
	dp.mu.Lock()
	defer dp.mu.Unlock()
	targets := make([]Retained[C], 0, len(dp.entries)-dp.cursor)
	for _, e := range dp.entries[dp.cursor:] {
		if e.View.Confirmed || e.View.Demoted {
			continue
		}
		targets = append(targets, e)
	}
	return targets
}
