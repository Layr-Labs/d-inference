package baserewards

import (
	"context"
	"log/slog"
	"time"

	"github.com/eigeninference/d-inference/coordinator/mdm"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// engine.go is the only file in this package that touches the store or registry.
// It builds per-machine settlement candidates from durable store state (the
// money source of truth) plus the live registry (trust/health/hardware), runs
// the pure floor/alloc math, and settles each machine's draw via an
// idempotent store write (design §8).

// settlementGrace is the window an open session keeps accruing uptime past its
// last heartbeat (design §8: open sessions accrue to min(epoch_end, last_seen+90s)).
const defaultGraceSeconds = 90

// Config holds the engine's policy knobs. Defaults come from DefaultConfig;
// deployment overrides are applied by the caller (server_config → main).
type Config struct {
	Enabled              bool
	ReductionK           float64 // default 0 (additive base income); k=1 = legacy max(earned,floor) backstop
	PoolBudgetMicroUSD   int64   // default FloorPoolBudgetMicroUSD ($9k/mo)
	WorkhorseReserveFrac float64 // default 0.5 — sub-pool reserved for 48–96GB
	// PerAccountCapFrac caps any single payout account's share of the pool.
	// DEFAULT 0 (DISABLED): base rewards are per-MACHINE, not per-account — an
	// operator running N real, attested, serving Macs contributes N machines of
	// capacity and should earn N floors. Attestation prevents fake machines and
	// the pool is already bounded, so a per-account cap only penalizes honest
	// multi-machine operators (the supply we most want). Left as an optional knob
	// in case a concentration limit is ever needed.
	PerAccountCapFrac float64
	MinUptimeFrac     float64       // 0.90 — hard eligibility gate (design §6 gate 3)
	GraceSeconds      int           // 90 — open-session uptime grace (design §8)
	WorkWindow        time.Duration // rolling window for the proven-work gate (gate 5)
}

// DefaultConfig returns the recommended launch configuration: k=0 additive base
// income (the full floor is paid on top of organic earnings), $9k pool, half
// reserved for the workhorse tier, NO per-account cap (per-machine payout), and
// 90% uptime gate.
func DefaultConfig() Config {
	return Config{
		Enabled:              false,
		ReductionK:           DefaultReductionK,
		PoolBudgetMicroUSD:   FloorPoolBudgetMicroUSD,
		WorkhorseReserveFrac: 0.5,
		PerAccountCapFrac:    0, // disabled — per-machine, not per-account (see Config)
		MinUptimeFrac:        MinUptimeForAvail,
		GraceSeconds:         defaultGraceSeconds,
		WorkWindow:           45 * 24 * time.Hour, // rolling ~45d proven-work window
	}
}

// Engine settles the base-reward floor for closed monthly epochs.
type Engine struct {
	store  store.Store
	reg    *registry.Registry
	cfg    Config
	logger *slog.Logger
	now    func() time.Time // injectable clock for tests
}

// NewEngine constructs an Engine. The store is the durable money source of
// truth; the registry supplies live trust/health/hardware at settlement time.
func NewEngine(s store.Store, reg *registry.Registry, cfg Config, logger *slog.Logger) *Engine {
	if logger == nil {
		logger = slog.Default()
	}
	if cfg.GraceSeconds <= 0 {
		cfg.GraceSeconds = defaultGraceSeconds
	}
	if cfg.WorkWindow <= 0 {
		cfg.WorkWindow = 45 * 24 * time.Hour
	}
	return &Engine{
		store:  s,
		reg:    reg,
		cfg:    cfg,
		logger: logger,
		now:    time.Now,
	}
}

// SettleResult summarizes one SettleEpoch call.
type SettleResult struct {
	EpochID           EpochID
	Eligible          int   // candidates that passed every gate
	Settled           int   // rows newly credited this call
	AlreadySettled    int   // skipped via idempotent (provider_key, epoch_id) conflict
	TotalDrawMicroUSD int64 // Σ newly-printed money this call
}

// candidate pairs an allocation Candidate with the per-machine audit context the
// settlement row records.
type candidate struct {
	c          Candidate
	uptimeFrac float64
}

// SettleEpoch settles the base-reward floor for one closed epoch. It is a no-op
// when the flag is off (design §6) or the epoch is not yet closed, and is
// idempotent — re-running over the same store credits nothing twice (design §8).
func (e *Engine) SettleEpoch(ctx context.Context, epochID EpochID) (SettleResult, error) {
	res := SettleResult{EpochID: epochID}
	if !e.cfg.Enabled {
		return res, nil // flag off — zero behavior change
	}

	start, end, err := epochBounds(epochID)
	if err != nil {
		return res, err
	}
	// Settlement is end-of-epoch only: never settle a month still in progress.
	if e.now().Before(end) {
		return res, nil
	}

	cands, err := e.buildCandidates(ctx, start, end)
	if err != nil {
		return res, err
	}
	res.Eligible = len(cands)
	if len(cands) == 0 {
		return res, nil
	}

	// Serialize settlement of this epoch across coordinator instances: two
	// settlers must not each allocate the full pool and overshoot FLOOR_POOL_B.
	// The memory store runs fn directly; postgres holds an advisory lock.
	lockErr := e.store.WithEpochSettlementLock(ctx, epochID, func() error {
		// Respect the hard pool cap across re-runs of the same closed epoch. A
		// machine settled on an earlier run keeps its frozen row; we subtract
		// those draws from the budget and drop those keys from this run's
		// candidates. Without this, a fleet that changed between two runs of one
		// epoch could settle a second cohort against the full budget and breach
		// FLOOR_POOL_B.
		settled, err := e.store.ListFloorDrawsForEpoch(ctx, epochID)
		if err != nil {
			return err
		}
		settledKeys := make(map[string]bool, len(settled))
		priorByAccount := make(map[string]int64)
		var settledSum int64
		for _, d := range settled {
			settledKeys[d.ProviderKey] = true
			priorByAccount[d.AccountID] += d.AmountMicroUSD
			settledSum += d.AmountMicroUSD
		}

		pureCands := make([]Candidate, 0, len(cands))
		for i := range cands {
			if settledKeys[cands[i].c.ProviderKey] {
				res.AlreadySettled++ // frozen row from a prior run this epoch
				continue
			}
			pureCands = append(pureCands, cands[i].c)
		}
		if len(pureCands) == 0 {
			return nil
		}

		remainingBudget := e.cfg.PoolBudgetMicroUSD - settledSum
		if remainingBudget < 0 {
			remainingBudget = 0
		}
		allocs := AllocateDraws(pureCands, remainingBudget, e.cfg.PoolBudgetMicroUSD, e.cfg.WorkhorseReserveFrac, e.cfg.PerAccountCapFrac, priorByAccount)

		// Index audit context by provider key so we can carry
		// floor/earned/uptime/mem into the settlement row.
		byKey := make(map[string]candidate, len(cands))
		for i := range cands {
			byKey[cands[i].c.ProviderKey] = cands[i]
		}

		for _, a := range allocs {
			cd := byKey[a.ProviderKey]
			draw := &store.ProviderFloorDraw{
				ProviderKey:    a.ProviderKey,
				AccountID:      a.AccountID,
				EpochID:        epochID,
				AmountMicroUSD: a.Granted,
				FloorMicroUSD:  cd.c.Floor,
				EarnedMicroUSD: cd.c.Earned,
				UptimeFrac:     cd.uptimeFrac,
				MemoryGB:       cd.c.MemGB,
			}
			credited, err := e.store.SettleProviderFloorDraw(ctx, draw)
			if err != nil {
				e.logger.Error("base rewards: settle draw failed",
					"epoch", epochID, "provider_key", a.ProviderKey, "error", err)
				continue
			}
			if credited {
				res.Settled++
				res.TotalDrawMicroUSD += a.Granted
			} else {
				res.AlreadySettled++
			}
		}
		return nil
	})
	if lockErr != nil {
		return res, lockErr
	}
	return res, nil
}

// buildCandidates enumerates the live fleet and returns one candidate per
// machine that passes every Phase-0 eligibility gate (design §6): attested +
// trust floor (gate 1), healthy + model loaded (gate 4), uptime ≥ MinUptimeFrac
// (gate 3), and proven work — a billed other-account job in the rolling window
// (gate 5, billed-job half). Memory tier is the self-reported bucket in Phase 0.
func (e *Engine) buildCandidates(ctx context.Context, start, end time.Time) ([]candidate, error) {
	sessions, err := e.store.ListProviderSessionsOverlapping(ctx, start, end)
	if err != nil {
		return nil, err
	}
	uptimeByKey := e.uptimeByProviderKey(sessions, start, end)

	workSince := e.now().Add(-e.cfg.WorkWindow)
	out := make([]candidate, 0)
	for _, p := range e.reg.ListProviders() {
		// Gate 1: attested + trust floor.
		if !p.Attested || !e.reg.TrustMeetsMinimum(p.TrustLevel) {
			continue
		}
		// Gate 4: healthy + advertised model loaded for routing.
		if !p.Online || !p.ModelLoaded {
			continue
		}
		if p.MemoryPressure >= 0.8 || p.ThermalState == "critical" {
			continue
		}
		// Identity: a machine with no stable provider key cannot be credited or
		// matched to earnings/sessions.
		if p.ProviderKey == "" {
			continue
		}

		uptimeFrac := uptimeByKey[p.ProviderKey]
		// Gate 3: hard uptime floor (below this, avail is also 0).
		if uptimeFrac < e.cfg.MinUptimeFrac {
			continue
		}

		// Gate 5: proven willingness-to-serve — a billed, other-account job
		// (self-route produces no earning row, so this is structurally clean)
		// OR a passed coordinator correctness probe (Phase 1) within the window.
		hasWork, err := e.store.HasBilledJobSince(ctx, p.ProviderKey, workSince)
		if err != nil {
			return nil, err
		}
		if !hasWork {
			probed, err := e.store.HasProbeSuccessSince(p.ProviderKey, workSince)
			if err != nil {
				return nil, err
			}
			if !probed {
				continue
			}
		}

		earned, err := e.store.SumProviderEarningsByKey(ctx, p.ProviderKey, start, end)
		if err != nil {
			return nil, err
		}

		// Memory tier: self-reported, but clamped DOWN to the max ever shipped
		// for the SE-signed hardware model so a machine cannot claim a higher
		// tier than its model can physically hold (a self-reported number may
		// only lower the floor, never raise it). Full verification (probe on a
		// tier-sized model) is Phase 1.
		memGB := p.MemoryGB
		if capGB, known := mdm.ModelMaxMemoryGB(p.HardwareModel); known && capGB > 0 && memGB > capGB {
			memGB = capGB
		}
		floor := ScaledFloor(memGB, uptimeFrac)
		draw := Draw(floor, earned, e.cfg.ReductionK)

		out = append(out, candidate{
			c: Candidate{
				ProviderKey: p.ProviderKey,
				AccountID:   "", // resolved below
				MemGB:       memGB,
				Earned:      earned,
				Floor:       floor,
				Draw:        draw,
			},
			uptimeFrac: uptimeFrac,
		})
	}

	// Resolve the payout account from the machine's sessions (the per-account cap
	// and the credit both key on it). Use the most recent session's account. A
	// machine with no linked payout account is dropped — it cannot be credited,
	// and must not consume pool budget or settle a draw to account_id ''.
	accountByKey := latestAccountByProviderKey(sessions)
	eligible := out[:0]
	for i := range out {
		acct := accountByKey[out[i].c.ProviderKey]
		if acct == "" {
			continue
		}
		out[i].c.AccountID = acct
		eligible = append(eligible, out[i])
	}
	return eligible, nil
}

// uptimeByProviderKey unions overlapping session intervals per machine and
// returns the covered fraction of the epoch, capped at 1.0. Open sessions accrue
// only to min(end, last_seen + grace); blue-green deploys leave two open rows
// that union without double-counting (design §8). Sessions with no provider key
// (pre-backfill) are ignored — they cannot be credited.
func (e *Engine) uptimeByProviderKey(sessions []store.ProviderSession, start, end time.Time) map[string]float64 {
	grace := time.Duration(e.cfg.GraceSeconds) * time.Second
	total := epochSeconds(start, end)

	type interval struct{ s, e time.Time }
	byKey := make(map[string][]interval)
	for _, ps := range sessions {
		if ps.ProviderKey == "" {
			continue
		}
		s := ps.ConnectedAt
		if s.Before(start) {
			s = start
		}
		var sessEnd time.Time
		if ps.DisconnectedAt != nil {
			sessEnd = *ps.DisconnectedAt
		} else {
			// Open session: clamp to last_seen + grace.
			sessEnd = ps.LastSeen.Add(grace)
		}
		if sessEnd.After(end) {
			sessEnd = end
		}
		if !sessEnd.After(s) {
			continue
		}
		byKey[ps.ProviderKey] = append(byKey[ps.ProviderKey], interval{s, sessEnd})
	}

	out := make(map[string]float64, len(byKey))
	for key, ivs := range byKey {
		// Sort by start, then sweep-merge overlapping intervals (handles
		// blue-green double-open without double-counting).
		for i := 1; i < len(ivs); i++ {
			for j := i; j > 0 && ivs[j].s.Before(ivs[j-1].s); j-- {
				ivs[j], ivs[j-1] = ivs[j-1], ivs[j]
			}
		}
		var covered float64
		curS, curE := ivs[0].s, ivs[0].e
		for _, iv := range ivs[1:] {
			if iv.s.After(curE) {
				covered += curE.Sub(curS).Seconds()
				curS, curE = iv.s, iv.e
				continue
			}
			if iv.e.After(curE) {
				curE = iv.e
			}
		}
		covered += curE.Sub(curS).Seconds()

		frac := 0.0
		if total > 0 {
			frac = covered / total
		}
		if frac > 1 {
			frac = 1 // no >100% uptime
		}
		out[key] = frac
	}
	return out
}

// latestAccountByProviderKey returns, per provider key, the account from the
// session with the latest connected_at (the current payout linkage).
func latestAccountByProviderKey(sessions []store.ProviderSession) map[string]string {
	type pick struct {
		account string
		when    time.Time
	}
	best := make(map[string]pick)
	for _, ps := range sessions {
		if ps.ProviderKey == "" || ps.AccountID == "" {
			continue
		}
		cur, ok := best[ps.ProviderKey]
		if !ok || ps.ConnectedAt.After(cur.when) {
			best[ps.ProviderKey] = pick{account: ps.AccountID, when: ps.ConnectedAt}
		}
	}
	out := make(map[string]string, len(best))
	for k, v := range best {
		out[k] = v.account
	}
	return out
}

// Run drives hourly settlement of the previous (closed) epoch. Idempotency
// absorbs duplicate ticks, restarts, and blue-green double-runs. It returns when
// ctx is cancelled; launch it via saferun.Go so a panic never crashes the
// process.
func (e *Engine) Run(ctx context.Context) {
	if !e.cfg.Enabled {
		return
	}
	// Settle once at startup (covers a restart that missed the tick), then hourly.
	e.settleOnce(ctx)
	ticker := time.NewTicker(time.Hour)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			e.settleOnce(ctx)
		}
	}
}

