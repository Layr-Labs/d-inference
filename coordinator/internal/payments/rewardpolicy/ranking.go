package rewardpolicy

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

// isWorkhorse reports whether a candidate is in the protected 48–96GB tier.
func IsWorkhorse(c Candidate) bool {
	return c.MemGB >= workhorseMinGB && c.MemGB <= workhorseMaxGB
}

// valuePerFloorDollar ranks candidates when the pool can't fund every base
// reward: higher is funded first. Under additive base income the full prorated floor is
// always desired, so this only rations a constrained pool — lower earned-vs-floor
// coverage ranks higher (direct the scarce subsidy to machines not yet earning
// much, the supply the base reward is meant to retain), and workhorse-class
// machines are boosted above the rest so biggest idle machines wait behind them.
// Returns a score in roughly [0, 2].
func ValuePerFloorDollar(c Candidate) float64 {
	if c.Floor <= 0 {
		return 0
	}
	coverage := float64(c.Earned) / float64(c.Floor)
	if coverage > 1 {
		coverage = 1
	}
	score := 1 - coverage // 1.0 fully idle, 0.0 fully self-funding
	if IsWorkhorse(c) {
		score += 1.0 // workhorse boost — never starved by big idle boxes
	}
	return score
}
