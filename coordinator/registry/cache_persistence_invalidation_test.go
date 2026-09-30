package registry

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

// Stop the ticker so these tests control every restore and flush explicitly.
func startStoppedCachePersistence(t *testing.T, r *Registry, st store.Store, wantFailure bool) {
	t.Helper()
	r.SetStore(st)
	ctx, cancel := context.WithCancel(context.Background())
	status, err := r.StartCacheRoutingPersistence(ctx)
	cancel()
	join, stop := context.WithTimeout(context.Background(), 5*time.Second)
	defer stop()
	if !r.WaitCacheRoutingPersistence(join) {
		t.Fatal("persistence loop did not stop")
	}
	if (err != nil) != wantFailure || !status.Enabled || status.Ready == wantFailure {
		t.Fatalf("unexpected start: status=%+v err=%v wantFailure=%v", status, err, wantFailure)
	}
}

func TestCachePersistenceInvalidationBeforeRestore(t *testing.T) {
	for _, outcome := range []string{"miss_absent", "miss_corrupt", "hit"} {
		t.Run(outcome, func(t *testing.T) {
			ctx := context.Background()
			mem := store.NewMemory(store.Config{})
			clock := time.Now().Add(-10 * time.Second)
			r1, _, capability := exactTestRegistry(t)
			removeTestProvider(r1, "provider-a")
			r1.SetCacheRoutingClockForTest(func() time.Time { return clock })
			capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
			startStoppedCachePersistence(t, r1, mem, false)
			first := persistenceTestProvider(t, r1, "first", capability)
			short, deep := exactTestAnchor(16, "c"), exactTestAnchor(32, "d")
			plan1 := boundTestCachePlan(r1, exactTestPlan(short, deep))
			_, ready := checkpointTestAttempt(t, r1, first, capability, "donor", plan1, 1)
			clock = clock.Add(time.Second)
			if !r1.ApplyPrefixCacheReadyV2(first.ID, ready) {
				t.Fatal("initial Ready rejected")
			}
			if err := r1.FlushCacheRoutingState(ctx); err != nil {
				t.Fatal(err)
			}
			if rows := storedHolders(t, mem); len(rows) != 1 || rows[0].AnchorTokenCount != deep.TokenCount {
				t.Fatalf("deep boundary not persisted: %+v", rows)
			}

			flaky := &fingerprintFlakyStore{MemoryStore: mem}
			flaky.fail.Store(true)
			r2, _, _ := exactTestRegistry(t)
			removeTestProvider(r2, "provider-a")
			clock = clock.Add(time.Second)
			r2.SetCacheRoutingClockForTest(func() time.Time { return clock })
			startStoppedCachePersistence(t, r2, flaky, true)
			back := persistenceTestProvider(t, r2, "back", capability)
			plan2 := boundTestCachePlan(r2, exactTestPlan(short, deep))
			if hints := memoryTestHints(r2, plan2, clock); len(hints) != 0 {
				t.Fatalf("failed restore supplied evidence: %+v", hints)
			}
			pr := &PendingRequest{RequestID: "lookup", Model: "model", CachePlan: plan2}
			if err := prepareBoundTestCacheAttempt(r2, pr, back); err != nil {
				t.Fatal(err)
			}
			lookup := testV2Lookup(preparedTestCacheMetadata(pr).CacheReceiptNonce, capability, deep, 1)
			lookup.RequestID, lookup.Outcome = pr.RequestID, outcome
			if outcome == "hit" {
				lookup.MatchedAnchor = &short
				lookup.ExpectedPrefillTokensSaved = short.TokenCount
			}
			if result := r2.ApplyPrefixCacheLookupV2Result(back.ID, lookup); !result.Accepted {
				t.Fatalf("lookup rejected: %+v", result)
			}
			r2.MarkCacheAttemptTerminal(pr)
			flaky.fail.Store(false)
			if err := r2.restoreCacheRoutingState(ctx, r2.cachePersister, r2.cacheRouting); err != nil {
				t.Fatal(err)
			}
			hints := memoryTestHints(r2, plan2, clock)
			wantRows := 0
			if outcome == "hit" {
				wantRows = 1
				if hints[back.ID].CachedTokens != short.TokenCount {
					t.Fatalf("shorter hit replaced by stale deeper evidence: %+v", hints)
				}
			} else if len(hints) != 0 {
				t.Fatalf("missed boundary resurrected: %+v", hints)
			}
			if err := r2.FlushCacheRoutingState(ctx); err != nil {
				t.Fatal(err)
			}
			rows := storedHolders(t, mem)
			if len(rows) != wantRows || (len(rows) == 1 && rows[0].AnchorTokenCount != short.TokenCount) {
				t.Fatalf("invalidated boundary remains durable: %+v", rows)
			}
		})
	}
}

