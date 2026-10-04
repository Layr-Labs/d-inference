package registry_test

import (
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachedemand"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachetracker"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// The production shape the caps are sized for: 30 unique holders a second,
// each living a 25-minute TTL. Under the former 10,000-entry cap the index
// turned over in under six minutes; every holder must now live its whole TTL.
func TestCacheHoldersSurviveOperatorTTLAtFleetRate(t *testing.T) {
	const ratePerSecond = 30
	ttl := 25 * time.Minute
	total := ratePerSecond * int(ttl/time.Second)
	h := newCacheSizingHarness(t, ttl)
	start := h.clock.Now()
	first := h.donate(0)
	for index := 1; index < total; index++ {
		h.clock.Advance(time.Second / ratePerSecond)
		h.donate(index)
	}
	now := h.clock.Now()
	if !now.Before(start.Add(ttl)) {
		t.Fatalf("fill ran to %s, past the first holder's TTL", now.Sub(start))
	}

	lifecycle := h.r.CacheRoutingLifecycleStatus()
	if lifecycle.HolderAdded != uint64(total) {
		t.Fatalf("holder_added=%d want %d", lifecycle.HolderAdded, total)
	}
	for reason, count := range lifecycle.HolderRemoved {
		if count != 0 {
			t.Fatalf("%d holders removed for %q inside the TTL: %+v", count, reason, lifecycle.HolderRemoved)
		}
	}
	holders, attempts := h.r.CacheRoutingStateCounts()
	if holders != total {
		t.Fatalf("holders=%d want %d", holders, total)
	}
	// Terminal attempts leave after their own two-minute TTL, at most one
	// sweep interval late.
	maxAttempts := ratePerSecond * int((cachetracker.AttemptTTL+cachetracker.SweepInterval)/time.Second)
	if attempts == 0 || attempts > maxAttempts+ratePerSecond {
		t.Fatalf("attempts=%d, want 1..%d", attempts, maxAttempts+ratePerSecond)
	}
	if matches := h.matches(first, now); len(matches) != 1 {
		t.Fatalf("oldest holder unavailable %s into a %s TTL: %+v", now.Sub(start), ttl, matches)
	}

	expiry := start.Add(ttl)
	if matches := h.matches(first, expiry.Add(-time.Nanosecond)); len(matches) != 1 {
		t.Fatal("holder lapsed before its TTL")
	}
	if matches := h.matches(first, expiry); len(matches) != 0 {
		t.Fatalf("holder outlived its TTL: %+v", matches)
	}
	if h.removed(cachetracker.RemovalTTL) == 0 || h.removed(cachetracker.RemovalCapacityEviction) != 0 {
		t.Fatalf("expiry not attributed to ttl: %+v", h.r.CacheRoutingLifecycleStatus().HolderRemoved)
	}
}

// After a traffic lull longer than the TTL the whole index is stale. It must
// drain in bounded passes, and a stale holder that a pass has not reached yet
// must never be returned.
func TestCacheMassExpiryDrainsInBoundedSweeps(t *testing.T) {
	const total = 3*cachetracker.MaxSweepRemovals + 100
	ttl := 25 * time.Minute
	h := newCacheSizingHarness(t, ttl)
	plans := make([]production.CachePlan, total)
	for index := range plans {
		plans[index] = h.donate(index)
	}
	tracker := h.tracker
	if holders, _, attempts, _ := tracker.indexSizes(); holders != total || attempts != total {
		t.Fatalf("seeded holders=%d attempts=%d", holders, attempts)
	}
	if len(h.matches(plans[total-1], h.clock.Now())) != 1 {
		t.Fatal("seeded holder unavailable")
	}

	h.clock.Advance(ttl + time.Minute)
	now := h.clock.Now()
	sweeps := 0
	for remaining := total; remaining > 0; sweeps++ {
		if sweeps > total/cachetracker.MaxSweepRemovals+1 {
			t.Fatalf("index not drained after %d sweeps: %d holders left", sweeps, remaining)
		}
		// Query from the back of the expiry order: the holder this pass reaches last.
		plan := plans[total-1-sweeps]
		if matches := h.matches(plan, now); len(matches) != 0 {
			t.Fatalf("sweep %d returned an expired holder: %+v", sweeps, matches)
		}
		holders, heap, attempts, attemptHeap := tracker.indexSizes()
		if heap != holders || attemptHeap != attempts {
			t.Fatalf("index drift: holders=%d heap=%d attempts=%d heap=%d", holders, heap, attempts, attemptHeap)
		}
		// One budget from the sweep plus the queried holder, which the lookup
		// itself expires when the sweep has not reached it.
		if drained := remaining - holders; drained > cachetracker.MaxSweepRemovals+1 {
			t.Fatalf("sweep %d removed %d holders under the lock, budget %d", sweeps, drained, cachetracker.MaxSweepRemovals)
		} else if holders > 0 && drained < cachetracker.MaxSweepRemovals {
			t.Fatalf("sweep %d stopped at %d removals with %d expired holders left", sweeps, drained, holders)
		}
		remaining = holders
	}
	if sweeps != total/cachetracker.MaxSweepRemovals+1 {
		t.Fatalf("drained in %d sweeps, want %d", sweeps, total/cachetracker.MaxSweepRemovals+1)
	}
	if _, _, attempts, _ := tracker.indexSizes(); attempts != 0 {
		t.Fatalf("%d expired attempts survived the drain", attempts)
	}
	lifecycle := h.r.CacheRoutingLifecycleStatus()
	if lifecycle.HolderRemoved[string(cachetracker.RemovalTTL)] != total ||
		lifecycle.HolderRemoved[string(cachetracker.RemovalCapacityEviction)] != 0 {
		t.Fatalf("mass expiry attribution: %+v", lifecycle.HolderRemoved)
	}
	// The index serves fresh evidence again.
	fresh := h.donate(total)
	if len(h.matches(fresh, h.clock.Now())) != 1 {
		t.Fatal("fresh holder unavailable after the drain")
	}
}

// The status counts settle expiry before they count, in bounded passes.
func TestCacheStateCountsSettleMassExpiry(t *testing.T) {
	const total = 2*cachetracker.MaxSweepRemovals + 7
	ttl := 25 * time.Minute
	h := newCacheSizingHarness(t, ttl)
	for index := 0; index < total; index++ {
		h.donate(index)
	}
	if holders, attempts := h.r.CacheRoutingStateCounts(); holders != total || attempts != total {
		t.Fatalf("holders=%d attempts=%d want %d", holders, attempts, total)
	}
	h.clock.Advance(ttl + time.Minute)
	if holders, attempts := h.r.CacheRoutingStateCounts(); holders != 0 || attempts != 0 {
		t.Fatalf("status counted expired entries: holders=%d attempts=%d", holders, attempts)
	}
	if got := h.removed(cachetracker.RemovalTTL); got != total {
		t.Fatalf("ttl removals=%d want %d", got, total)
	}
}

// A hit renews the holder. Sweeps at the original deadline must leave it, and
// the sweep at the renewed deadline must take it.
func TestCacheHolderRefreshMovesItsExpiry(t *testing.T) {
	ttl := 25 * time.Minute
	h := newCacheSizingHarness(t, ttl)
	start := h.clock.Now()
	plan := h.donate(0)
	neighbour := h.donate(1)

	h.clock.Advance(20 * time.Minute)
	h.hit(0)
	renewed := h.clock.Now().Add(ttl)

	h.clock.Advance(5*time.Minute + time.Second) // past the original deadline
	now := h.clock.Now()
	if !now.After(start.Add(ttl)) {
		t.Fatal("clock did not pass the original deadline")
	}
	if holders, _ := h.r.CacheRoutingStateCounts(); holders != 1 {
		t.Fatalf("holders=%d, want only the renewed one", holders)
	}
	if len(h.matches(neighbour, now)) != 0 {
		t.Fatal("holder that was never renewed survived its TTL")
	}
	matches := h.matches(plan, now)
	if len(matches) != 1 || !matches[0].Holder.ExpiresAt.Equal(renewed) {
		t.Fatalf("renewed holder lost or not re-dated: %+v", matches)
	}

	h.clock.Advance(renewed.Sub(now))
	if holders, _ := h.r.CacheRoutingStateCounts(); holders != 0 {
		t.Fatalf("holders=%d after the renewed deadline", holders)
	}
	if len(h.matches(plan, h.clock.Now())) != 0 {
		t.Fatal("renewed holder outlived its renewed TTL")
	}
	if got := h.removed(cachetracker.RemovalTTL); got != 2 {
		t.Fatalf("ttl removals=%d want 2", got)
	}
}

func TestCacheIndexCapsCoverSizingTTL(t *testing.T) {
	h := newCacheSizingHarness(t, cachedemand.SizingTTL)
	seconds := int(cachedemand.SizingTTL / time.Second)
	if h.tracker.config.MaxEntries < 4*30*seconds {
		t.Fatalf("holder cap %d lacks 4x headroom over 30 holders/s for %s", h.tracker.config.MaxEntries, cachedemand.SizingTTL)
	}
	// The demand cap's sizing is held by TestCacheDemandCapCoversMeasuredPlanMix.
	if h.tracker.config.MaxEntries != indexKernelMaxEntries || h.demandLimit != cachedemand.MaxEntries ||
		h.demandTTL != cachedemand.SizingTTL {
		t.Fatalf("tracker caps: holders=%d demand=%d ttl=%s", h.tracker.config.MaxEntries, h.demandLimit, h.demandTTL)
	}
}

// Known cost of evicting the soonest expiry at the attempt cap: the terminal
// attempt, which waits only for its write-behind receipt, goes before older
// in-flight ones, so its late ready is refused. The refusal is an ordinary
// missing attempt: no mismatch, no fence, no holder.
func TestCacheAttemptCapRefusesLateReceiptOfTerminalAttempt(t *testing.T) {
	h := newCacheSizingHarness(t, 25*time.Minute, production.CacheDependencies{MaxAttempts: 3})
	tracker := h.tracker
	prepare := func(index int) (*production.PendingRequest, string) {
		pr := &production.PendingRequest{RequestID: fmt.Sprintf("request-%d", index), Model: "model", CachePlan: h.plan(index)}
		if err := h.r.PrepareCacheAttempt(pr, h.provider); err != nil {
			t.Fatal(err)
		}
		return pr, pr.CacheAttemptSnapshot().MetadataMessage().CacheReceiptNonce
	}

	_, longA := prepare(0)
	h.clock.Advance(time.Second)
	_, longB := prepare(1)
	h.clock.Advance(time.Second)
	finished, terminal := prepare(2)
	h.seq++
	lookup := fenceTestV2Lookup(terminal, h.capability, h.plan(2).Boundaries[0], h.seq)
	lookup.RequestID = finished.RequestID
	if result := h.r.ApplyPrefixCacheLookupV2Result(h.provider.ID, sizingWireCopy(t, lookup)); !result.Accepted {
		t.Fatalf("lookup: %s", result.Reason)
	}
	h.r.MarkCacheAttemptTerminal(finished) // response done, SSD write-behind pending
	h.clock.Advance(time.Second)
	_, fresh := prepare(3) // over the cap

	h.seq++
	ready := fenceTestV2Ready(terminal, h.capability, h.plan(2).Boundaries[0], h.seq)
	ready.RequestID = finished.RequestID
	late := h.r.ApplyPrefixCacheReadyV2Result(h.provider.ID, sizingWireCopy(t, ready))
	mismatch := cacheReceiptMismatch(late)
	if late.Accepted || late.Reason != production.CacheReceiptAttemptUnavailable || mismatch {
		t.Fatalf("late ready: accepted=%v reason=%s mismatch=%v", late.Accepted, late.Reason, mismatch)
	}
	for name, nonce := range map[string]string{"longA": longA, "longB": longB, "fresh": fresh} {
		if _, held := tracker.config.Attempts.Load(nonce); !held {
			t.Fatalf("in-flight attempt %s was evicted before the terminal one", name)
		}
	}
	lifecycle := h.r.CacheRoutingLifecycleStatus()
	if lifecycle.FencesApplied != 0 || lifecycle.HolderAdded != 0 {
		t.Fatalf("refused receipt had side effects: %+v", lifecycle)
	}
	assertCacheIndexInvariants(t, tracker, "attempt cap")
}

// After a lull the backlog re-arms the sweep for exactly as many tracker
// operations as the drain takes; the interval gate then returns.
func TestCacheSweepRearmStopsAfterDrain(t *testing.T) {
	const total = 3*cachetracker.MaxSweepRemovals + 100
	const passes = total/cachetracker.MaxSweepRemovals + 1
	h := newCacheSizingHarness(t, 25*time.Minute)
	for index := 0; index < total; index++ {
		h.donate(index)
	}
	h.clock.Advance(26 * time.Minute)
	tracker := h.tracker
	probe := h.plan(total + 1) // matches nothing, so only the sweep removes
	read := func() (removed uint64, backlog bool) {
		return indexKernelMetrics(tracker).Removed[string(cachetracker.RemovalTTL)], tracker.ContinueSweep(0)
	}
	for op := 0; op < passes+6; op++ {
		before, _ := read()
		h.clock.Advance(time.Millisecond)
		h.matches(probe, h.clock.Now())
		after, backlog := read()
		removed := int(after - before)
		switch {
		case op < passes-1:
			if removed != cachetracker.MaxSweepRemovals || !backlog {
				t.Fatalf("op %d removed %d backlog=%v, want a full budget and a backlog", op, removed, backlog)
			}
		case op == passes-1:
			if removed != total%cachetracker.MaxSweepRemovals || backlog {
				t.Fatalf("op %d removed %d backlog=%v, want the remainder and no backlog", op, removed, backlog)
			}
		default:
			if removed != 0 || backlog {
				t.Fatalf("op %d removed %d backlog=%v after the drain", op, removed, backlog)
			}
		}
	}
	if holders, _, attempts, _ := tracker.indexSizes(); holders != 0 || attempts != 0 {
		t.Fatalf("left holders=%d attempts=%d", holders, attempts)
	}
	// Inside the interval a newly expired holder waits for the next sweep.
	fresh := h.donate(total + 2)
	h.clock.Advance(cachetracker.SweepInterval - time.Second)
	h.matches(probe, h.clock.Now())
	if holders, _, _, _ := tracker.indexSizes(); holders != 1 || len(h.matches(fresh, h.clock.Now())) != 1 {
		t.Fatalf("holders=%d inside the sweep interval", holders)
	}
	assertCacheIndexInvariants(t, tracker, "after drain")
}
