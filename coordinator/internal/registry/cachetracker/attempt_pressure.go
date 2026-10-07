package cachetracker

import "time"

// Terminal grace is optional late-receipt evidence, never live request
// authority. Byte pressure examines at most graceReclaimScan terminal records
// per admission, keeps the byte limit, and refuses when live records or the
// work bound prevent a fit. No tenant or prompt labels are recorded.
const graceReclaimScan = 64

// AttemptLifecycle is the attempt ledger's aggregate state for a status
// scrape. The counters are monotonic within one tracker generation.
type AttemptLifecycle struct {
	Bytes, BudgetRefused, GraceReclaimed uint64
}

func (t *Tracker[P]) AttemptLifecycle() AttemptLifecycle {
	return AttemptLifecycle{Bytes: t.attemptBudget.Bytes(),
		BudgetRefused: t.attemptBudgetRefused, GraceReclaimed: t.attemptGraceReclaimed}
}

// reclaimTerminalGraceLocked makes room for a validated, detached candidate
// whose replacement total exceeds the limit. It removes terminal records only
// when their complete refund admits the candidate, and returns the total after
// those removals. Only a record still inside its grace at now counts as a
// grace reclaim; one whose grace already ended is an expiry the sweep has not
// reached yet.
func (t *Tracker[P]) reclaimTerminalGraceLocked(now time.Time, exclude string, total uint64) (uint64, bool) {
	victims := t.terminalBudgetVictimsLocked(exclude, total-t.attemptBudget.MaxBytes())
	if victims == nil {
		return total, false
	}
	for _, victim := range victims {
		attempt := t.attempts.Lookup(victim)
		total -= attempt.AccountedBytes
		t.RemoveAttemptLocked(victim)
		if now.Before(attempt.ExpiresAt) && t.attemptGraceReclaimed != ^uint64(0) {
			t.attemptGraceReclaimed++
		}
	}
	return total, true
}

// terminalBudgetVictimsLocked peeks, without mutating anything, the
// earliest-expiring terminal records whose stored charges free need bytes.
// exclude, the nonce being replaced, is never chosen. It returns nil when the
// bounded scan cannot free need bytes or meets a record it cannot refund.
func (t *Tracker[P]) terminalBudgetVictimsLocked(exclude string, need uint64) []string {
	if t.terminalOrder.Len() == 0 {
		return nil
	}
	victims := make([]string, 0, graceReclaimScan)
	var refunded uint64
	for entry := range t.terminalOrder.Earliest(graceReclaimScan) {
		nonce := entry.Key().Nonce
		if nonce == exclude {
			continue
		}
		attempt, ok := t.attempts.Load(nonce)
		if !ok || !attempt.Terminal || attempt.AccountedBytes == 0 ||
			attempt.AccountedBytes > t.attemptBudget.Bytes()-refunded {
			return nil
		}
		victims = append(victims, nonce)
		refunded += attempt.AccountedBytes
		if refunded >= need {
			return victims
		}
	}
	return nil
}

func (t *Tracker[P]) noteAttemptBudgetRefusalLocked() {
	if t.attemptBudgetRefused != ^uint64(0) {
		t.attemptBudgetRefused++
	}
}
