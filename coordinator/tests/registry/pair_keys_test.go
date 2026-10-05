package registry_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/identitygate"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// TestPairKeysCannotAliasAcrossDelimiter pins the guarantee the old
// "providerID:modelID" strings lacked: ("a:b", "c") and ("a", "b:c") are
// different pairs for both the dispatch-load cooldown (now a per-identity gate
// keyed inside by model) and pending model loads (a struct key).
func TestPairKeysCannotAliasAcrossDelimiter(t *testing.T) {
	gates := identitygate.New(testLogger(), nil)
	var planner *production.ModelLoadPlanner
	r := production.NewWithDependencies(testLogger(), production.Dependencies{
		IdentityGates: gates,
		ModelLoadPlanning: func(p *production.ModelLoadPlanner) production.ModelLoadPlanning {
			planner = p
			return p
		},
	})
	makeSchedulerProvider(t, r, "a:b", "c", 50)
	makeSchedulerProvider(t, r, "a", "b:c", 50)

	if !r.RecordDispatchLoadFailure("a:b", "c") {
		t.Fatal("first failure must start a cooldown")
	}
	aliased := gates.ViewForSession(nil, "a").DispatchLoadCooled("b:c", time.Now())
	direct := gates.ViewForSession(nil, "a:b").DispatchLoadCooled("c", time.Now())
	if aliased || !direct {
		t.Fatalf("dispatch-load cooldown aliased across ':' (aliased=%v direct=%v)", aliased, direct)
	}

	planner.Reserve([]production.ModelLoadAction{{ProviderID: "a:b", ModelID: "c"}}, time.Now())
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
	// Exercise both resolution paths on the actual directory that now owns
	// the gate cache. The cached path must receive its real session handle.
	gates := identitygate.New(testLogger(), nil)
	p1 := gates.Attach("p1")
	p2 := gates.Attach("p2")
	gates.RecordDispatchLoadFailure("p1", "m")
	now := time.Now()
	hits := 0
	allocs := testing.AllocsPerRun(200, func() {
		if gates.ViewForSession(p1, "p1").DispatchLoadCooled("m", now) {
			hits++
		}
		if gates.ViewForSession(p2, "p2").DispatchLoadCooled("m", now) {
			hits++
		}
		if gates.ViewForSession(nil, "p1").DispatchLoadCooled("m", now) {
			hits++
		}
		if gates.ViewForSession(nil, "p2").DispatchLoadCooled("m", now) {
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
	gates := identitygate.New(testLogger(), nil)
	var planner *production.ModelLoadPlanner
	r := production.NewWithDependencies(testLogger(), production.Dependencies{
		IdentityGates: gates,
		ModelLoadPlanning: func(p *production.ModelLoadPlanner) production.ModelLoadPlanning {
			planner = p
			return p
		},
	})
	makeSchedulerProvider(t, r, "p1", "m", 50)
	makeSchedulerProvider(t, r, "p10", "m", 50)
	now := time.Now()
	planner.Reserve([]production.ModelLoadAction{
		{ProviderID: "p1", ModelID: "m"},
		{ProviderID: "p10", ModelID: "m"},
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
	if gates.ViewForSession(nil, "p1").DispatchLoadCooled("m", now) {
		t.Fatal("identity-less disconnected provider's cooldown residue survived")
	}
	if !gates.ViewForSession(nil, "p10").DispatchLoadCooled("m", now) {
		t.Fatal("prefix-sharing provider's cooldown was dropped")
	}
}
