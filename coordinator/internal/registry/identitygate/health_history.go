package identitygate

import (
	"time"
)

// HealthRingSize bounds retained terminal outcomes per identity.
const HealthRingSize = 20

// BreakerWindow is the observation horizon for node-health fault rates.
const BreakerWindow = 120 * time.Second

// FaultStreak is the current consecutive-fault evidence for quarantine policy.
func (w *HealthHistory) FaultStreak() int { return w.consecFail }

// DropDisconnectFlush removes only coordinator disconnect-flush faults, preserving
// ordinary failure provenance and recomputing the trailing fault streak.
func (w *HealthHistory) DropDisconnectFlush() (dropped bool) {
	entries := w.Chronological()
	kept := entries[:0]
	for _, o := range entries {
		if o.DisconnectFlush {
			dropped = true
			continue
		}
		kept = append(kept, o)
	}
	if !dropped {
		return false
	}
	w.rebuild(kept)
	return true
}

// HealthOutcome is one recorded terminal: Success=false is a FAULT, Success=true
// is a SUCCESS. Capacity/client sheds are never recorded.
type HealthOutcome struct {
	At      time.Time
	Success bool
	// DisconnectFlush marks a disconnect-flush (502) fault so a version-changed
	// reconnect can drop exactly those entries (version_reset.go).
	DisconnectFlush bool
}

// RecordFault appends one FAULT outcome, tagging it as a disconnect flush
// when it came from the registry's pending-request flush (status 502).
func (w *HealthHistory) RecordFault(now time.Time, flush bool) {
	w.recordOutcome(HealthOutcome{At: now, DisconnectFlush: flush})
}

// HealthHistory is a fixed-size ring of the most recent
// HealthRingSize outcomes for one provider, plus the running count of
// CONSECUTIVE faults (reset by any success). The ring backs the windowed
// fail-rate trip condition; consecFail backs the consecutive-fault condition.
// Its owning identity gate serializes all operations, including reads and merges.
type HealthHistory struct {
	outcomes   [HealthRingSize]HealthOutcome
	size       int // number of valid entries (saturates at HealthRingSize)
	head       int // index of the next write
	consecFail int // consecutive faults; reset to 0 on any success
}

// Record appends one outcome to the ring and updates the consecutive-fault
// counter. Only faults and successes are recorded (callers filter healthy sheds
// out first).
func (w *HealthHistory) Record(success bool, now time.Time) {
	w.recordOutcome(HealthOutcome{At: now, Success: success})
}

func (w *HealthHistory) recordOutcome(outcome HealthOutcome) {
	w.outcomes[w.head] = outcome
	w.head = (w.head + 1) % HealthRingSize
	if w.size < HealthRingSize {
		w.size++
	}
	if outcome.Success {
		w.consecFail = 0
	} else {
		w.consecFail++
	}
}

// rebuild replaces the ring with an already bounded chronological history,
// retaining flush provenance and deriving the trailing fault streak anew.
func (w *HealthHistory) rebuild(outcomes []HealthOutcome) {
	*w = HealthHistory{}
	for _, outcome := range outcomes {
		w.recordOutcome(outcome)
	}
}

// Chronological returns an owned copy of valid outcomes ordered oldest to newest.
func (w *HealthHistory) Chronological() []HealthOutcome {
	out := make([]HealthOutcome, 0, w.size)
	start := (w.head + HealthRingSize - w.size) % HealthRingSize
	for i := 0; i < w.size; i++ {
		out = append(out, w.outcomes[(start+i)%HealthRingSize])
	}
	return out
}

// Merge folds src's outcomes into w for an identity rebind whose new key
// ALREADY has history (e.g. this session's sekey:-keyed faults migrating onto
// a serial: window populated by a previous connection). Both rings are merged
// in timestamp order (stable two-pointer merge: w's entry wins ties), the most
// recent HealthRingSize entries are kept, and consecFail is recomputed
// as the merged tail's trailing fault run — keeping only the destination ring
// (the pre-merge behavior) dropped the in-progress consecutive-fault streak,
// so a flapping provider whose identity enriched mid-streak evaded the
// breaker. O(HealthRingSize).
func (w *HealthHistory) Merge(src *HealthHistory) {
	if src == nil || src.size == 0 {
		return
	}
	if w.size == 0 {
		*w = *src
		return
	}
	a, b := w.Chronological(), src.Chronological()
	merged := make([]HealthOutcome, 0, len(a)+len(b))
	i, j := 0, 0
	for i < len(a) && j < len(b) {
		if !a[i].At.After(b[j].At) {
			merged = append(merged, a[i])
			i++
		} else {
			merged = append(merged, b[j])
			j++
		}
	}
	merged = append(merged, a[i:]...)
	merged = append(merged, b[j:]...)
	if len(merged) > HealthRingSize {
		merged = merged[len(merged)-HealthRingSize:]
	}
	w.rebuild(merged)
}

// WindowStats returns the number of outcomes recorded within [now-window, now]
// and how many of those were faults.
func (w *HealthHistory) WindowStats(now time.Time, window time.Duration) (total, fails int) {
	cutoff := now.Add(-window)
	for i := 0; i < w.size; i++ {
		o := w.outcomes[i]
		if o.At.Before(cutoff) {
			continue
		}
		total++
		if !o.Success {
			fails++
		}
	}
	return total, fails
}
