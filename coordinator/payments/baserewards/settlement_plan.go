package baserewards

import (
	"context"
	"errors"
	"time"

	rewardpolicy "github.com/eigeninference/d-inference/coordinator/internal/payments/rewardpolicy"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// settleCandidatePlan runs under the epoch lock. A remaining allocation is one
// atomic batch, including partial and zero waitlisted rows. On a late rejection
// nothing from that plan is frozen: reread actual spending and verified aliases,
// refresh consent or remove the rejected session, and allocate again.
func (e *Engine) settleCandidatePlan(ctx context.Context, epoch string, start, end time.Time, candidates []candidate, result *SettleResult) error {
	batchStore, ok := store.As[store.FloorDrawBatchStore](e.store)
	if !ok {
		return errors.New("base rewards: atomic floor settlement store unavailable")
	}
	initial := make(map[string]bool)
	for _, c := range candidates {
		for _, p := range c.live {
			initial[p.ID] = true
		}
	}
	blocked := make(map[string]bool)
	counted := make(map[string]bool)
	verifiedBindings := make(map[string]store.MachineRewardBinding)
	periodBudget := rewardpolicy.PeriodBudget(e.cfg.PoolBudgetMicroUSD, start, end)
	// Retries can join aliases, exclude failed sessions, or refresh changed
	// consent. Keep the attempt bound for unstable consent; no retry admits a
	// session that was absent from the original plan.
	for attempt := 0; attempt <= 2*len(initial); attempt++ {
		if err := ctx.Err(); err != nil {
			return err
		}
		if attempt > 0 {
			var err error
			candidates, err = e.buildCandidatesWithBindings(ctx, start, end, verifiedBindings)
			if err != nil {
				return err
			}
		}
		settled, err := e.store.ListFloorDrawsForEpoch(ctx, epoch)
		if err != nil {
			return err
		}
		settledKeys := make(map[string]bool, len(settled))
		priorByAccount := make(map[string]int64)
		var spent int64
		for _, d := range settled {
			settledKeys[d.ProviderKey] = true
			priorByAccount[d.AccountID] += d.AmountMicroUSD
			spent += d.AmountMicroUSD
		}
		pending := make([]candidate, 0, len(candidates))
		sessions := make([]registry.ProviderSnapshot, 0, len(candidates))
		pure := make([]rewardpolicy.Candidate, 0, len(candidates))
		for _, c := range candidates {
			c.live = remainingRewardSessions(c.live, initial, blocked)
			if len(c.live) == 0 {
				continue
			}
			if candidatePreviouslySettled(c, settledKeys) {
				if !counted[c.c.ProviderKey] {
					result.AlreadySettled++
					counted[c.c.ProviderKey] = true
				}
				continue
			}
			session, eligible := e.eligibleCandidateSession(c)
			if !eligible {
				continue
			}
			pending = append(pending, c)
			sessions = append(sessions, session)
			pure = append(pure, c.c)
		}
		if len(pending) == 0 {
			return nil
		}
		allocations := AllocateDraws(pure, max(int64(0), periodBudget-spent), periodBudget, e.cfg.WorkhorseReserveFrac, e.cfg.PerAccountCapFrac, priorByAccount)
		items := make([]store.FloorDrawBatchItem, len(allocations))
		for i, allocation := range allocations {
			c := pending[i]
			items[i] = store.FloorDrawBatchItem{SessionID: sessions[i].ID, MachineID: c.machineID, Draw: store.ProviderFloorDraw{
				ProviderKey: allocation.ProviderKey, AccountID: allocation.AccountID, EpochID: epoch,
				AmountMicroUSD: allocation.Granted, FloorMicroUSD: c.c.Floor, EarnedMicroUSD: c.c.Earned,
				UptimeFrac: c.uptimeFrac, MemoryGB: c.c.MemGB,
			}}
			if sessions[i].AutopilotOptedIn {
				items[i].Draw.AutopilotBonusMicroUSD = allocation.Granted / 10
			}
		}
		batch, err := batchStore.SettleProviderFloorDrawBatch(ctx, items, func(i int) bool {
			current, eligible := e.candidateSessionSnapshot(pending[i], sessions[i].ID)
			return eligible && current.AutopilotOptedIn == sessions[i].AutopilotOptedIn
		})
		if err != nil {
			return err
		}
		if batch.Committed {
			result.Settled += len(items)
			for _, item := range items {
				result.TotalDrawMicroUSD += item.Draw.AmountMicroUSD + item.Draw.AutopilotBonusMicroUSD
				result.TotalAutopilotBonusMicroUSD += item.Draw.AutopilotBonusMicroUSD
			}
			return nil
		}
		if len(batch.Rejections) == 0 {
			return errors.New("base rewards: batch did not commit or reject a candidate")
		}
		for _, rejection := range batch.Rejections {
			if rejection.Index < 0 || rejection.Index >= len(items) {
				return errors.New("base rewards: invalid batch rejection")
			}
			if rejection.Reason == store.FloorDrawDuplicate {
				if rejection.DuplicateOf < 0 || rejection.DuplicateOf >= len(items) || rejection.DuplicateOf == rejection.Index || rejection.CanonicalMachineID == "" {
					return errors.New("base rewards: invalid duplicate identity")
				}
				for _, i := range []int{rejection.Index, rejection.DuplicateOf} {
					verifiedBindings[sessions[i].ID] = store.MachineRewardBinding{MachineID: rejection.CanonicalMachineID, AccountID: items[i].Draw.AccountID, MachineAliases: []string{rejection.CanonicalMachineID}}
				}
				continue
			}
			// Consent can change without losing ordinary reward eligibility.
			// Rebuild that plan instead of dropping the machine's base grant.
			if rejection.Reason == store.FloorDrawUnauthorized && e.candidateSessionAuthorized(pending[rejection.Index], sessions[rejection.Index].ID) {
				continue
			}
			blocked[sessions[rejection.Index].ID] = true
			key := pending[rejection.Index].c.ProviderKey
			if rejection.Reason == store.FloorDrawAlreadyPaid && !counted[key] {
				result.AlreadySettled++
				counted[key] = true
			}
		}
	}
	return errors.New("base rewards: authorization changed throughout settlement")
}

func remainingRewardSessions(live []registry.ProviderSnapshot, initial, blocked map[string]bool) []registry.ProviderSnapshot {
	remaining := make([]registry.ProviderSnapshot, 0, len(live))
	for _, p := range live {
		if initial[p.ID] && !blocked[p.ID] {
			remaining = append(remaining, p)
		}
	}
	return remaining
}
