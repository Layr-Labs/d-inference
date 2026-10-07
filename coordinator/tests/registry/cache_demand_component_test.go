package registry_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachedemand"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachehistory"
)

func TestCacheDemandTouchedRunsAfterUnlockOnRetainedHistory(t *testing.T) {
	d := newDemandFixture(4, time.Minute)
	now := time.Unix(1000, 0)
	done := make(chan struct{}, 1)
	d.tracker.SetOnTouched(func(keys []string, at time.Time) {
		entries, evictions := d.tracker.Stats()
		if len(keys) != 1 || keys[0] != "boundary" || at != now || entries != 1 || evictions != 0 {
			t.Errorf("persistence observation: keys=%v at=%v entries=%d evictions=%d", keys, at, entries, evictions)
		}
		if len(keys) == 1 {
			if entry, ok := d.index.Load(keys[0]); !ok || entry.Seen != now {
				t.Error("persistence callback did not observe the retained production index")
			}
		}
		done <- struct{}{}
	})
	go d.tracker.Observe([]cachedemand.Boundary{{Key: "boundary", Tokens: 1024}}, now)
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("persistence callback blocked behind demand lock")
	}
}

func TestCacheDemandHistorySnapshotAndResetOwnRecords(t *testing.T) {
	index := cachehistory.New()
	now := time.Unix(1000, 0)
	initial := []cachehistory.Entry{{Key: "a", Seen: now}, {Key: "b", Seen: now.Add(time.Second)}}
	index.Reset(initial)
	initial[0].Key = "caller mutation"
	view := index.Snapshot()
	view[0].Key = "snapshot mutation"
	if first, ok := index.Front(); !ok || first.Key != "a" || index.Len() != 2 {
		t.Fatalf("mutable record storage escaped: first=%+v present=%v count=%d", first, ok, index.Len())
	}
	index.Store(cachehistory.Entry{Key: "a", Seen: now.Add(2 * time.Second)})
	if view := index.Snapshot(); len(view) != 2 || view[0].Key != "b" || view[1].Key != "a" {
		t.Fatalf("refresh did not retain key/order identity: %+v", view)
	}
	index.Delete("b")
	if _, ok := index.Load("b"); ok || index.Len() != 1 || len(index.Snapshot()) != 1 {
		t.Fatal("delete left the directory and arrival order inconsistent")
	}
}
