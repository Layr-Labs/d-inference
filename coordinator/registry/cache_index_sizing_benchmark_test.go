package registry

import (
	"fmt"
	"runtime"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Run the two memory benchmarks once each, without the race detector:
//
//	go test -run '^$' -bench 'CacheHolderMemory|CacheDemandMemory' -benchtime 1x ./registry/
//
// They report the settled heap growth of a full index, which is the figure
// the cacheRoutingMaxEntries and cacheDemandMaxEntries comments quote.
func BenchmarkCacheHolderMemory(b *testing.B) {
	for _, kind := range []string{"donated", "hit"} {
		b.Run(fmt.Sprintf("%s/holders=%d", kind, cacheRoutingMaxEntries), func(b *testing.B) {
			for i := 0; i < b.N; i++ {
				h := newCacheSizingHarness(b, cacheRoutingSizingTTL)
				h.forgetAttempts, h.decodedReceipts = true, true
				before := settledHeapBytes()
				for index := 0; index < cacheRoutingMaxEntries; index++ {
					h.receipt(index, kind == "hit")
				}
				after := settledHeapBytes()
				holders, heapEntries, attempts, _ := h.r.cacheRouting.indexSizes()
				if holders != cacheRoutingMaxEntries || heapEntries != holders || attempts != 0 {
					b.Fatalf("holders=%d heap=%d attempts=%d", holders, heapEntries, attempts)
				}
				b.ReportMetric(float64(after-before)/float64(holders), "B/holder")
				b.ReportMetric(float64(after-before)/(1<<20), "MiB/full-index")
				runtime.KeepAlive(h)
			}
		})
	}
}

func BenchmarkCacheDemandMemory(b *testing.B) {
	b.Run(fmt.Sprintf("entries=%d", cacheDemandMaxEntries), func(b *testing.B) {
		for i := 0; i < b.N; i++ {
			tracker := newCacheRoutingTracker(cacheRoutingSizingTTL, defaultCacheRoutingMaxHolders)
			routeKey := []byte("0123456789abcdef0123456789abcdef")
			now := time.Unix(1_700_000_000, 0)
			before := settledHeapBytes()
			for index := 0; index < cacheDemandMaxEntries; index++ {
				plan := exactTestPlan(cacheSizingAnchor(index))
				plan.generation = tracker.generation
				tracker.observeCacheDemand(&plan, routeKey, now)
			}
			after := settledHeapBytes()
			if entries := len(tracker.demand.entries); entries != cacheDemandMaxEntries {
				b.Fatalf("entries=%d", entries)
			}
			b.ReportMetric(float64(after-before)/float64(cacheDemandMaxEntries), "B/entry")
			b.ReportMetric(float64(after-before)/(1<<20), "MiB/full-index")
			runtime.KeepAlive(tracker)
		}
	})
}

// Lookup cost must not depend on how many holders the index keeps: the query
// is one keyed map read per boundary and tier.
func BenchmarkCacheMatchingHolders(b *testing.B) {
	for _, total := range []int{1_000, 10_000, cacheRoutingMaxEntries} {
		b.Run(fmt.Sprintf("holders=%d/boundaries=64/matching=4", total), func(b *testing.B) {
			tracker := newCacheRoutingTracker(cacheRoutingSizingTTL, defaultCacheRoutingMaxHolders)
			routeKey := []byte("0123456789abcdef0123456789abcdef")
			anchors := make([]protocol.PrefixCacheAnchor, 64)
			for i := range anchors {
				anchors[i] = protocol.PrefixCacheAnchor{TokenCount: (i + 1) * 256, ChainHash: fmt.Sprintf("%064x", i+1)}
			}
			plan := exactTestPlan(anchors...)
			plan.generation = tracker.generation
			now := time.Unix(1_700_000_000, 0)
			fillSyntheticHolders(tracker, total-4, now)
			warm := anchors[31]
			tracker.mu.Lock()
			for i := 0; i < 4; i++ {
				tracker.upsertHolderLocked(cacheBoundaryKey(routeKey, plan, warm), cacheHolder{
					ProviderID: fmt.Sprintf("holder-%d", i), ModelID: "model",
					ModelAggregateHash: plan.ModelAggregateHash, PromptContractID: plan.PromptContractID,
					Anchor: warm, StageMs: 120, UpdatedAt: now, ExpiresAt: now.Add(tracker.ttl),
				})
			}
			tracker.mu.Unlock()
			if holders, _, _, _ := tracker.indexSizes(); holders != total {
				b.Fatalf("holders=%d want %d", holders, total)
			}
			query := now.Add(time.Minute)
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				if matches := tracker.matchingHolders(plan, routeKey, CacheRoutingOn, query); len(matches) != 4 {
					b.Fatalf("matches=%d", len(matches))
				}
			}
		})
	}
}

