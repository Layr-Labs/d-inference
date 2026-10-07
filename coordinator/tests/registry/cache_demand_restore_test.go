package registry_test

import (
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachedemand"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachehistory"
	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

// The demand index reports which restored entries it accepted; only those
// count as already persisted, so a key the index rejected (at the TTL edge
// here) is written again on its next observation.
func TestCacheDemandRestoreReportsAcceptedEntries(t *testing.T) {
	d := newDemandFixture(8, time.Minute)
	now := time.Now()
	ttl := time.Minute
	accepted := d.tracker.Restore([]crs.DemandRecord{
		{Key: "fresh", SeenAt: now.Add(-time.Second)},
		{Key: "edge", SeenAt: now.Add(-ttl)},
		{Key: "future", SeenAt: now.Add(time.Second)},
		{Key: "", SeenAt: now},
	}, now)
	if len(accepted) != 1 || accepted[0].Key != "fresh" {
		t.Fatalf("only the entry inside the window is accepted: %+v", accepted)
	}
	entries, _ := d.tracker.Stats()
	if entries != 1 {
		t.Fatalf("index holds %d entries, want 1", entries)
	}
}

// A restore retried after traffic has populated the demand index merges by
// seen time: a capped merge evicts the oldest entries across both sets,
// never a fresher live observation to keep an older durable one.
func TestCacheDemandRestoreMergesBySeenTimeUnderTheCap(t *testing.T) {
	d := newDemandFixture(4, time.Minute)
	now := time.Now()
	// Live observations from this process, the freshest evidence there is.
	for i, key := range []string{"live-1", "live-2"} {
		d.tracker.Restore([]crs.DemandRecord{{Key: key, SeenAt: now.Add(-time.Duration(i) * time.Second)}}, now)
	}
	// The durable copy holds more older entries than the cap can keep.
	accepted := d.tracker.Restore([]crs.DemandRecord{
		{Key: "old-1", SeenAt: now.Add(-40 * time.Second)},
		{Key: "old-2", SeenAt: now.Add(-30 * time.Second)},
		{Key: "old-3", SeenAt: now.Add(-20 * time.Second)},
		{Key: "old-4", SeenAt: now.Add(-10 * time.Second)},
	}, now)
	if len(accepted) != 2 || accepted[0].Key != "old-3" || accepted[1].Key != "old-4" {
		t.Fatalf("only the entries the cap kept count as persisted: %+v", accepted)
	}
	if entries, _ := d.tracker.Stats(); entries != 4 {
		t.Fatalf("index holds %d entries, want the cap of 4", entries)
	}
	var order []string
	view := d.index.Snapshot()
	for i := 0; i < len(view); i++ {
		order = append(order, view[i].Key)
	}
	if want := []string{"old-3", "old-4", "live-2", "live-1"}; fmt.Sprint(order) != fmt.Sprint(want) {
		t.Fatalf("capped merge must keep the newest entries in seen order: got %v want %v", order, want)
	}
	// The live list can be out of timestamp order (clocks are sampled before
	// the lock): a delayed older observation behind a newer one. The merge
	// still keeps the newest entries, not the tail of the list.
	d.tracker.Clear()
	for _, e := range []cachehistory.Entry{{Key: "live-new", Seen: now}, {Key: "live-delayed", Seen: now.Add(-25 * time.Second)}} {
		d.tracker.Observe([]cachedemand.Boundary{{Key: e.Key, Tokens: 256}}, e.Seen)
	}
	d.tracker.Restore([]crs.DemandRecord{
		{Key: "mid-1", SeenAt: now.Add(-15 * time.Second)},
		{Key: "mid-2", SeenAt: now.Add(-10 * time.Second)},
		{Key: "mid-3", SeenAt: now.Add(-5 * time.Second)},
	}, now)
	order = order[:0]
	view = d.index.Snapshot()
	for i := 0; i < len(view); i++ {
		order = append(order, view[i].Key)
	}
	if want := []string{"mid-1", "mid-2", "mid-3", "live-new"}; fmt.Sprint(order) != fmt.Sprint(want) {
		t.Fatalf("merge over an unsorted live list must keep the newest entries: got %v want %v", order, want)
	}
	// An entry older than everything kept never displaces fresher ones.
	d.tracker.Restore([]crs.DemandRecord{{Key: "old-1", SeenAt: now.Add(-40 * time.Second)}}, now)
	entries := d.index.Len()
	first, _ := d.index.Front()
	front := first.Key
	if entries != 4 || front == "old-1" {
		t.Fatalf("re-restore of an older entry must not displace fresher ones: entries=%d front=%s", entries, front)
	}
}

// The cap can only meet an expired head when the bounded sweep left expired
// entries behind, which takes more than cachedemand.MaxExpiryPerObserve of
// them. Those removals are expiries and must not count as cap evictions.
func TestCacheDemandCapEvictionCounterSkipsUnsweptExpiries(t *testing.T) {
	const stale = cachedemand.MaxExpiryPerObserve + 6
	d := newDemandFixture(stale, time.Minute)
	start := time.Unix(1_700_000_000, 0)
	for i := 0; i < stale; i++ {
		d.tracker.Observe([]cachedemand.Boundary{{Key: fmt.Sprintf("stale/%d", i), Tokens: 1_024}}, start)
	}
	// Shrink the cap under a wholly stale index: the sweep clears its budget,
	// the cap then removes the six expired entries left and, once only live
	// entries remain, two of the five just recorded.
	shrunk := newDemandFixture(3, time.Minute)
	shrunk.index.Reset(d.index.Snapshot())
	d = shrunk
	fresh := make([]cachedemand.Boundary, 5)
	for i := range fresh {
		fresh[i] = cachedemand.Boundary{Key: fmt.Sprintf("fresh/%d", i), Tokens: (i + 1) * 1_024}
	}
	d.tracker.Observe(fresh, start.Add(time.Minute+time.Second))
	entries, evictions := d.tracker.Stats()
	if entries != 3 || evictions != 2 {
		t.Fatalf("entries=%d cap evictions=%d, want 3 and 2 (six expired heads are expiries)", entries, evictions)
	}
	for _, key := range []string{"fresh/2", "fresh/3", "fresh/4"} {
		if _, ok := d.index.Load(key); !ok {
			t.Fatalf("live entry %q lost", key)
		}
	}
}
