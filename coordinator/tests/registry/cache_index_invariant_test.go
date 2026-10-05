package registry_test

import (
	"fmt"
	"math/rand"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheindex"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachetracker"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// assertCacheIndexInvariants checks the whole tracker bookkeeping: bucket
// maps, holder count, both expiry heaps with their by-key indexes, and both
// per-provider indexes. Call only after concurrent operations have stopped.
func assertCacheIndexInvariants(t *testing.T, fixture *cacheIndexKernelFixture, where string) {
	t.Helper()
	tr := fixture.config
	total := 0
	for key, bucket := range tr.Holders.Buckets() {
		if bucket.Count() == 0 {
			t.Fatalf("%s: empty bucket %q retained", where, key)
		}
		if bucket.Count() > tr.MaxHolders {
			t.Fatalf("%s: bucket %q has %d > %d", where, key, bucket.Count(), tr.MaxHolders)
		}
		for pid, holder := range bucket.Entries() {
			total++
			entry := tr.HolderOrder.Load(cacheindex.HolderRef{Key: key, ProviderID: pid})
			if entry == nil {
				t.Fatalf("%s: holder %q/%q has no heap entry", where, key, pid)
			}
			if !entry.ExpiresAt().Equal(holder.ExpiresAt) {
				t.Fatalf("%s: holder %q/%q heap key %s != expiry %s", where, key, pid, entry.ExpiresAt(), holder.ExpiresAt)
			}
			if indexed := tr.HolderProviders.Contains(pid, entry); !indexed {
				t.Fatalf("%s: holder %q/%q missing from its provider index", where, key, pid)
			}
		}
	}
	if total != tr.Holders.Len() || tr.HolderOrder.Len() != total || tr.HolderOrder.KeyCount() != total {
		t.Fatalf("%s: holders=%d holderCount=%d heap=%d byRef=%d", where, total, tr.Holders.Len(), tr.HolderOrder.Len(), tr.HolderOrder.KeyCount())
	}
	if total > tr.MaxEntries {
		t.Fatalf("%s: holders=%d over cap %d", where, total, tr.MaxEntries)
	}
	for i, entry := range tr.HolderOrder.Entries() {
		if entry.Position() != i {
			t.Fatalf("%s: holder heap[%d].index=%d", where, i, entry.Position())
		}
		if tr.HolderOrder.Load(entry.Key()) != entry {
			t.Fatalf("%s: holder heap[%d] not the indexed entry", where, i)
		}
		if _, ok := tr.Holders.Bucket(entry.Key().Key).Load(entry.Key().ProviderID); !ok {
			t.Fatalf("%s: leaked holder heap entry %+v", where, entry.Key())
		}
		if i > 0 && tr.HolderOrder.Less(i, (i-1)/2) {
			t.Fatalf("%s: holder heap property broken at %d", where, i)
		}
	}
	indexed := 0
	for pid := range tr.HolderProviders.Providers() {
		if tr.HolderProviders.Count(pid) == 0 {
			t.Fatalf("%s: empty holder index retained for provider %q", where, pid)
		}
		for entry := range tr.HolderProviders.Entries(pid) {
			indexed++
			if entry.Key().ProviderID != pid {
				t.Fatalf("%s: provider %q indexes holder %+v", where, pid, entry.Key())
			}
			if tr.HolderOrder.Load(entry.Key()) != entry {
				t.Fatalf("%s: provider %q indexes a leaked holder entry %+v", where, pid, entry.Key())
			}
		}
	}
	if indexed != total {
		t.Fatalf("%s: provider index holds %d holders, index %d", where, indexed, total)
	}

	if tr.AttemptOrder.Len() != tr.Attempts.Len() || tr.AttemptOrder.KeyCount() != tr.Attempts.Len() {
		t.Fatalf("%s: attempts=%d heap=%d byNonce=%d", where, tr.Attempts.Len(), tr.AttemptOrder.Len(), tr.AttemptOrder.KeyCount())
	}
	if tr.Attempts.Len() > tr.MaxAttempts {
		t.Fatalf("%s: attempts=%d over cap %d", where, tr.Attempts.Len(), tr.MaxAttempts)
	}
	for i, entry := range tr.AttemptOrder.Entries() {
		if entry.Position() != i {
			t.Fatalf("%s: attempt heap[%d].index=%d", where, i, entry.Position())
		}
		attempt, ok := tr.Attempts.Load(entry.Key().Nonce)
		if !ok {
			t.Fatalf("%s: leaked attempt heap entry %q", where, entry.Key().Nonce)
		}
		if !entry.ExpiresAt().Equal(attempt.ExpiresAt) {
			t.Fatalf("%s: attempt %q heap key %s != expiry %s", where, entry.Key().Nonce, entry.ExpiresAt(), attempt.ExpiresAt)
		}
		if entry.Key().ProviderID != attempt.ProviderID {
			t.Fatalf("%s: attempt %q indexed under %q, belongs to %q", where, entry.Key().Nonce, entry.Key().ProviderID, attempt.ProviderID)
		}
		if tr.AttemptOrder.Load(entry.Key().Nonce) != entry {
			t.Fatalf("%s: attempt heap[%d] not the indexed entry", where, i)
		}
		if indexed := tr.AttemptProviders.Contains(entry.Key().ProviderID, entry); !indexed {
			t.Fatalf("%s: attempt %q missing from its provider index", where, entry.Key().Nonce)
		}
		if i > 0 && tr.AttemptOrder.Less(i, (i-1)/2) {
			t.Fatalf("%s: attempt heap property broken at %d", where, i)
		}
	}
	indexed = 0
	for pid := range tr.AttemptProviders.Providers() {
		if tr.AttemptProviders.Count(pid) == 0 {
			t.Fatalf("%s: empty attempt index retained for provider %q", where, pid)
		}
		for entry := range tr.AttemptProviders.Entries(pid) {
			indexed++
			if entry.Key().ProviderID != pid || tr.AttemptOrder.Load(entry.Key().Nonce) != entry {
				t.Fatalf("%s: provider %q indexes a leaked attempt entry %q", where, pid, entry.Key().Nonce)
			}
		}
	}
	if indexed != tr.Attempts.Len() {
		t.Fatalf("%s: provider index holds %d attempts, index %d", where, indexed, tr.Attempts.Len())
	}
}

// cacheIndexCensus is the brute-force view: every holder with its model and
// every attempt with its provider and model, read from the primary maps only.
func cacheIndexCensus(fixture *cacheIndexKernelFixture) (map[cacheindex.HolderRef]string, map[string][2]string) {
	tr := fixture.config
	holders := make(map[cacheindex.HolderRef]string)
	for key, bucket := range tr.Holders.Buckets() {
		for pid, holder := range bucket.Entries() {
			holders[cacheindex.HolderRef{Key: key, ProviderID: pid}] = holder.ModelID
		}
	}
	attempts := make(map[string][2]string, tr.Attempts.Len())
	for nonce, attempt := range tr.Attempts.Entries() {
		attempts[nonce] = [2]string{attempt.ProviderID, attempt.Model}
	}
	return holders, attempts
}

// assertCacheInvalidationMatchesCensus compares an index-driven invalidation
// with the full walk it replaced: exactly the entries doomed by the predicate
// are gone and nothing else moved.
func assertCacheInvalidationMatchesCensus(
	t *testing.T, tr *cacheIndexKernelFixture, where string,
	holdersBefore map[cacheindex.HolderRef]string, attemptsBefore map[string][2]string,
	doomed func(providerID, modelID string) bool,
) (removedHolders int) {
	t.Helper()
	holdersAfter, attemptsAfter := cacheIndexCensus(tr)
	for ref, model := range holdersBefore {
		_, kept := holdersAfter[ref]
		if kept == doomed(ref.ProviderID, model) {
			t.Fatalf("%s: holder %+v model %q kept=%v", where, ref, model, kept)
		}
		if !kept {
			removedHolders++
		}
	}
	for nonce, owner := range attemptsBefore {
		if _, kept := attemptsAfter[nonce]; kept == doomed(owner[0], owner[1]) {
			t.Fatalf("%s: attempt %q of %v kept=%v", where, nonce, owner, kept)
		}
	}
	if len(holdersAfter) > len(holdersBefore) || len(attemptsAfter) > len(attemptsBefore) {
		t.Fatalf("%s: invalidation added entries", where)
	}
	return removedHolders
}

// Eight seeds of 6,000 random operations over every mutation the tracker
// has, with caps small enough that the bucket cap, the global cap, the
// attempt cap, bounded sweeps and provider invalidation all fire constantly.
// The full bookkeeping is checked after every operation.
func TestCacheIndexInvariantsUnderRandomMixedSequence(t *testing.T) {
	for _, seed := range []int64{1, 2, 3, 4, 5, 6, 7, 8} {
		t.Run(fmt.Sprintf("seed=%d", seed), func(t *testing.T) {
			rng := rand.New(rand.NewSource(seed))
			var tr *cacheIndexKernelFixture
			var maintenance production.CacheMaintainer
			r := production.NewWithDependencies(testLogger(), production.Dependencies{Cache: production.CacheDependencies{
				MaxEntries: 40, MaxAttempts: 12,
				Trackers: func(config cachetracker.Config[*production.Provider]) *cachetracker.Tracker[*production.Provider] {
					tr = &cacheIndexKernelFixture{Tracker: cachetracker.New(config), config: config}
					return tr.Tracker
				},
				Maintenance: func(owner production.CacheMaintenance) production.CacheMaintainer {
					maintenance = owner
					return owner
				},
			}})
			config := generationTestConfig(production.CacheRoutingOn)
			config.TTL, config.MaxHolders = 10*time.Minute, 3
			if err := r.ConfigureCacheRouting(config); err != nil {
				t.Fatal(err)
			}
			now := time.Unix(1_700_000_000, 0)
			reasons := []cachetracker.RemovalReason{
				cachetracker.RemovalTTL, cachetracker.RemovalDisconnect, cachetracker.RemovalEpochChange,
				cachetracker.RemovalCapabilityChange, cachetracker.RemovalProofMismatch,
				cachetracker.RemovalMissInvalidation, cachetracker.RemovalCapacityEviction, cachetracker.RemovalShorterHit,
			}
			key := func() string {
				tier := "ssd"
				if rng.Intn(3) == 0 {
					tier = "memory"
				}
				return cachetracker.CacheTierKey(fmt.Sprintf("k%02d", rng.Intn(30)), tier)
			}
			tierOf := func(k string) string {
				if len(k) > 7 && k[:7] == "memory:" {
					return "memory"
				}
				return "ssd"
			}
			provider := func() string { return fmt.Sprintf("p%d", rng.Intn(6)) }
			model := func() string { return fmt.Sprintf("m%d", rng.Intn(3)) }
			removals := func(reason cachetracker.RemovalReason) uint64 {
				return indexKernelMetrics(tr).Removed[string(reason)]
			}
			nonces := 0
			nonce := func() string {
				if nonces == 0 {
					return "none"
				}
				return fmt.Sprintf("n%d", rng.Intn(nonces))
			}
			for step := 0; step < 6000; step++ {
				op := rng.Intn(16)
				where := fmt.Sprintf("seed %d step %d op %d", seed, step, op)
				switch op {
				case 0, 1, 2, 3:
					k, p := key(), provider()
					holder := indexKernelHolder{ProviderID: p, ModelID: model(), UpdatedAt: now, ExpiresAt: now.Add(tr.ReceiptTTL(tierOf(k)))}
					if rng.Intn(2) == 0 {
						tr.PreserveStageMeasurementLocked(k, &holder, protocol.PrefixCacheV2Capability{}, now)
					}
					// Brute-force the global cap's victim when only the global cap can fire.
					_, exists := tr.config.Holders.Bucket(k).Load(p)
					checkVictim := !exists && tr.config.Holders.Len() == tr.config.MaxEntries && tr.config.Holders.Bucket(k).Count() < tr.config.MaxHolders
					var victim cacheindex.HolderRef
					var victimExpiry time.Time
					if checkVictim {
						victim, victimExpiry = cacheindex.HolderRef{Key: k, ProviderID: p}, holder.ExpiresAt
						for bk, bucket := range tr.config.Holders.Buckets() {
							for bp, h := range bucket.Entries() {
								ref := cacheindex.HolderRef{Key: bk, ProviderID: bp}
								if h.ExpiresAt.Before(victimExpiry) || (h.ExpiresAt.Equal(victimExpiry) &&
									(ref.Key < victim.Key || (ref.Key == victim.Key && ref.ProviderID < victim.ProviderID))) {
									victim, victimExpiry = ref, h.ExpiresAt
								}
							}
						}
					}
					tr.UpsertHolderLocked(k, holder)
					if checkVictim {
						if _, still := tr.config.Holders.Bucket(victim.Key).Load(victim.ProviderID); still {
							t.Fatalf("%s: cap did not evict the soonest-expiring holder %+v", where, victim)
						}
					}
				case 4:
					tr.RemoveHolderLocked(key(), provider(), reasons[rng.Intn(len(reasons))])
				case 5:
					now = now.Add(time.Duration(rng.Intn(45_000)) * time.Millisecond)
					if rng.Intn(20) == 0 {
						now = now.Add(time.Duration(rng.Intn(12)) * time.Minute)
					}
				case 6:
					tr.SweepIfDueLocked(now)
				case 7:
					tr.ExpireHoldersLocked(now, 1+rng.Intn(3))
					tr.ExpireAttemptsLocked(now, 1+rng.Intn(3))
				case 8:
					k, p := key(), provider()
					holder, live := tr.ActiveHolderLocked(k, p, now)
					if live && !now.Before(holder.ExpiresAt) {
						t.Fatalf("%s: expired holder returned live", where)
					}
				case 9:
					p, m := provider(), model()
					holdersBefore, attemptsBefore := cacheIndexCensus(tr)
					if rng.Intn(4) == 0 {
						counted := removals(cachetracker.RemovalDisconnect)
						tr.InvalidateProviderEvidence(p, cachetracker.RemovalDisconnect, rng.Intn(2) == 0)
						removed := assertCacheInvalidationMatchesCensus(t, tr, where, holdersBefore, attemptsBefore,
							func(providerID, _ string) bool { return providerID == p })
						if got := removals(cachetracker.RemovalDisconnect) - counted; got != uint64(removed) {
							t.Fatalf("%s: disconnect counted %d of %d removals", where, got, removed)
						}
					} else {
						counted := removals(cachetracker.RemovalCapabilityChange)
						tr.InvalidateProviderModels(p, map[string]cachetracker.RemovalReason{m: cachetracker.RemovalCapabilityChange})
						removed := assertCacheInvalidationMatchesCensus(t, tr, where, holdersBefore, attemptsBefore,
							func(providerID, modelID string) bool { return providerID == p && modelID == m })
						if got := removals(cachetracker.RemovalCapabilityChange) - counted; got != uint64(removed) {
							t.Fatalf("%s: capability change counted %d of %d removals", where, got, removed)
						}
					}
				case 10, 11:
					n := fmt.Sprintf("n%d", nonces)
					nonces++
					tr.StoreAttemptLocked(n, indexKernelAttempt{RequestID: n, ProviderID: provider(), Model: model(),
						CreatedAt: now, ExpiresAt: now.Add(indexKernelInFlightAttemptTTL)})
					if tr.config.Attempts.Len() > tr.config.MaxAttempts {
						tr.EnforceAttemptCapLocked()
					}
				case 12:
					tr.MarkAttemptTerminal(nonce(), now)
				case 13:
					tr.RemoveAttemptLocked(nonce())
				case 14:
					n := nonce()
					attempt, live := tr.ActiveAttemptLocked(n, now)
					if live {
						// What the lookup and ready receipts do: record progress at
						// the same expiry.
						attempt.LookupSeen = true
						tr.StoreAttemptLocked(n, attempt)
					}
					if live && !now.Before(attempt.ExpiresAt) {
						t.Fatalf("%s: expired attempt returned live", where)
					}
				case 15:
					holders, attempts := maintenance.StateCounts(now)
					backlog := tr.ContinueSweep(0)
					if backlog {
						t.Fatalf("%s: status counts returned with a sweep backlog", where)
					}
					// No sweep runs inside the interval, so stale entries may be
					// counted; the counts must still be what is stored.
					if h, _, a, _ := tr.indexSizes(); holders != h || attempts != a {
						t.Fatalf("%s: counts %d/%d vs index %d/%d", where, holders, attempts, h, a)
					}
				}
				assertCacheIndexInvariants(t, tr, where)
				added, removed, count := indexKernelMetrics(tr).Added, uint64(0), tr.config.Holders.Len()
				for _, n := range indexKernelMetrics(tr).Removed {
					removed += n
				}
				if added-removed != uint64(count) {
					t.Fatalf("%s: added=%d removed=%d holders=%d", where, added, removed, count)
				}
			}
			// Unbounded expiry must agree with a brute-force census.
			now = now.Add(time.Minute)
			expired := 0
			for _, bucket := range tr.config.Holders.Buckets() {
				for _, h := range bucket.Entries() {
					if !now.Before(h.ExpiresAt) {
						expired++
					}
				}
			}
			removed, _ := tr.ExpireHoldersLocked(now, 1<<30)
			if removed != expired {
				t.Fatalf("heap expired %d, census %d", removed, expired)
			}
			assertCacheIndexInvariants(t, tr, "final")
		})
	}
}

// Receipts, routing, status scrapes, disconnects and capability changes run
// concurrently while a mass expiry drains. Run under -race.
func TestCacheIndexConcurrentTrackerOperations(t *testing.T) {
	var maintenance production.CacheMaintainer
	h := newCacheSizingHarness(t, 25*time.Minute, production.CacheDependencies{
		Maintenance: func(owner production.CacheMaintenance) production.CacheMaintainer {
			maintenance = owner
			return owner
		},
	})
	tracker := h.tracker
	for index := 0; index < 2*indexKernelSweepRemovals+50; index++ {
		h.donate(index)
	}
	h.clock.Advance(26 * time.Minute)
	var wg sync.WaitGroup
	stop := make(chan struct{})
	var stopOnce sync.Once
	stopWorkers := func() {
		stopOnce.Do(func() { close(stop) })
		wg.Wait()
	}
	// A fatal receipt assertion must not leak these workers into later tests
	// (especially testing.AllocsPerRun's process-wide allocation measurement).
	defer stopWorkers()
	concurrentStart := h.clock.Now()
	clockBudget := min(indexKernelAttemptTTL, indexKernelInFlightAttemptTTL) / 4
	const clockSteps = 1000
	run := func(fn func(i int)) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; ; i++ {
				select {
				case <-stop:
					return
				default:
					fn(i)
				}
			}
		}()
	}
	run(func(i int) { h.r.CacheRoutingStateCounts() })
	run(func(i int) { h.r.CacheRoutingLifecycleStatus() })
	run(func(i int) { h.matches(h.plan(i%4000), h.clock.Now()) })
	run(func(i int) {
		maintenance.InvalidateProviderModels("other", map[string]cachetracker.RemovalReason{"model": cachetracker.RemovalCapabilityChange})
	})
	run(func(i int) { maintenance.InvalidateProviderEvidence("another", cachetracker.RemovalDisconnect, false) })
	// The initial 26-minute advance already makes old holders eligible for
	// concurrent expiry. Keep clock writes racing with tracker operations,
	// without making a newly prepared lookup/ready transaction expire merely
	// because this goroutine receives more CPU time than the donating thread.
	run(func(i int) {
		if i < clockSteps {
			h.clock.Advance(clockBudget / clockSteps)
		}
	})
	for index := 10_000; index < 10_600; index++ {
		h.donate(index)
	}
	// Once every lookup/ready transaction is complete, expire the late holders
	// too while the same tracker workers are still active.
	h.clock.Advance(26 * time.Minute)
	h.r.CacheRoutingStateCounts()
	stopWorkers()
	if elapsed := h.clock.Now().Sub(concurrentStart); elapsed > 26*time.Minute+clockBudget {
		t.Fatalf("concurrent clock advanced %s beyond the two-phase expiry budget", elapsed)
	}
	assertCacheIndexInvariants(t, tracker, "concurrent")
	// Both generations of expired holders must balance regardless of how the
	// concurrent sweeps interleave or whether a bounded sweep remains pending.
	holders, _ := h.r.CacheRoutingStateCounts()
	lifecycle := h.r.CacheRoutingLifecycleStatus()
	removed := uint64(0)
	for _, count := range lifecycle.HolderRemoved {
		removed += count
	}
	if lifecycle.HolderAdded-removed != uint64(holders) ||
		lifecycle.HolderRemoved[string(cachetracker.RemovalCapacityEviction)] != 0 {
		t.Fatalf("holders=%d holder_added=%d removed=%+v", holders, lifecycle.HolderAdded, lifecycle.HolderRemoved)
	}
}
