package api

import (
	"fmt"
	"testing"
	"time"
)

func TestZombieCappedInsertionKeepsRecentlyActiveEntries(t *testing.T) {
	z := newZombieStreamCanceller()
	now := time.Now()
	for i := range zombieCancelMaxEntries {
		z.record(fmt.Sprint(i), "m", cancelCauseHedgeLoser, now)
	}
	z.markSent("0", now)
	z.strayChunk("1", now)
	_, expired := z.record("new", "m", cancelCauseHedgeLoser, now)
	if len(expired) != 1 || z.entries["2"] != nil || z.entries["0"] == nil || z.entries["1"] == nil {
		t.Fatal("capped insertion did not evict the least recently active entry")
	}
	z.forget("0")
	z.terminal("1")
	z.record("expire-trigger", "m", cancelCauseHedgeLoser, now.Add(zombieEntryTTL+time.Second))
	if z.size() != 1 || z.recency.Len() != 1 || len(z.positions) != 1 {
		t.Fatal("forget, terminal or TTL expiry leaked eviction metadata")
	}
}

func TestZombieCappedInsertionDoesNotForceExpirySweep(t *testing.T) {
	z := newZombieStreamCanceller()
	now := time.Now()
	for i := range zombieCancelMaxEntries {
		z.record(fmt.Sprint(i), "m", cancelCauseHedgeLoser, now)
	}
	// A regular sweep at the exact TTL boundary retains all entries. They
	// expire a nanosecond later, but a capped insertion must not bypass the
	// one-second sweep cadence and walk all of them on the token hot path.
	z.record("0", "m", cancelCauseHedgeLoser, now.Add(zombieEntryTTL))
	_, expired := z.record("new", "m", cancelCauseHedgeLoser, now.Add(zombieEntryTTL+time.Nanosecond))
	if len(expired) != 1 || z.size() != zombieCancelMaxEntries {
		t.Fatalf("capped insertion forced a sweep: expired=%d retained=%d", len(expired), z.size())
	}
}

// Run with a fixed clock so every operation measures capped insertion, not
// the separately rate-limited expiry sweep. IDs revisit evicted streams like
// a restart wave exceeding the tracker cap.
func BenchmarkZombieCappedStrayChurn(b *testing.B) {
	z := newZombieStreamCanceller()
	now := time.Now()
	ids := make([]string, zombieCancelMaxEntries*2)
	for i := range ids {
		ids[i] = fmt.Sprint(i)
	}
	for _, id := range ids[:zombieCancelMaxEntries] {
		z.strayChunk(id, now)
	}
	b.ResetTimer()
	for i := range b.N {
		z.strayChunk(ids[(i+zombieCancelMaxEntries)%len(ids)], now)
	}
}
