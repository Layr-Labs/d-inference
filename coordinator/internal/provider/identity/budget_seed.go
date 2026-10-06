package identity

import "github.com/eigeninference/d-inference/coordinator/store"

// SeedPushBudgets restores durable admission windows and rotation-clear history.
func (t *Throttle) SeedPushBudgets(generation uint64, budgets []store.CodeAttestPushBudget) {
	t.mu.Lock()
	defer t.mu.Unlock()
	for _, budget := range budgets {
		if budget.SEPubKey == "" || !t.publicationCurrentLocked(budget.SEPubKey, generation) {
			continue
		}
		if budget.TokenHash == "" {
			if budget.LastClearAt.After(t.lastBudgetClear[budget.SEPubKey]) {
				t.lastBudgetClear[budget.SEPubKey] = budget.LastClearAt
			}
			if budget.NextPushAt.After(t.Now()) && budget.NextPushAt.After(t.novelPushFloor[budget.SEPubKey]) {
				t.novelPushFloor[budget.SEPubKey] = budget.NextPushAt
			}
			continue
		}
		if !budget.NextPushAt.After(t.Now()) {
			continue
		}
		key := CodeAttestPushBudgetKey(budget.SEPubKey, budget.TokenHash)
		t.durableNextPush[key] = budget.NextPushAt
		t.noteBudgetTokenReservationHeld(budget.SEPubKey, budget.TokenHash)
	}
}