func (e *Engine) settleOnce(ctx context.Context) {
	epochID := previousEpochID(e.now())
	res, err := e.SettleEpoch(ctx, epochID)
	if err != nil {
		e.logger.Error("base rewards: settlement failed", "epoch", epochID, "error", err)
		return
	}
	if res.Settled > 0 || res.AlreadySettled > 0 {
		e.logger.Info("base rewards: epoch settled",
			"epoch", res.EpochID,
			"eligible", res.Eligible,
			"settled", res.Settled,
			"already_settled", res.AlreadySettled,
			"total_draw_micro_usd", res.TotalDrawMicroUSD,
		)
	}
}

// Status returns a read-only admin projection of the current settlement state
// for the previous (most recently closed) epoch.
func (e *Engine) Status(ctx context.Context) (map[string]any, error) {
	if !e.cfg.Enabled {
		return map[string]any{"enabled": false}, nil
	}
	epochID := previousEpochID(e.now())
	used, err := e.store.SumFloorDrawsForEpoch(ctx, epochID)
	if err != nil {
		return nil, err
	}
	draws, err := e.store.ListFloorDrawsForEpoch(ctx, epochID)
	if err != nil {
		return nil, err
	}
	return map[string]any{
		"enabled":     true,
		"epoch_id":    epochID,
		"pool_budget": e.cfg.PoolBudgetMicroUSD,
		"pool_used":   used,
		"reduction_k": e.cfg.ReductionK,
		"draw_count":  len(draws),
		"draws":       draws,
	}, nil
}
