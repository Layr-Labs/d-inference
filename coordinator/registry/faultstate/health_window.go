package faultstate

import (
	"time"
)

// providerHealthOutcome is one recorded terminal: ok=false is a FAULT, ok=true
// is a SUCCESS. Capacity/client sheds are never recorded.
type providerHealthOutcome struct {
	ts time.Time
	ok bool
	// flush marks a disconnect-flush (502) fault so a version-changed
	// reconnect can drop exactly those entries (version_reset.go).
	flush bool
}

// recordFault appends one FAULT outcome, tagging it as a disconnect flush
// when it came from the registry's pending-request flush (status 502).
func (w *providerHealthWindow) recordFault(now time.Time, flush bool) {
	w.recordOutcome(providerHealthOutcome{ts: now, flush: flush})
}

// providerHealthWindow is a fixed-size ring of the most recent
// providerHealthRingSize outcomes for one provider, plus the running count of
// CONSECUTIVE faults (reset by any success). The ring backs the windowed
// fail-rate trip condition; consecFail backs the consecutive-fault condition.
type providerHealthWindow struct {
	outcomes   [providerHealthRingSize]providerHealthOutcome
	size       int // number of valid entries (saturates at providerHealthRingSize)
	head       int // index of the next write
	consecFail int // consecutive faults; reset to 0 on any success
}

// record appends one outcome to the ring and updates the consecutive-fault
// counter. Only faults and successes are recorded (callers filter healthy sheds
// out first).
func (w *providerHealthWindow) record(ok bool, now time.Time) {
	w.recordOutcome(providerHealthOutcome{ts: now, ok: ok})
}

func (w *providerHealthWindow) recordOutcome(outcome providerHealthOutcome) {
	w.outcomes[w.head] = outcome
	w.head = (w.head + 1) % providerHealthRingSize
	if w.size < providerHealthRingSize {
		w.size++
	}
	if outcome.ok {
		w.consecFail = 0
	} else {
		w.consecFail++
	}
}

// rebuild replaces the ring with an already bounded chronological history,
// retaining flush provenance and deriving the trailing fault streak anew.
func (w *providerHealthWindow) rebuild(outcomes []providerHealthOutcome) {
	*w = providerHealthWindow{}
	for _, outcome := range outcomes {
		w.recordOutcome(outcome)
	}
}

// chronological returns the ring's valid outcomes ordered oldest → newest.
func (w *providerHealthWindow) chronological() []providerHealthOutcome {
	out := make([]providerHealthOutcome, 0, w.size)
	start := (w.head + providerHealthRingSize - w.size) % providerHealthRingSize
	for i := 0; i < w.size; i++ {
		out = append(out, w.outcomes[(start+i)%providerHealthRingSize])
	}
	return out
}

// merge folds src's outcomes into w for an identity rebind whose new key
// ALREADY has history (e.g. this session's sekey:-keyed faults migrating onto
// a serial: window populated by a previous connection). Both rings are merged
// in timestamp order (stable two-pointer merge: w's entry wins ties), the most
// recent providerHealthRingSize entries are kept, and consecFail is recomputed
// as the merged tail's trailing fault run — keeping only the destination ring
// (the pre-merge behavior) dropped the in-progress consecutive-fault streak,
// so a flapping provider whose identity enriched mid-streak evaded the
// breaker. O(providerHealthRingSize).
func (w *providerHealthWindow) merge(src *providerHealthWindow) {
	if src == nil || src.size == 0 {
		return
	}
	if w.size == 0 {
		*w = *src
		return
	}
	a, b := w.chronological(), src.chronological()
	merged := make([]providerHealthOutcome, 0, len(a)+len(b))
	i, j := 0, 0
	for i < len(a) && j < len(b) {
		if !a[i].ts.After(b[j].ts) {
			merged = append(merged, a[i])
			i++
		} else {
			merged = append(merged, b[j])
			j++
		}
	}
	merged = append(merged, a[i:]...)
	merged = append(merged, b[j:]...)
	if len(merged) > providerHealthRingSize {
		merged = merged[len(merged)-providerHealthRingSize:]
	}
	w.rebuild(merged)
}

// windowStats returns the number of outcomes recorded within [now-window, now]
// and how many of those were faults.
func (w *providerHealthWindow) windowStats(now time.Time, window time.Duration) (total, fails int) {
	cutoff := now.Add(-window)
	for i := 0; i < w.size; i++ {
		o := w.outcomes[i]
		if o.ts.Before(cutoff) {
			continue
		}
		total++
		if !o.ok {
			fails++
		}
	}
	return total, fails
}
