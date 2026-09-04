package registry

import (
	"fmt"
	"testing"
	"time"
)

// In-gap pending charge (buildCandidateInto, budget-reporting branch): a
// request the coordinator has reserved on a box but whose heartbeat has not
// yet reflected it is charged to that box's backlog exactly as the heartbeat
// will charge it once reported (Σ prompt + max_output at the box's decode
// rate). Before this, a reserved request raised the winner's cost by only
// queueMs + pendingMs (3.75 s) until the next heartbeat, so at large
// max_tokens — where the per-tok/s cost gap between boxes is 5-9 s — a
// concurrent-arrival cohort herded onto the cheapest box up to its cap.

// inGapCandidate builds provider p's routing candidate exactly as the scan
// does (snapshot + cost), under the shared lock.
func inGapCandidate(t *testing.T, reg *Registry, p *Provider, model string, pr *PendingRequest) *routingCandidate {
	t.Helper()
	reg.mu.RLock()
	defer reg.mu.RUnlock()
	now := time.Now()
	snap, ok := reg.snapshotProviderLockedEx(p, model, pr.Traits, false, false, now)
	if !ok {
		t.Fatalf("%s failed the routing gates", p.ID)
	}
	c, reason, ok := reg.buildCandidateWithReason(snap, pr, now)
	if !ok {
		t.Fatalf("%s rejected: %v", p.ID, reason)
	}
	return c
}

func inGapPending(id, model string, prompt, maxTok int) *PendingRequest {
	return &PendingRequest{RequestID: id, Model: model, EstimatedPromptTokens: prompt, RequestedMaxTokens: maxTok}
}

// TestInGapPendingChargedLikeHeartbeatOccupant: two identical budget-reporting
// boxes, one carrying an in-gap coordinator pending of R tokens, the other a
// heartbeat-reported occupant of the same R (which the coordinator also still
// holds pending, as in production) — equal BacklogMs and equal CostMs, and
// the breakdown still sums to Total.
func TestInGapPendingChargedLikeHeartbeatOccupant(t *testing.T) {
	reg := New(testLogger())
	model := "in-gap-parity-model"
	const prompt, maxTok = 500, 4096
	occupant := int64(prompt + maxTok)

	inGap := makeTokenBudgetProvider(t, reg, "in-gap", model, 100, 0, 1_000_000, 80)
	inGap.AddPending(inGapPending("occupant-a", model, prompt, maxTok))

	reported := makeTokenBudgetProvider(t, reg, "reported", model, 100, occupant, 1_000_000, 80)
	reported.mu.Lock()
	reported.BackendCapacity.Slots[0].NumRunning = 1
	reported.mu.Unlock()
	reported.AddPending(inGapPending("occupant-b", model, prompt, maxTok))

	pr := inGapPending("probe", model, prompt, maxTok)
	a := inGapCandidate(t, reg, inGap, model, pr)
	b := inGapCandidate(t, reg, reported, model, pr)
	if a.breakdown.BacklogMs <= 0 {
		t.Fatalf("in-gap pending not charged: BacklogMs=%v", a.breakdown.BacklogMs)
	}
	if a.breakdown.BacklogMs != b.breakdown.BacklogMs {
		t.Fatalf("BacklogMs in-gap=%v reported=%v, want equal (same unit, same rate)", a.breakdown.BacklogMs, b.breakdown.BacklogMs)
	}
	if a.costMs != b.costMs {
		t.Fatalf("CostMs in-gap=%v reported=%v, want equal", a.costMs, b.costMs)
	}
	if inGapPendingTokens(&a.snapshot) == 0 || inGapPendingTokens(&b.snapshot) != 0 {
		t.Fatalf("inGapPendingTokens in-gap=%d reported=%d, want >0/0", inGapPendingTokens(&a.snapshot), inGapPendingTokens(&b.snapshot))
	}
	bd := a.breakdown
	sum := bd.StateMs + bd.QueueMs + bd.PendingMs + bd.BacklogMs + bd.ThisReqMs + bd.HealthMs + bd.CapacityRateMs
	if sum != bd.Total {
		t.Fatalf("breakdown sum %v != Total %v", sum, bd.Total)
	}
}

// TestInGapPendingNotDoubleChargedOnceReported: once the heartbeat reflects
// the pending (maxTokensPotential or active+queued >= pendingMaxTokens) the
// in-gap extra is zero — the charge moves from the coordinator ledger to the
// heartbeat, it never stacks.
func TestInGapPendingNotDoubleChargedOnceReported(t *testing.T) {
	reg := New(testLogger())
	model := "in-gap-dedup-model"
	const prompt, maxTok = 500, 4096
	occupant := int64(prompt + maxTok)
	pr := inGapPending("probe", model, prompt, maxTok)

	viaPotential := makeTokenBudgetProvider(t, reg, "via-potential", model, 100, 0, 1_000_000, 80)
	viaPotential.mu.Lock()
	viaPotential.BackendCapacity.Slots[0].MaxTokensPotential = occupant
	viaPotential.mu.Unlock()
	viaPotential.AddPending(inGapPending("occ-1", model, prompt, maxTok))
	if c := inGapCandidate(t, reg, viaPotential, model, pr); c.breakdown.BacklogMs != 0 || inGapPendingTokens(&c.snapshot) != 0 {
		t.Fatalf("maxTokensPotential-reported pending charged again: BacklogMs=%v extra=%d", c.breakdown.BacklogMs, inGapPendingTokens(&c.snapshot))
	}

	viaUsed := makeTokenBudgetProvider(t, reg, "via-used", model, 100, occupant, 1_000_000, 80)
	viaUsed.AddPending(inGapPending("occ-2", model, prompt, maxTok))
	c := inGapCandidate(t, reg, viaUsed, model, pr)
	if want := float64(occupant) / 80 * 1000; c.breakdown.BacklogMs != want || inGapPendingTokens(&c.snapshot) != 0 {
		t.Fatalf("active-reported pending charged twice: BacklogMs=%v want %v extra=%d", c.breakdown.BacklogMs, want, inGapPendingTokens(&c.snapshot))
	}
}

