package inference_test

import (
	"fmt"
	"testing"
	"time"

	cancellation "github.com/eigeninference/d-inference/coordinator/internal/inference/cancellation"
)

func TestZombieCappedInsertionKeepsRecentlyActiveEntries(t *testing.T) {
	z := newZombieFixture()

	now := time.Now()
	for i := range cancellation.MaxEntries {
		z.Record(fmt.Sprint(i), "m", cancellation.CauseHedgeLoser, now)
	}
	z.MarkSent("0", now)
	z.StrayChunk("1", now)
	_, expired := z.Record("new", "m", cancellation.CauseHedgeLoser, now)
	if len(expired) != 1 || z.entries.Lookup("2") != nil || z.entries.Lookup("0") == nil || z.entries.Lookup("1") == nil {
		t.Fatal("capped insertion did not evict the least recently active entry")
	}
	z.Forget("0")
	z.Terminal("1")
	z.Record("expire-trigger", "m", cancellation.CauseHedgeLoser, now.Add(cancellation.EntryTTL+time.Second))
	oldestID, oldest := z.entries.Oldest()
	if z.Len() != 1 || z.entries.Len() != 1 || oldestID != "expire-trigger" || z.entries.Lookup(oldestID) != oldest {
		t.Fatal("forget, terminal or TTL expiry leaked eviction metadata")
	}
	assertZombieIndexDrains(t, z.entries, oldest)
}

func assertZombieIndexDrains(t *testing.T, index *cancellation.Index, survivor *cancellation.Entry) {
	t.Helper()
	for i := range cancellation.MaxEntries {
		if index.Lookup(fmt.Sprint(i)) != nil {
			t.Fatalf("removed request %d retained a keyed node", i)
		}
	}
	if index.Lookup("new") != nil || index.Lookup("expire-trigger") != survivor {
		t.Fatal("recency index retained a ghost or changed its surviving entry")
	}
	index.Remove("expire-trigger")
	id, entry := index.Oldest()
	if index.Len() != 0 || id != "" || entry != nil || index.Lookup("expire-trigger") != nil {
		t.Fatal("drained recency index retained keyed or ordered metadata")
	}
}

func TestZombieCappedInsertionDoesNotForceExpirySweep(t *testing.T) {
	z := newZombieFixture()

	now := time.Now()
	for i := range cancellation.MaxEntries {
		z.Record(fmt.Sprint(i), "m", cancellation.CauseHedgeLoser, now)
	}
	// A regular sweep at the exact TTL boundary retains all entries. They
	// expire a nanosecond later, but a capped insertion must not bypass the
	// one-second sweep cadence and walk all of them on the token hot path.
	z.Record("0", "m", cancellation.CauseHedgeLoser, now.Add(cancellation.EntryTTL))
	_, expired := z.Record("new", "m", cancellation.CauseHedgeLoser, now.Add(cancellation.EntryTTL+time.Nanosecond))
	if len(expired) != 1 || z.Len() != cancellation.MaxEntries {
		t.Fatalf("capped insertion forced a sweep: expired=%d retained=%d", len(expired), z.Len())
	}
}

// Run with a fixed clock so every operation measures capped insertion, not
// the separately rate-limited expiry sweep. IDs revisit evicted streams like
// a restart wave exceeding the tracker cap.
func BenchmarkZombieCappedStrayChurn(b *testing.B) {
	z := newZombieFixture()

	now := time.Now()
	ids := make([]string, cancellation.MaxEntries*2)
	for i := range ids {
		ids[i] = fmt.Sprint(i)
	}
	for _, id := range ids[:cancellation.MaxEntries] {
		z.StrayChunk(id, now)
	}
	b.ResetTimer()
	for i := range b.N {
		z.StrayChunk(ids[(i+cancellation.MaxEntries)%len(ids)], now)
	}
}
