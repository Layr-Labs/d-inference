package promptwork_test

import (
	"context"
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/api/promptwork"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
)

func TestAccountingBoundsFallbackParsingBeforeTokenizerReadiness(t *testing.T) {
	gate := production.NewGate()
	releases := make([]func(), 0, 16)
	for range 16 {
		release, ok := gate.Acquire(context.Background(), 100)
		if !ok {
			t.Fatal("unexpected saturation")
		}
		releases = append(releases, release)
	}
	calls := 0
	fallback := production.Result{Work: production.Heuristic(10)}
	parse := func(ctx context.Context) production.Result {
		calls++
		if deadline, ok := ctx.Deadline(); !ok || time.Until(deadline) > promptcontract.DefaultRequestTimeout {
			t.Fatal("parsing lacks bounded request clock")
		}
		// This path needs no tokenizer: a reviewed template fallback may return
		// before readiness while still consuming the shared accounting permit.
		return production.Result{Work: exactWork()}
	}
	got := production.Account(context.Background(), gate, 100, fallback, parse)
	if calls != 0 || got.Work.Source != "heuristic" {
		t.Fatal("saturated gate executed fallback body parsing")
	}
	releases[0]()
	got = production.Account(context.Background(), gate, 100, fallback, parse)
	if calls != 1 || got.Work.Source != "exact_contract" {
		t.Fatal("available permit failed fallback accounting")
	}
	// Account must return its permit even when the callback never calls Plan.
	release, ok := gate.Acquire(context.Background(), 100)
	if !ok {
		t.Fatal("not-ready fallback leaked permit")
	}
	release()
	for _, release := range releases[1:] {
		release()
	}
	if got := production.Account(context.Background(), gate, promptcontract.DefaultMaxRequestBytes+1, fallback, parse); calls != 1 || got.Work.Source != "heuristic" {
		t.Fatal("oversize body parsed before gate")
	}
}

func TestAccountingPreservesOriginalDeadlineAndRejectsExpiredWork(t *testing.T) {
	deadline := time.Now().Add(20 * time.Millisecond)
	ctx, cancel := context.WithDeadline(context.Background(), deadline)
	defer cancel()
	fallback := production.Result{Work: production.Heuristic(10)}
	calls := 0
	_ = production.Account(ctx, production.NewGate(), 100, fallback, func(ctx context.Context) production.Result {
		calls++
		if got, _ := ctx.Deadline(); !got.Equal(deadline) {
			t.Fatal("accounting reset original deadline")
		}
		<-ctx.Done()
		return fallback
	})
	_ = production.Account(ctx, production.NewGate(), 100, fallback, func(context.Context) production.Result { calls++; return fallback })
	if calls != 1 {
		t.Fatal("expired request performed parsing")
	}
}
