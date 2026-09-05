package registry

import (
	"testing"
	"time"
)

// TestPairKeysCannotAliasAcrossDelimiter pins the guarantee the old
// "providerID:modelID" strings lacked: ("a:b", "c") and ("a", "b:c") are
// different pairs for both the dispatch-load cooldown (now a per-identity gate
// keyed inside by model) and pending model loads (a struct key).
func TestPairKeysCannotAliasAcrossDelimiter(t *testing.T) {
	r := New(testLogger())
	makeSchedulerProvider(t, r, "a:b", "c", 50)
	makeSchedulerProvider(t, r, "a", "b:c", 50)

	if !r.RecordDispatchLoadFailure("a:b", "c") {
		t.Fatal("first failure must start a cooldown")
	}
	aliased := r.dispatchLoadCooled("a", "b:c", time.Now())
	direct := r.dispatchLoadCooled("a:b", "c", time.Now())
	if aliased || !direct {
		t.Fatalf("dispatch-load cooldown aliased across ':' (aliased=%v direct=%v)", aliased, direct)
	}

	r.reservePendingModelLoads([]modelLoadAction{{providerID: "a:b", modelID: "c"}}, time.Now())
	if r.HasPendingModelLoad("a", "b:c") {
		t.Fatal("pending model load aliased across ':'")
	}
	if !r.HasPendingModelLoad("a:b", "c") {
		t.Fatal("pending model load not recorded for the real pair")
	}
}

// TestDispatchLoadCooldownGateAllocatesNothing pins the hot-path contract for
// the per-provider cooldown gate, on both the scan's cached-gate path and the
// session-resolving path.
func TestDispatchLoadCooldownGateAllocatesNothing(t *testing.T) {
	r := New(testLogger())
	p1 := makeSchedulerProvider(t, r, "p1", "m", 50)
	p2 := makeSchedulerProvider(t, r, "p2", "m", 50)
	r.RecordDispatchLoadFailure("p1", "m")
	now := time.Now()
	r.mu.RLock()
	defer r.mu.RUnlock()
	hits := 0
	allocs := testing.AllocsPerRun(200, func() {
		if r.gateOf(p1).dispatchLoadCooled("m", now) {
			hits++
		}
		if r.gateOf(p2).dispatchLoadCooled("m", now) {
			hits++
		}
		if r.dispatchLoadCooled("p1", "m", now) {
			hits++
		}
		if r.dispatchLoadCooled("p2", "m", now) {
			hits++
		}
	})
	if allocs != 0 {
		t.Fatalf("cooldown gate allocated %v per run; want 0", allocs)
	}
	if hits == 0 {
		t.Fatal("active cooldown was not observed")
	}
}

// TestDisconnectDropsOnlyThatProvidersPendingLoads pins the Disconnect sweep:
// the session's own pending loads go, a provider whose id merely shares a
// prefix keeps its entries (exact field match, as the old "id:" prefix test
// also guaranteed), and a disconnected identity-less provider's dispatch-load
// residue is dropped by exact fault-key match.
func TestDisconnectDropsOnlyThatProvidersPendingLoads(t *testing.T) {
	r := New(testLogger())
	makeSchedulerProvider(t, r, "p1", "m", 50)
	makeSchedulerProvider(t, r, "p10", "m", 50)
	now := time.Now()
	r.reservePendingModelLoads([]modelLoadAction{
		{providerID: "p1", modelID: "m"},
		{providerID: "p10", modelID: "m"},
	}, now)
	r.RecordDispatchLoadFailure("p1", "m")
	r.RecordDispatchLoadFailure("p10", "m")

	r.Disconnect("p1")

	if r.HasPendingModelLoad("p1", "m") {
		t.Fatal("disconnected provider's pending load survived")
	}
	if !r.HasPendingModelLoad("p10", "m") {
		t.Fatal("prefix-sharing provider's pending load was dropped")
	}
	if r.dispatchLoadCooled("p1", "m", now) {
		t.Fatal("identity-less disconnected provider's cooldown residue survived")
	}
	if !r.dispatchLoadCooled("p10", "m", now) {
		t.Fatal("prefix-sharing provider's cooldown was dropped")
	}
}