// TestInGapPendingSpreadsConcurrentCohort promotes the herding probe: 20 warm
// budget-reporting boxes at 60..79 tok/s, 40 sequential reservations with NO
// heartbeats in between (the whole cohort lands inside one heartbeat gap).
// Max load per box must stay <= 2 at every max_tokens; at 32,768 the old cost
// piled 8 onto the fastest box (its concurrency cap) because one in-gap
// pending cost 3.75 s while the gap to the next box was 5.3 s.
func TestInGapPendingSpreadsConcurrentCohort(t *testing.T) {
	for _, maxTok := range []int{256, 4096, 32_768} {
		t.Run(fmt.Sprintf("max_tokens=%d", maxTok), func(t *testing.T) {
			reg := New(testLogger())
			model := "in-gap-herd-model"
			const boxes, requests = 20, 40
			for i := range boxes {
				tps := float64(60 + i)
				p := makeTokenBudgetProvider(t, reg, fmt.Sprintf("box-%02d", i), model, tps, 0, 4_000_000, tps)
				p.mu.Lock()
				p.BackendCapacity.Slots[0].MaxConcurrency = 8
				p.mu.Unlock()
			}
			load := map[string]int{}
			var last RoutingDecision
			for i := range requests {
				pr := inGapPending(fmt.Sprintf("herd-%d", i), model, 500, maxTok)
				p, decision := reg.ReserveProviderEx(model, pr)
				if p == nil {
					t.Fatalf("reservation %d failed: %+v", i, decision)
				}
				load[p.ID]++
				last = decision
			}
			maxLoad := 0
			for _, n := range load {
				if n > maxLoad {
					maxLoad = n
				}
			}
			if maxLoad > 2 || len(load) != boxes {
				t.Fatalf("max load %d across %d boxes, want <= 2 across all %d (load=%v)", maxLoad, len(load), boxes, load)
			}
			// The exposure tally: every box carried an in-gap pending by the
			// last scan.
			if last.InGapPendingCandidates != boxes {
				t.Fatalf("InGapPendingCandidates=%d on the last scan, want %d", last.InGapPendingCandidates, boxes)
			}
		})
	}
}

// TestInGapPendingMakesColdBoxCheaperAtLargeMaxTokens documents the
// product-visible edge: at max_tokens 32,768 one in-gap pending on the
// fastest warm box (79 tok/s: 421 s of charged backlog + 415 s for this
// request) makes an idle COLD box with the same rate (30 s load penalty +
// 415 s) the cheaper route — identical to what the heartbeat-reported charge
// does a few hundred ms later, only immediate. The charge is proportional
// to the pending's size: a small in-gap pending (256 tokens, ~10 s of
// backlog) leaves the warm box cheaper than the 30 s cold load.
func TestInGapPendingMakesColdBoxCheaperAtLargeMaxTokens(t *testing.T) {
	build := func(t *testing.T, occupantMaxTokens int) (*Registry, string) {
		reg := New(testLogger())
		model := "in-gap-cold-model"
		warm := makeTokenBudgetProvider(t, reg, "warm", model, 79, 0, 4_000_000, 79)
		warm.AddPending(inGapPending("warm-occupant", model, 500, occupantMaxTokens))
		scenarioProvider{id: "cold", decodeTPS: 79, totalMemGB: 64, slotState: "unknown"}.register(t, reg, model)
		return reg, model
	}
	t.Run("32768-token in-gap pending routes the next 32768 to the cold box", func(t *testing.T) {
		reg, model := build(t, 32_768)
		p, decision := reg.ReserveProviderEx(model, inGapPending("big", model, 500, 32_768))
		if p == nil || p.ID != "cold" {
			t.Fatalf("winner=%v (cost %v, backlog %v), want the idle cold box", p, decision.CostMs, decision.BacklogMs)
		}
		if decision.StateMs != slotStatePenaltyUnknown {
			t.Fatalf("StateMs=%v, want the cold-load penalty %v", decision.StateMs, slotStatePenaltyUnknown)
		}
	})
	t.Run("256-token in-gap pending keeps the warm box cheaper", func(t *testing.T) {
		reg, model := build(t, 256)
		p, decision := reg.ReserveProviderEx(model, inGapPending("small", model, 500, 256))
		if p == nil || p.ID != "warm" {
			t.Fatalf("winner=%v (cost %v), want the warm box", p, decision.CostMs)
		}
	})
}
