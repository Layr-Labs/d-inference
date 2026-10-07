package cachepersist_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
	"github.com/eigeninference/d-inference/coordinator/store/memory"

	production "github.com/eigeninference/d-inference/coordinator/registry/cachepersist"
)

// Overlapping sessions park the same durable row more than once; one parked
// copy per (key, epoch) keeps the newer evidence and takes one cap slot.
func TestParkDedupesByHolderIdentity(t *testing.T) {
	mem := memory.NewMemory(store.Config{})
	p := production.New(mem, nil, production.Options{MaxPending: 2})
	now := time.Now()
	older := rec("a", "e", now.Add(-time.Second), time.Minute)
	older.StageMs = 50
	newer := rec("a", "e", now, time.Minute)
	newer.StageMs = 900
	p.Park(older)
	p.Park(newer)
	p.Park(older) // a late duplicate of the older session
	p.Park(rec("b", "e", now, time.Minute))
	if s := p.Status(); s.PendingHolders != 2 || s.DroppedPending != 0 {
		t.Fatalf("duplicates must not consume the cap: %+v", s)
	}
	rows, _ := p.Take("e", "model", 0)
	byKey := map[string]crs.HolderRecord{}
	for _, r := range rows {
		byKey[r.Key] = r
	}
	if len(rows) != 2 || byKey["a"].StageMs != 900 || byKey["b"].Key != "b" {
		t.Fatalf("one parked copy per identity with the newer evidence: %+v", rows)
	}
}

// A bounded take hands back at most limit rows and says whether more remain,
// so a large bucket can be bound in chunks.
func TestTakeInChunks(t *testing.T) {
	mem := memory.NewMemory(store.Config{})
	p := production.New(mem, nil, production.Options{MaxPending: 10})
	now := time.Now()
	for i := 0; i < 5; i++ {
		p.Park(rec(string(rune('a'+i)), "e", now, time.Minute))
	}
	total := 0
	for i := 0; i < 3; i++ {
		rows, more := p.Take("e", "model", 2)
		total += len(rows)
		if i < 2 && (len(rows) != 2 || !more) {
			t.Fatalf("chunk %d: rows=%d more=%v", i, len(rows), more)
		}
		if i == 2 && (len(rows) != 1 || more) {
			t.Fatalf("last chunk: rows=%d more=%v", len(rows), more)
		}
	}
	if total != 5 || p.HasPending() {
		t.Fatalf("all rows must be taken exactly once: total=%d pending=%v", total, p.HasPending())
	}
}