func TestCachePersistenceNewestSessionInvalidation(t *testing.T) {
	for _, backend := range []string{"memory", "postgres"} {
		t.Run(backend, func(t *testing.T) {
			for _, flushed := range []bool{false, true} {
				name := "queued"
				if flushed {
					name = "flushed"
				}
				t.Run(name, func(t *testing.T) {
					var st store.Store = store.NewMemory(store.Config{})
					if backend == "postgres" {
						st = isolatedPostgresStore(t)
					}
					durable, _ := store.As[crs.Store](st)
					ctx := context.Background()
					base := time.Now().Add(-2 * time.Minute).Truncate(time.Second)
					clock := base
					r, _, capability := exactTestRegistry(t)
					removeTestProvider(r, "provider-a")
					r.SetCacheRoutingClockForTest(func() time.Time { return clock })
					capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
					startStoppedCachePersistence(t, r, st, false)
					older := persistenceTestProvider(t, r, "older", capability)
					newer := persistenceTestProvider(t, r, "newer", capability)
					anchor := exactTestAnchor(16, "c")
					plan := boundTestCachePlan(r, exactTestPlan(anchor))
					for i, p := range []*Provider{older, newer} {
						clock = base.Add(time.Duration(i) * 30 * time.Second)
						_, ready := checkpointTestAttempt(t, r, p, capability, "donor-"+p.ID, plan, 1)
						clock = clock.Add(time.Second)
						ready.StageMs = float64(50 + i*850)
						if !r.ApplyPrefixCacheReadyV2(p.ID, ready) {
							t.Fatal("Ready rejected")
						}
					}
					if hints := memoryTestHints(r, plan, clock); len(hints) != 2 {
						t.Fatalf("expected both live holders: %+v", hints)
					}
					if flushed {
						if err := r.FlushCacheRoutingState(ctx); err != nil {
							t.Fatal(err)
						}
					}
					clock = clock.Add(time.Second)
					pr := &PendingRequest{RequestID: "miss", Model: "model", CachePlan: plan}
					if err := prepareBoundTestCacheAttempt(r, pr, newer); err != nil {
						t.Fatal(err)
					}
					miss := testV2Lookup(preparedTestCacheMetadata(pr).CacheReceiptNonce, capability, anchor, 3)
					miss.RequestID = pr.RequestID
					if result := r.ApplyPrefixCacheLookupV2Result(newer.ID, miss); !result.Accepted {
						t.Fatalf("miss rejected: %+v", result)
					}
					if hints := memoryTestHints(r, plan, clock); len(hints) != 1 || hints[older.ID].StageMs != 50 {
						t.Fatalf("older in-memory holder was lost: %+v", hints)
					}
					if err := r.FlushCacheRoutingState(ctx); err != nil {
						t.Fatal(err)
					}
					if rows, err := durable.LoadCacheHolders(ctx, clock, 0, 0); err != nil || len(rows) != 0 {
						t.Fatalf("invalidated newer record persisted: rows=%+v err=%v", rows, err)
					}
					clock = base.Add(62 * time.Second)
					if hints := memoryTestHints(r, plan, clock); len(hints) != 0 {
						t.Fatalf("older holder should have expired: %+v", hints)
					}
					r2, _, _ := exactTestRegistry(t)
					removeTestProvider(r2, "provider-a")
					r2.SetCacheRoutingClockForTest(func() time.Time { return clock })
					startStoppedCachePersistence(t, r2, st, false)
					persistenceTestProvider(t, r2, "restarted", capability)
					if hints := memoryTestHints(r2, boundTestCachePlan(r2, exactTestPlan(anchor)), clock); len(hints) != 0 {
						t.Fatalf("restart resurrected invalidated evidence: %+v", hints)
					}
				})
			}
		})
	}
}
