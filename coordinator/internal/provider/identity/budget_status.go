package identity

import "time"

// BudgetStatus describes the token window used to diagnose a denied reservation.
type BudgetStatus struct {
	LastPushAt time.Time
	NextPushAt time.Time
	Present    bool
}

func (t *Throttle) BudgetStatus(seKey, token string) BudgetStatus {
	t.mu.Lock()
	defer t.mu.Unlock()
	key := CodeAttestPushBudgetKey(seKey, CodeAttestTokenHash(token))
	last, local := t.lastPush[key]
	next, durable := t.durableNextPush[key]
	return BudgetStatus{LastPushAt: last, NextPushAt: next, Present: local || durable}
}
