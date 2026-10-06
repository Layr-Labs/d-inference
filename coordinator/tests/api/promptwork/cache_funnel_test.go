package promptwork_test

import (
	"context"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/api/promptwork"
	"github.com/eigeninference/d-inference/coordinator/internal/observation/cachefunnel"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
)

func TestOnlyASaturatedGateDefersPlanning(t *testing.T) {
	gate := production.NewGate()
	releases := make([]func(), 0, 16)
	for range 16 {
		release, ok := gate.Acquire(context.Background(), 100)
		if !ok {
			t.Fatal("unexpected saturation")
		}
		releases = append(releases, release)
	}
	fallback := production.Result{Work: production.Heuristic(10)}
	planned := func(context.Context) production.Result { return production.Result{Work: exactWork()} }

	if !production.Account(context.Background(), gate, 100, fallback, planned).PlanningDeferred() {
		t.Fatal("a request refused by the full gate is not reported as deferred")
	}
	cancelled, cancel := context.WithCancel(context.Background())
	cancel()
	if production.Account(cancelled, gate, 100, fallback, planned).PlanningDeferred() {
		t.Fatal("a cancelled request is reported as a gate refusal")
	}
	if production.Account(context.Background(), gate, promptcontract.DefaultMaxRequestBytes+1, fallback, planned).PlanningDeferred() {
		t.Fatal("an oversized body is reported as a gate refusal")
	}
	releases[0]()
	if production.Account(context.Background(), gate, 100, fallback, planned).PlanningDeferred() {
		t.Fatal("a request that held a slot is reported as deferred")
	}
	for _, release := range releases[1:] {
		release()
	}
}

func TestMemoCarriesTheFunnelAccountThroughTheRequestContext(t *testing.T) {
	if got := production.CacheFunnelFromContext(context.Background()); got != nil {
		t.Fatalf("context without a memo yields funnel account %p, want none", got)
	}
	outside := &production.Memo{}
	if got := production.CacheFunnelFromContext(production.WithMemo(context.Background(), outside)); got != nil {
		t.Fatalf("request outside the population yields funnel account %p, want none", got)
	}

	ledger := cachefunnel.NewLedger(nil)
	account := ledger.Enter()
	memo := &production.Memo{}
	memo.ObserveCacheFunnel(account)
	planning, cancel := context.WithCancel(production.WithMemo(context.Background(), memo))
	defer cancel()
	if got := production.CacheFunnelFromContext(planning); got != account {
		t.Fatalf("derived planning context yields %p, want the request's account %p", got, account)
	}

	// The gate refusal is recorded through the context alone, as the planning
	// entry point does, and is the request's terminal reason.
	production.CacheFunnelFromContext(planning).NotePlanning(cachefunnel.PlanningGateRefused, cachefunnel.Tokens{})
	account.Close(false)
	status := ledger.Snapshot()
	for _, totals := range status.Reasons {
		want := uint64(0)
		if totals.Reason == cachefunnel.GateRefused.String() {
			want = 1
		}
		if totals.Requests != want {
			t.Fatalf("reason %q counts %d requests, want %d", totals.Reason, totals.Requests, want)
		}
	}
}
