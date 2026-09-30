package registry

import (
	"fmt"
	"math/rand"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// assertCacheIndexInvariants checks the whole tracker bookkeeping: bucket
// maps, holder count, both expiry heaps with their by-key indexes, and both
// per-provider indexes. Caller holds no lock.
func assertCacheIndexInvariants(t *testing.T, tr *cacheRoutingTracker, where string) {
	t.Helper()
	tr.mu.Lock()
	defer tr.mu.Unlock()
	total := 0
	for key, bucket := range tr.holders {
		if len(bucket) == 0 {
			t.Fatalf("%s: empty bucket %q retained", where, key)
		}
		if len(bucket) > tr.maxHolders {
			t.Fatalf("%s: bucket %q has %d > %d", where, key, len(bucket), tr.maxHolders)
		}
		for pid, holder := range bucket {
			total++
			entry := tr.holderOrderByRef[cacheHolderRef{key: key, providerID: pid}]
			if entry == nil {
				t.Fatalf("%s: holder %q/%q has no heap entry", where, key, pid)
			}
			if !entry.expiresAt.Equal(holder.ExpiresAt) {
				t.Fatalf("%s: holder %q/%q heap key %s != expiry %s", where, key, pid, entry.expiresAt, holder.ExpiresAt)
			}
			if _, indexed := tr.holdersByProvider[pid][entry]; !indexed {
				t.Fatalf("%s: holder %q/%q missing from its provider index", where, key, pid)
			}
		}
	}
	if total != tr.holderCount || len(tr.holderOrder) != total || len(tr.holderOrderByRef) != total {
		t.Fatalf("%s: holders=%d holderCount=%d heap=%d byRef=%d", where, total, tr.holderCount, len(tr.holderOrder), len(tr.holderOrderByRef))
	}
	if total > tr.maxEntries {
		t.Fatalf("%s: holders=%d over cap %d", where, total, tr.maxEntries)
	}
	for i, entry := range tr.holderOrder {
		if entry.index != i {
			t.Fatalf("%s: holder heap[%d].index=%d", where, i, entry.index)
		}
		if tr.holderOrderByRef[entry.ref] != entry {
			t.Fatalf("%s: holder heap[%d] not the indexed entry", where, i)
		}
		if _, ok := tr.holders[entry.ref.key][entry.ref.providerID]; !ok {
			t.Fatalf("%s: leaked holder heap entry %+v", where, entry.ref)
		}
		if i > 0 && tr.holderOrder.Less(i, (i-1)/2) {
			t.Fatalf("%s: holder heap property broken at %d", where, i)
		}
	}
	indexed := 0
	for pid, set := range tr.holdersByProvider {
		if len(set) == 0 {
			t.Fatalf("%s: empty holder index retained for provider %q", where, pid)
		}
		for entry := range set {
			indexed++
			if entry.ref.providerID != pid {
				t.Fatalf("%s: provider %q indexes holder %+v", where, pid, entry.ref)
			}
			if tr.holderOrderByRef[entry.ref] != entry {
				t.Fatalf("%s: provider %q indexes a leaked holder entry %+v", where, pid, entry.ref)
			}
		}
	}
	if indexed != total {
		t.Fatalf("%s: provider index holds %d holders, index %d", where, indexed, total)
	}

	if len(tr.attemptOrder) != len(tr.attempts) || len(tr.attemptOrderByNonce) != len(tr.attempts) {
		t.Fatalf("%s: attempts=%d heap=%d byNonce=%d", where, len(tr.attempts), len(tr.attemptOrder), len(tr.attemptOrderByNonce))
	}
	if len(tr.attempts) > tr.maxAttempts {
		t.Fatalf("%s: attempts=%d over cap %d", where, len(tr.attempts), tr.maxAttempts)
	}
	for i, entry := range tr.attemptOrder {
		if entry.index != i {
			t.Fatalf("%s: attempt heap[%d].index=%d", where, i, entry.index)
		}
		attempt, ok := tr.attempts[entry.nonce]
		if !ok {
			t.Fatalf("%s: leaked attempt heap entry %q", where, entry.nonce)
		}
		if !entry.expiresAt.Equal(attempt.ExpiresAt) {
			t.Fatalf("%s: attempt %q heap key %s != expiry %s", where, entry.nonce, entry.expiresAt, attempt.ExpiresAt)
		}
		if entry.providerID != attempt.ProviderID {
			t.Fatalf("%s: attempt %q indexed under %q, belongs to %q", where, entry.nonce, entry.providerID, attempt.ProviderID)
		}
		if tr.attemptOrderByNonce[entry.nonce] != entry {
			t.Fatalf("%s: attempt heap[%d] not the indexed entry", where, i)
		}
		if _, indexed := tr.attemptsByProvider[entry.providerID][entry]; !indexed {
			t.Fatalf("%s: attempt %q missing from its provider index", where, entry.nonce)
		}
		if i > 0 && tr.attemptOrder.Less(i, (i-1)/2) {
			t.Fatalf("%s: attempt heap property broken at %d", where, i)
		}
	}
	indexed = 0
	for pid, set := range tr.attemptsByProvider {
		if len(set) == 0 {
			t.Fatalf("%s: empty attempt index retained for provider %q", where, pid)
		}
		for entry := range set {
			indexed++
			if entry.providerID != pid || tr.attemptOrderByNonce[entry.nonce] != entry {
				t.Fatalf("%s: provider %q indexes a leaked attempt entry %q", where, pid, entry.nonce)
			}
		}
	}
	if indexed != len(tr.attempts) {
		t.Fatalf("%s: provider index holds %d attempts, index %d", where, indexed, len(tr.attempts))
	}
}

// cacheIndexCensus is the brute-force view: every holder with its model and
// every attempt with its provider and model, read from the primary maps only.
func cacheIndexCensus(tr *cacheRoutingTracker) (map[cacheHolderRef]string, map[string][2]string) {
	tr.mu.Lock()
	defer tr.mu.Unlock()
	holders := make(map[cacheHolderRef]string)
	for key, bucket := range tr.holders {
		for pid, holder := range bucket {
			holders[cacheHolderRef{key: key, providerID: pid}] = holder.ModelID
		}
	}
	attempts := make(map[string][2]string, len(tr.attempts))
	for nonce, attempt := range tr.attempts {
		attempts[nonce] = [2]string{attempt.ProviderID, attempt.Model}
	}
	return holders, attempts
}

// assertCacheInvalidationMatchesCensus compares an index-driven invalidation
// with the full walk it replaced: exactly the entries doomed by the predicate
// are gone and nothing else moved.
func assertCacheInvalidationMatchesCensus(
	t *testing.T, tr *cacheRoutingTracker, where string,
	holdersBefore map[cacheHolderRef]string, attemptsBefore map[string][2]string,
	doomed func(providerID, modelID string) bool,
) (removedHolders int) {
	t.Helper()
	holdersAfter, attemptsAfter := cacheIndexCensus(tr)
	for ref, model := range holdersBefore {
		_, kept := holdersAfter[ref]
		if kept == doomed(ref.providerID, model) {
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
			tr := newCacheRoutingTracker(10*time.Minute, 3)
			tr.maxEntries, tr.maxAttempts = 40, 12
			now := time.Unix(1_700_000_000, 0)
			reasons := []cacheHolderRemovalReason{
				cacheHolderRemovalTTL, cacheHolderRemovalDisconnect, cacheHolderRemovalEpochChange,
				cacheHolderRemovalCapabilityChange, cacheHolderRemovalProofMismatch,
				cacheHolderRemovalMissInvalidation, cacheHolderRemovalCapacityEviction, cacheHolderRemovalShorterHit,
			}
			key := func() string {
				tier := "ssd"
				if rng.Intn(3) == 0 {
					tier = "memory"
				}
				return cacheTierKey(fmt.Sprintf("k%02d", rng.Intn(30)), tier)
			}
			tierOf := func(k string) string {
				if len(k) > 7 && k[:7] == "memory:" {
					return "memory"
				}
				return "ssd"
			}
			provider := func() string { return fmt.Sprintf("p%d", rng.Intn(6)) }
			model := func() string { return fmt.Sprintf("m%d", rng.Intn(3)) }
			removals := func(reason cacheHolderRemovalReason) uint64 {
				tr.mu.Lock()
				defer tr.mu.Unlock()
				return tr.holderRemoved[string(reason)]
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
					holder := cacheHolder{ProviderID: p, ModelID: model(), UpdatedAt: now, ExpiresAt: now.Add(tr.receiptTTL(tierOf(k)))}
					tr.mu.Lock()
					if rng.Intn(2) == 0 {
						tr.preserveStageMeasurementLocked(k, &holder, protocol.PrefixCacheV2Capability{}, now)
					}
					// Brute-force the global cap's victim when only the global cap can fire.
					_, exists := tr.holders[k][p]
					checkVictim := !exists && tr.holderCount == tr.maxEntries && len(tr.holders[k]) < tr.maxHolders
					var victim cacheHolderRef
					var victimExpiry time.Time
					if checkVictim {
						victim, victimExpiry = cacheHolderRef{key: k, providerID: p}, holder.ExpiresAt
						for bk, bucket := range tr.holders {
							for bp, h := range bucket {
								ref := cacheHolderRef{key: bk, providerID: bp}
								if h.ExpiresAt.Before(victimExpiry) || (h.ExpiresAt.Equal(victimExpiry) &&
									(ref.key < victim.key || (ref.key == victim.key && ref.providerID < victim.providerID))) {
									victim, victimExpiry = ref, h.ExpiresAt
								}
							}
						}
					}
					tr.upsertHolderLocked(k, holder)
					if checkVictim {
						if _, still := tr.holders[victim.key][victim.providerID]; still {
							tr.mu.Unlock()
							t.Fatalf("%s: cap did not evict the soonest-expiring holder %+v", where, victim)
						}
					}
					tr.mu.Unlock()
				case 4:
					tr.mu.Lock()
					tr.removeHolderLocked(key(), provider(), reasons[rng.Intn(len(reasons))])
					tr.mu.Unlock()
				case 5:
					now = now.Add(time.Duration(rng.Intn(45_000)) * time.Millisecond)
					if rng.Intn(20) == 0 {
						now = now.Add(time.Duration(rng.Intn(12)) * time.Minute)
					}
				case 6:
					tr.mu.Lock()
					tr.sweepIfDueLocked(now)
					tr.mu.Unlock()
				case 7:
					tr.mu.Lock()
					tr.expireHoldersLocked(now, 1+rng.Intn(3))
					tr.expireAttemptsLocked(now, 1+rng.Intn(3))
					tr.mu.Unlock()
				case 8:
					k, p := key(), provider()
					tr.mu.Lock()
					holder, live := tr.activeHolderLocked(k, p, now)
					tr.mu.Unlock()
					if live && !now.Before(holder.ExpiresAt) {
						t.Fatalf("%s: expired holder returned live", where)
					}
				case 9:
					p, m := provider(), model()
					holdersBefore, attemptsBefore := cacheIndexCensus(tr)
					if rng.Intn(4) == 0 {
						counted := removals(cacheHolderRemovalDisconnect)
						tr.invalidateProviderEvidence(p, cacheHolderRemovalDisconnect, rng.Intn(2) == 0)
						removed := assertCacheInvalidationMatchesCensus(t, tr, where, holdersBefore, attemptsBefore,
							func(providerID, _ string) bool { return providerID == p })
						if got := removals(cacheHolderRemovalDisconnect) - counted; got != uint64(removed) {
							t.Fatalf("%s: disconnect counted %d of %d removals", where, got, removed)
						}
					} else {
						counted := removals(cacheHolderRemovalCapabilityChange)
						tr.invalidateProviderModels(p, map[string]cacheHolderRemovalReason{m: cacheHolderRemovalCapabilityChange})
						removed := assertCacheInvalidationMatchesCensus(t, tr, where, holdersBefore, attemptsBefore,
							func(providerID, modelID string) bool { return providerID == p && modelID == m })
						if got := removals(cacheHolderRemovalCapabilityChange) - counted; got != uint64(removed) {
							t.Fatalf("%s: capability change counted %d of %d removals", where, got, removed)
						}
					}
				case 10, 11:
					n := fmt.Sprintf("n%d", nonces)
					nonces++
					tr.mu.Lock()
					tr.storeAttemptLocked(n, cacheAttempt{RequestID: n, ProviderID: provider(), Model: model(),
						CreatedAt: now, ExpiresAt: now.Add(cacheRoutingInFlightAttemptTTL)})
					if len(tr.attempts) > tr.maxAttempts {
						tr.enforceAttemptCapLocked()
					}
					tr.mu.Unlock()
				case 12:
					tr.markAttemptTerminal(nonce(), now)
				case 13:
					tr.forgetAttempt(nonce())
				case 14:
					n := nonce()
					tr.mu.Lock()
					attempt, live := tr.activeAttemptLocked(n, now)
					if live {
						// What the lookup and ready receipts do: record progress at
						// the same expiry.
						attempt.LookupSeen = true
						tr.storeAttemptLocked(n, attempt)
					}
					tr.mu.Unlock()
					if live && !now.Before(attempt.ExpiresAt) {
						t.Fatalf("%s: expired attempt returned live", where)
					}
				case 15:
					holders, attempts := tr.stateCounts(now)
					tr.mu.Lock()
					backlog := tr.sweepBacklog
					tr.mu.Unlock()
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
				tr.mu.Lock()
				added, removed, count := tr.holderAdded, uint64(0), tr.holderCount
				for _, n := range tr.holderRemoved {
					removed += n
				}
				tr.mu.Unlock()
				if added-removed != uint64(count) {
					t.Fatalf("%s: added=%d removed=%d holders=%d", where, added, removed, count)
				}
			}
			// Unbounded expiry must agree with a brute-force census.
			now = now.Add(time.Minute)
			tr.mu.Lock()
			expired := 0
			for _, bucket := range tr.holders {
				for _, h := range bucket {
					if !now.Before(h.ExpiresAt) {
						expired++
					}
				}
			}
			removed, _ := tr.expireHoldersLocked(now, 1<<30)
			tr.mu.Unlock()
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
	h := newCacheSizingHarness(t, 25*time.Minute)
	tracker := h.r.cacheRouting
	for index := 0; index < 2*cacheRoutingMaxSweepRemovals+50; index++ {
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
	clockBudget := min(cacheRoutingAttemptTTL, cacheRoutingInFlightAttemptTTL) / 4
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
	run(func(i int) { tracker.invalidateProviderModel("other", "model", cacheHolderRemovalCapabilityChange) })
	run(func(i int) { tracker.disconnect("another", cacheHolderRemovalDisconnect) })
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
		lifecycle.HolderRemoved[string(cacheHolderRemovalCapacityEviction)] != 0 {
		t.Fatalf("holders=%d holder_added=%d removed=%+v", holders, lifecycle.HolderAdded, lifecycle.HolderRemoved)
	}
}
