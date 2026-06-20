package baserewards

import "sort"

// alloc.go holds the pure pool allocation (design §7): when eligible floors
// exceed the budget, fund the 48–96GB workhorse tier first (a reserved sub-pool
// + value-per-floor-dollar ranking) rather than biggest-machine-first, so idle
// 512GB boxes cannot consume the whole pool and starve the workhorse tier the
// marketing is written for. A per-account concentration cap (bound to the
// Stripe payout identity — design §6) limits any single account's share.

// FloorPoolBudgetMicroUSD is the default monthly hard cap on Σ base_draw. Each
// 5-minute settlement period receives a prorated share of this pool.
const FloorPoolBudgetMicroUSD int64 = 9_000_000_000 // $9,000/mo

// Workhorse tier bounds (inclusive) — the 48–96GB class protected by the
// reserved sub-pool (design §7).
const (
	workhorseMinGB = 48
	workhorseMaxGB = 96
)

// Candidate is one machine's desired draw plus the inputs the allocator needs to
// rank and cap it.
type Candidate struct {
	ProviderKey string
	AccountID   string // for the per-account concentration cap (Stripe identity)
	MemGB       int
	Earned      int64
	Floor       int64 // scaled floor
	Draw        int64 // desired base reward = max(0, Floor - k*Earned); default k=0 ⇒ full Floor
}

// Allocation is the granted draw for one machine, never exceeding its desired
// Candidate.Draw.
type Allocation struct {
	ProviderKey string
	AccountID   string
	Granted     int64 // <= Candidate.Draw
}

// isWorkhorse reports whether a candidate is in the protected 48–96GB tier.
func isWorkhorse(c Candidate) bool {
	return c.MemGB >= workhorseMinGB && c.MemGB <= workhorseMaxGB
}

// valuePerFloorDollar ranks candidates when the pool can't fund every base
// reward: higher is funded first. Under additive base income the full prorated floor is
// always desired, so this only rations a constrained pool — lower earned-vs-floor
// coverage ranks higher (direct the scarce subsidy to machines not yet earning
// much, the supply the base reward is meant to retain), and workhorse-class
// machines are boosted above the rest so biggest idle machines wait behind them.
// Returns a score in roughly [0, 2].
func valuePerFloorDollar(c Candidate) float64 {
	if c.Floor <= 0 {
		return 0
	}
	coverage := float64(c.Earned) / float64(c.Floor)
	if coverage > 1 {
		coverage = 1
	}
	score := 1 - coverage // 1.0 fully idle, 0.0 fully self-funding
	if isWorkhorse(c) {
		score += 1.0 // workhorse boost — never starved by big idle boxes
	}
	return score
}

// AllocateDraws caps Σ Granted <= budget. Protection order (design §7):
//  1. The workhorse tier (48<=MemGB<=96) is funded first from a reserved
//     sub-pool (workhorseReserveFrac of budget), ranked by
//     value-per-floor-dollar.
//  2. The remaining budget (reserve leftovers + the rest) water-fills every
//     still-unfunded candidate by the same ranking.
//  3. An optional per-account cap (perAccountCapFrac of capBudget; 0 disables)
//     bounds each AccountID's total grant. The cap is keyed on the FULL pool
//     (capBudget), and priorByAccount seeds each account's already-settled total
//     for this period, so the cap holds ACROSS idempotent re-settlement runs (a
//     new machine from an account near its cap cannot win a fresh full cap).
//
// `budget` is what may be granted this run (the period pool minus amounts
// already settled for this epoch_id); `capBudget` is the full period pool used
// only as the per-account cap basis. Pass capBudget == budget and priorByAccount
// == nil for a single-shot allocation.
//
// Deterministic for any input: candidates are stable-sorted with ProviderKey as
// the final tiebreaker, so map iteration order in the caller never changes the
// result. Returns one Allocation per input candidate (Granted may be 0 —
// waitlisted).
func AllocateDraws(cands []Candidate, budget, capBudget int64, workhorseReserveFrac, perAccountCapFrac float64, priorByAccount map[string]int64) []Allocation {
	out := make([]Allocation, len(cands))
	idx := make(map[string]int, len(cands)) // providerKey -> out index
	order := make([]int, len(cands))
	for i := range cands {
		out[i] = Allocation{ProviderKey: cands[i].ProviderKey, AccountID: cands[i].AccountID, Granted: 0}
		idx[cands[i].ProviderKey] = i
		order[i] = i
	}
	if budget <= 0 || len(cands) == 0 {
		return out
	}

	// Rank by value-per-floor-dollar desc; ProviderKey asc as the deterministic
	// final tiebreaker (map-order independent).
	sort.SliceStable(order, func(a, b int) bool {
		ca, cb := cands[order[a]], cands[order[b]]
		va, vb := valuePerFloorDollar(ca), valuePerFloorDollar(cb)
		if va != vb {
			return va > vb
		}
		return ca.ProviderKey < cb.ProviderKey
	})

	var perAccountCap int64
	if perAccountCapFrac > 0 {
		perAccountCap = int64(float64(capBudget) * perAccountCapFrac)
	}
	// Seed each account's running total with what it was already granted this
	// epoch so the cap is cumulative across re-settlement runs. These prior
	// amounts are NOT part of remaining (they were spent on earlier runs).
	accountGranted := make(map[string]int64, len(priorByAccount))
	for acct, amt := range priorByAccount {
		accountGranted[acct] = amt
	}

	remaining := budget
	// grant tops up one candidate, honoring the remaining budget and per-account
	// cap. Returns the amount actually granted (cumulative grants are tracked in
	// out/accountGranted/remaining).
	grant := func(c Candidate, cap int64) {
		i := idx[c.ProviderKey]
		want := c.Draw - out[i].Granted
		if want > cap {
			want = cap
		}
		if want > remaining {
			want = remaining
		}
		if perAccountCap > 0 {
			headroom := perAccountCap - accountGranted[c.AccountID]
			if want > headroom {
				want = headroom
			}
		}
		if want <= 0 {
			return
		}
		out[i].Granted += want
		accountGranted[c.AccountID] += want
		remaining -= want
	}

	// Step 1: fund the workhorse tier from the reserved sub-pool.
	if workhorseReserveFrac > 0 {
		reserve := int64(float64(budget) * workhorseReserveFrac)
		for _, o := range order {
			if remaining <= 0 || reserve <= 0 {
				break
			}
			c := cands[o]
			if !isWorkhorse(c) {
				continue
			}
			before := remaining
			grant(c, reserve)
			spent := before - remaining
			reserve -= spent
		}
	}

	// Step 2: water-fill the rest (and any unfunded workhorses) from whatever
	// budget remains.
	for _, o := range order {
		if remaining <= 0 {
			break
		}
		grant(cands[o], remaining)
	}

	return out
}