// legacyFullScanSweep is the former sweepLocked holder pass, kept here only as
// the reference arm.
func legacyFullScanSweep(tracker *cacheRoutingTracker, now time.Time) (removed int) {
	for key, holders := range tracker.holders {
		for providerID, holder := range holders {
			if !now.Before(holder.ExpiresAt) {
				tracker.removeHolderLocked(key, providerID, cacheHolderRemovalTTL)
				removed++
			}
		}
	}
	return removed
}

// Each iteration expires exactly ten holders and then restores them, so the
// live set stays at the stated size. The heap arm must cost the same at every
// size; the full scan grows with the index.
func BenchmarkCacheSweepTenExpired(b *testing.B) {
	const expiring = 10
	for _, total := range []int{1_000, 100_000, cacheRoutingMaxEntries} {
		for _, arm := range []string{"full_scan", "expiry_heap"} {
			b.Run(fmt.Sprintf("holders=%d/%s", total, arm), func(b *testing.B) {
				tracker := newCacheRoutingTracker(cacheRoutingSizingTTL, defaultCacheRoutingMaxHolders)
				// Room for the ten on top of a full index; at the cap itself they
				// would be the soonest to expire and so the cap's own victims.
				tracker.maxEntries = total + expiring
				base := time.Unix(1_700_000_000, 0)
				fillSyntheticHolders(tracker, total, base)
				// Resident-shaped: updated after every filler, expiring before all of them.
				short := func() {
					for i := 0; i < expiring; i++ {
						at := base.Add(time.Minute)
						tracker.upsertHolderLocked(fmt.Sprintf("memory:short-%d", i), cacheHolder{
							ProviderID: "resident", UpdatedAt: at, ExpiresAt: at.Add(cacheRoutingMemoryTTL),
						})
					}
				}
				now := base.Add(2 * time.Minute)
				examined := 0
				tracker.mu.Lock()
				defer tracker.mu.Unlock()
				b.ResetTimer()
				for i := 0; i < b.N; i++ {
					b.StopTimer()
					short()
					b.StartTimer()
					removed, looked := 0, 0
					if arm == "full_scan" {
						removed, looked = legacyFullScanSweep(tracker, now), tracker.holderCount+expiring
					} else {
						removed, looked = tracker.expireHoldersLocked(now, cacheRoutingMaxSweepRemovals)
					}
					if removed != expiring {
						b.Fatalf("removed=%d", removed)
					}
					examined += looked
				}
				b.StopTimer()
				if tracker.holderCount != total {
					b.Fatalf("live holders=%d want %d", tracker.holderCount, total)
				}
				b.ReportMetric(float64(examined)/float64(b.N), "examined/op")
			})
		}
	}
}

// The longest single hold a sweep can take: a full budget out of a full,
// wholly expired index. Run with -benchtime 1x.
func BenchmarkCacheSweepMassExpiry(b *testing.B) {
	for i := 0; i < b.N; i++ {
		tracker := newCacheRoutingTracker(cacheRoutingSizingTTL, defaultCacheRoutingMaxHolders)
		base := time.Unix(1_700_000_000, 0)
		fillSyntheticHolders(tracker, cacheRoutingMaxEntries, base)
		now := base.Add(2 * cacheRoutingSizingTTL)
		sweeps, longest, total := 0, time.Duration(0), time.Duration(0)
		tracker.mu.Lock()
		for tracker.holderCount > 0 {
			started := time.Now()
			backlog := tracker.sweepLocked(now)
			held := time.Since(started)
			sweeps++
			total += held
			longest = max(longest, held)
			if !backlog && tracker.holderCount > 0 {
				b.Fatalf("sweep stopped with %d expired holders left", tracker.holderCount)
			}
		}
		tracker.mu.Unlock()
		b.ReportMetric(float64(sweeps), "sweeps")
		b.ReportMetric(float64(longest.Microseconds()), "max-hold-µs")
		b.ReportMetric(float64(total.Microseconds())/float64(sweeps), "mean-hold-µs")
	}
}

