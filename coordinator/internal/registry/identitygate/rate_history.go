package identitygate

import "time"

// RateHistory owns each model's chronological capacity outcomes. Its caller
// serializes access with the identity gate lock.
type RateHistory struct {
	rejects map[string][]time.Time
	accepts map[string][]time.Time
}

func NewRateHistory() RateHistory {
	return RateHistory{
		rejects: make(map[string][]time.Time),
		accepts: make(map[string][]time.Time),
	}
}

// RecordReject also drops expired accept-only history before computing the
// first rejection rate after a quiet interval.
func (h *RateHistory) RecordReject(model string, now time.Time) {
	h.rejects[model] = appendWindowedOutcome(h.rejects[model], now)
	if accepts, ok := h.accepts[model]; ok {
		accepts = pruneWindowedOutcomes(accepts, now)
		if len(accepts) == 0 {
			delete(h.accepts, model)
		} else {
			h.accepts[model] = accepts
		}
	}
}

// RecordAccept retains served dispatches even when no reject is in-window.
func (h *RateHistory) RecordAccept(model string, now time.Time) {
	h.accepts[model] = appendWindowedOutcome(h.accepts[model], now)
}

// Merge preserves equal timestamp multiplicity and chronological ordering.
// As with identity migration, the source must not be mutated after transfer.
func (h *RateHistory) Merge(src *RateHistory) {
	for model, outcomes := range src.rejects {
		h.rejects[model] = MergeChronologicalTimestamps(h.rejects[model], outcomes)
	}
	for model, outcomes := range src.accepts {
		h.accepts[model] = MergeChronologicalTimestamps(h.accepts[model], outcomes)
	}
}

// Prune removes fully aged model histories, retaining the original prefix of
// any history that still has a live outcome for subsequent ordered migration.
func (h *RateHistory) Prune(now time.Time) {
	for model, outcomes := range h.rejects {
		if len(outcomes) == 0 || now.Sub(outcomes[len(outcomes)-1]) >= capacityRateWindow {
			delete(h.rejects, model)
		}
	}
	for model, outcomes := range h.accepts {
		if len(outcomes) == 0 || now.Sub(outcomes[len(outcomes)-1]) >= capacityRateWindow {
			delete(h.accepts, model)
		}
	}
}

func (h *RateHistory) empty() bool {
	return len(h.rejects)+len(h.accepts) == 0
}

func (h *RateHistory) newestRejectNS() int64 {
	var newest int64
	for _, rejects := range h.rejects {
		if n := len(rejects); n > 0 {
			if ns := rejects[n-1].UnixNano(); ns > newest {
				newest = ns
			}
		}
	}
	return newest
}

// Counts reads the strict window without discarding dormant accept evidence.
func (h *RateHistory) Counts(model string, now time.Time) (rejects, accepts int) {
	return countInWindow(h.rejects[model], now), countInWindow(h.accepts[model], now)
}

func (h *RateHistory) Assess(model string, now time.Time) RateAssessment {
	rejects, accepts := h.Counts(model, now)
	return RateAssessment{Rejects: rejects, Accepts: accepts}
}

// Chronological returns owned evidence of the two independently aged histories.
func (h *RateHistory) Chronological(model string) (rejects, accepts []time.Time) {
	return append([]time.Time(nil), h.rejects[model]...), append([]time.Time(nil), h.accepts[model]...)
}
