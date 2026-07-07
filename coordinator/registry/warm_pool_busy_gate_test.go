package registry

import (
	"testing"
	"time"
)

// Tests for the bounded-busy warm-pool candidate gate (postmortem 2026-07-06
// layer 7): eligibility is pendingCount + Σ slots(NumRunning+NumWaiting) <=
// WarmPoolConfig.AllowBusyLoadMax, with the default 0 preserving the historical
// fully-idle requirement exactly, and non-idle candidates additionally required
// to fit the model weights WITHOUT evicting co-resident models.

// warmCandidateReason evaluates the warm-pool candidate gate under the lock
// discipline the fleet snapshot uses and returns the disqualification reason
// ("" = eligible).
func warmCandidateReason(reg *Registry, p *Provider, model string) warmColdReason {
	reg.mu.RLock()
	defer reg.mu.RUnlock()
	p.mu.Lock()
	defer p.mu.Unlock()
	_, reason := reg.warmPoolCandidateReasonLocked(p, model, time.Now())
	return reason
}

// configureBusyGate installs a warm-pool config with the given bounded-busy
// threshold (the only knob under test here).
func configureBusyGate(reg *Registry, allowBusyLoadMax int) {
	cfg := testWarmPoolConfig()
	cfg.AllowBusyLoadMax = allowBusyLoadMax
	reg.ConfigureWarmPool(cfg)
}

// TestWarmPoolBusyGateDefaultZeroPreservesFullIdle pins the AllowBusyLoadMax=0
// default to the exact historical behavior: ANY activity — one coordinator-
// pending request or one backend-busy slot — disqualifies the cold candidate
// with warmColdNotIdle, and a truly idle box is eligible. Covers both the
// unconfigured-controller default and an explicit 0.
func TestWarmPoolBusyGateDefaultZeroPreservesFullIdle(t *testing.T) {
	model := "busy-gate-default"

	for _, configured := range []bool{false, true} {
		reg := New(testLogger())
		if configured {
			configureBusyGate(reg, 0)
		}

		idle := makeWarmPoolColdProvider(t, reg, "idle", model, 80, 64, 8)
		if got := warmCandidateReason(reg, idle, model); got != warmColdEligible {
			t.Fatalf("configured=%v idle box reason = %q, want eligible", configured, got)
		}

		backendBusy := makeWarmPoolColdProvider(t, reg, "backend-busy", model, 80, 64, 8)
		backendBusy.mu.Lock()
		backendBusy.BackendCapacity.Slots[0].NumRunning = 1
		backendBusy.mu.Unlock()
		if got := warmCandidateReason(reg, backendBusy, model); got != warmColdNotIdle {
			t.Fatalf("configured=%v backend-busy box reason = %q, want %q", configured, got, warmColdNotIdle)
		}

		pending := makeWarmPoolColdProvider(t, reg, "pending", model, 80, 64, 8)
		pending.mu.Lock()
		pending.pendingReqs["r1"] = &PendingRequest{RequestID: "r1", Model: "other-model"}
		pending.mu.Unlock()
		if got := warmCandidateReason(reg, pending, model); got != warmColdNotIdle {
			t.Fatalf("configured=%v 1-pending box reason = %q, want %q", configured, got, warmColdNotIdle)
		}
	}
}

// TestWarmPoolBusyGateBoundedThreshold exercises the AllowBusyLoadMax=2
// boundary: total busy load (coordinator-pending + backend running+waiting,
// summed across ALL slots) of 1 or 2 is eligible, 3 is not.
func TestWarmPoolBusyGateBoundedThreshold(t *testing.T) {
	model := "busy-gate-bounded"

	cases := []struct {
		name       string
		pending    int
		numRunning int
		numWaiting int
		want       warmColdReason
	}{
		{name: "busy_1_running", numRunning: 1, want: warmColdEligible},
		{name: "busy_2_running_waiting", numRunning: 1, numWaiting: 1, want: warmColdEligible},
		{name: "busy_2_pending_plus_running", pending: 1, numRunning: 1, want: warmColdEligible},
		{name: "busy_3_over_threshold", numRunning: 2, numWaiting: 1, want: warmColdNotIdle},
		{name: "busy_3_pending_plus_backend", pending: 1, numRunning: 2, want: warmColdNotIdle},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			reg := New(testLogger())
			configureBusyGate(reg, 2)
			p := makeWarmPoolColdProvider(t, reg, "box-"+tc.name, model, 80, 64, 8)
			p.mu.Lock()
			p.BackendCapacity.Slots[0].NumRunning = tc.numRunning
			p.BackendCapacity.Slots[0].NumWaiting = tc.numWaiting
			for i := 0; i < tc.pending; i++ {
				id := "r" + string(rune('0'+i))
				p.pendingReqs[id] = &PendingRequest{RequestID: id, Model: "other-model"}
			}
			p.mu.Unlock()

			if got := warmCandidateReason(reg, p, model); got != tc.want {
				t.Fatalf("reason = %q, want %q", got, tc.want)
			}
		})
	}
}

