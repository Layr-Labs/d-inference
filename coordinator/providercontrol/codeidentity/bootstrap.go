package codeidentity

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// Seed wires the store into the code-identity reuse cache and
// seeds it from persisted records at startup (W5 Fix 2). This is what makes the
// reuse cache survive a coordinator restart / blue-green deploy, so a fresh
// instance does not re-push the entire fleet (against Apple's ~3/hour/device push
// budget). Safe to call once during server setup, AFTER the store is set and the
// attestor is wired; a nil store or nil throttle is a no-op. SECURITY: seeding
// only repopulates the cache that reuseAttestation re-validates (same version,
// freshness, token, and exact process key) on every read. A stale, mismatched,
// or legacy process-key-less row still falls through to a real challenge.
func (s *Manager) Seed(ctx context.Context, st Store) {
	if s == nil || s.state == nil || st == nil {
		return
	}
	// Wire the write-through path so future successful round-trips are persisted.
	s.state.store = st

	rows, err := st.ListCodeAttestations(ctx)
	if err != nil {
		s.deps.Logger.Warn("code-attest: failed to seed reuse cache from store", "error", err)
	} else if n := s.state.seed(rows); n > 0 {
		s.deps.Logger.Info("code-attest: seeded reuse cache from persisted records (survives deploys)", "records", n)
	}
	if st, ok := store.As[pushBudgetStore](st); ok {
		budgets, err := st.ListCodeAttestPushBudgets(ctx)
		if err != nil {
			s.deps.Logger.Warn("code-attest: failed to seed durable push budgets", "error", err)
		} else {
			th := s.state
			th.mu.Lock()
			for _, budget := range budgets {
				if budget.SEPubKey == "" {
					continue
				}
				if budget.TokenHash == "" {
					// Sentinel row: the per-SE-key novel-token admission floor
					// (also the shape of legacy pre-composite rows, whose
					// per-SE budget means exactly this). Codex P1. Its
					// LastClearAt seeds the rotation-clear cooldown, so a
					// restart cannot re-grant a floor clear the previous
					// instance already spent (Codex 06:36Z P1) — even when the
					// floor itself has already elapsed.
					if budget.LastClearAt.After(th.lastBudgetClear[budget.SEPubKey]) {
						th.lastBudgetClear[budget.SEPubKey] = budget.LastClearAt
					}
					if budget.NextPushAt.After(th.now()) &&
						budget.NextPushAt.After(th.novelPushFloor[budget.SEPubKey]) {
						th.novelPushFloor[budget.SEPubKey] = budget.NextPushAt
					}
					continue
				}
				if !budget.NextPushAt.After(th.now()) {
					continue
				}
				key := codeAttestPushBudgetKey(
					budget.SEPubKey, budget.TokenHash,
				)
				th.durableNextPush[key] = budget.NextPushAt
				th.noteBudgetTokenReservationHeld(
					budget.SEPubKey, budget.TokenHash,
				)
			}
			th.mu.Unlock()
		}
	}
}