// legacyProviderInvalidationWalk is the former invalidateProviderEvidence
// holder and attempt pass, kept here only as the reference arm.
func legacyProviderInvalidationWalk(tracker *cacheRoutingTracker, providerID string, reason cacheHolderRemovalReason) {
	tracker.mu.Lock()
	defer tracker.mu.Unlock()
	for key, holders := range tracker.holders {
		if _, exists := holders[providerID]; exists {
			tracker.removeHolderLocked(key, providerID, reason)
		}
	}
	for nonce, attempt := range tracker.attempts {
		if attempt.ProviderID == providerID {
			tracker.removeAttemptLocked(nonce)
		}
	}
}

// A disconnect must cost what that provider holds, not what the index holds.
// Each iteration restores the provider's 64 holders and 8 attempts with the
// timer stopped, then times one invalidation.
func BenchmarkCacheProviderInvalidationWalk(b *testing.B) {
	const held, attempts = 64, 8
	for _, total := range []int{10_000, cacheRoutingMaxEntries} {
		for _, arm := range []string{"full_walk", "provider_index"} {
			b.Run(fmt.Sprintf("holders=%d/held=%d/%s", total, held, arm), func(b *testing.B) {
				tracker := newCacheRoutingTracker(cacheRoutingSizingTTL, defaultCacheRoutingMaxHolders)
				tracker.maxEntries = total + held
				now := time.Unix(1_700_000_000, 0)
				fillSyntheticHolders(tracker, total, now)
				restore := func() {
					tracker.mu.Lock()
					defer tracker.mu.Unlock()
					for i := 0; i < held; i++ {
						tracker.upsertHolderLocked(fmt.Sprintf("victim-%d", i), cacheHolder{
							ProviderID: "victim", ModelID: "model", UpdatedAt: now, ExpiresAt: now.Add(tracker.ttl),
						})
					}
					for i := 0; i < attempts; i++ {
						tracker.storeAttemptLocked(fmt.Sprintf("victim-%d", i), cacheAttempt{
							ProviderID: "victim", Model: "model", CreatedAt: now,
							ExpiresAt: now.Add(cacheRoutingInFlightAttemptTTL),
						})
					}
				}
				b.ResetTimer()
				for i := 0; i < b.N; i++ {
					b.StopTimer()
					restore()
					b.StartTimer()
					if arm == "full_walk" {
						legacyProviderInvalidationWalk(tracker, "victim", cacheHolderRemovalDisconnect)
					} else {
						tracker.disconnect("victim", cacheHolderRemovalDisconnect)
					}
				}
				b.StopTimer()
				if holders, _, left, _ := tracker.indexSizes(); holders != total || left != 0 {
					b.Fatalf("holders=%d attempts=%d after invalidation, want %d/0", holders, left, total)
				}
			})
		}
	}
}

// What the per-provider holder index adds to a full holder index spread over
// 512 providers: the settled heap released by dropping the index alone. Run
// with -benchtime 1x, without the race detector.
func BenchmarkCacheProviderIndexMemory(b *testing.B) {
	for i := 0; i < b.N; i++ {
		tracker := newCacheRoutingTracker(cacheRoutingSizingTTL, defaultCacheRoutingMaxHolders)
		fillSyntheticHolders(tracker, cacheRoutingMaxEntries, time.Unix(1_700_000_000, 0))
		with := settledHeapBytes()
		tracker.mu.Lock()
		providers := len(tracker.holdersByProvider)
		tracker.holdersByProvider = nil
		tracker.mu.Unlock()
		without := settledHeapBytes()
		b.ReportMetric(float64(providers), "providers")
		b.ReportMetric(float64(with-without)/float64(cacheRoutingMaxEntries), "B/holder")
		b.ReportMetric(float64(with-without)/(1<<20), "MiB/full-index")
		runtime.KeepAlive(tracker)
	}
}