// TestWarmPoolBusyGateNoEvictionFit pins the no-eviction rule for non-idle
// candidates (mirror of the dispatch path's freeMemoryAdmits, which only
// consults the eviction-aware headroom when totalPending == 0): a busy box must
// fit the weights in its CURRENT free memory (total - gpuActive), because it
// cannot evict idle co-resident models. The same box, idle, stays eligible —
// eviction is available again.
func TestWarmPoolBusyGateNoEvictionFit(t *testing.T) {
	model := "busy-gate-no-evict"
	catalog := []CatalogEntry{{ID: model, SizeGB: 30, MinRAMGB: 36}}

	build := func(t *testing.T, activeGB float64, busy int, freeForLoadGB *float64) (*Registry, *Provider) {
		reg := New(testLogger())
		configureBusyGate(reg, 2)
		reg.SetModelCatalog(catalog)
		p := makeWarmPoolColdProvider(t, reg, "box", model, 80, 36, activeGB)
		p.mu.Lock()
		p.BackendCapacity.Slots[0].NumRunning = busy
		p.BackendCapacity.FreeForLoadGB = freeForLoadGB
		p.mu.Unlock()
		return reg, p
	}

	// Busy box, weights (30 GB) exceed current free memory (36-20=16 GB): the
	// bounded-busy gate admits it but the no-eviction fit vetoes.
	reg, p := build(t, 20, 1, nil)
	if got := warmCandidateReason(reg, p, model); got != warmColdBusyNoEvict {
		t.Fatalf("busy tight-memory box reason = %q, want %q", got, warmColdBusyNoEvict)
	}

	// The SAME memory shape, idle: eligible — an idle box may evict, and the
	// eviction-aware reported gate (absent here) is the only fit authority.
	reg, p = build(t, 20, 0, nil)
	if got := warmCandidateReason(reg, p, model); got != warmColdEligible {
		t.Fatalf("idle tight-memory box reason = %q, want eligible (idle boxes may evict)", got)
	}

	// Busy box with real headroom (36-2=34 GB >= 30 GB): eligible.
	reg, p = build(t, 2, 1, nil)
	if got := warmCandidateReason(reg, p, model); got != warmColdEligible {
		t.Fatalf("busy roomy box reason = %q, want eligible", got)
	}

	// The provider-reported free-for-load gate still runs FIRST: a busy box whose
	// reported loadable headroom is too small is no_free_for_load, not the
	// no-eviction reason.
	tooSmall := 10.0
	reg, p = build(t, 2, 1, &tooSmall)
	if got := warmCandidateReason(reg, p, model); got != warmColdNoFreeForLoad {
		t.Fatalf("busy reported-too-small box reason = %q, want %q", got, warmColdNoFreeForLoad)
	}
}

// TestWarmColdReasonStringsStable pins every warmColdReason string: they are
// exported as Datadog gauge tags (warm_pool.cold_disqualified reason:<...>) and
// appear in warm_pool_tick logs — dashboards key on them, so a rename is a
// breaking change, not a refactor.
func TestWarmColdReasonStringsStable(t *testing.T) {
	want := map[warmColdReason]string{
		warmColdEligible:       "",
		warmColdOfflineUntrust: "offline_untrusted_private",
		warmColdPendingLoad:    "pending_load_or_cooldown",
		warmColdNotIdle:        "not_idle",
		warmColdThermal:        "thermal_critical",
		warmColdTrust:          "trust_or_runtime",
		warmColdStaleChallenge: "stale_challenge",
		warmColdNotServing:     "not_serving_catalog",
		warmColdDedicated:      "dedicated_excluded",
		warmColdTooLarge:       "model_too_large",
		warmColdNoFreeForLoad:  "no_free_for_load",
		warmColdBusyNoEvict:    "busy_no_evict_headroom",
	}
	for reason, s := range want {
		if string(reason) != s {
			t.Fatalf("warmColdReason %q changed, want %q — gauge tags/dashboards key on these strings", string(reason), s)
		}
	}
}
