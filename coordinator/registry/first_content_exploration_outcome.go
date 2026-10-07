package registry

// RecordFirstContentExplorationOutcome feeds a delivered request or an
// exploration failure into identity-local backoff, not provider health.
// Callers exclude capacity sheds, neutral terminals, drain and client errors.
func (r *Registry) RecordFirstContentExplorationOutcome(providerID, model string, ok bool) {
	r.gates.RecordFirstContentExplorationOutcome(providerID, model, ok)
}

// SetFirstContentExplored captures the committed selection's use of the idle
// evidence exception or exploration median pricing, before dispatch starts.
func (pr *PendingRequest) SetFirstContentExplored(explored bool) {
	if pr != nil {
		pr.firstContentExplored = explored
	}
}

func (pr *PendingRequest) FirstContentExplored() bool {
	return pr != nil && pr.firstContentExplored
}

// ClaimFirstContentExplorationOutcome keeps timeout cancellation and any
// following attributable-stall fault from recording the same failure twice.
// Neutral terminals must not claim exploration feedback.
func (pr *PendingRequest) ClaimFirstContentExplorationOutcome() bool {
	return pr.FirstContentExplored() && !pr.firstContentExplorationOutcomeRecorded.Swap(true)
}
