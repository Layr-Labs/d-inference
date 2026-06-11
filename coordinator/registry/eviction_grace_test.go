package registry

import (
	"testing"
	"time"
)

func providerPresent(r *Registry, id string) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	_, ok := r.providers[id]
	return ok
}

// A provider stale for only ONE sweep must NOT be evicted (grace), but stale for
// TWO consecutive sweeps IS — so a transient coordinator stall that ages many
// LastHeartbeat values at once gives the fleet a sweep to recover.
func TestEvictStaleTwoStrikeGrace(t *testing.T) {
	r := New(testLogger())
	const model = aliasQAT
	p := registerProviderWithModel(r, "p1", model)
	p.mu.Lock()
	p.LastHeartbeat = time.Now().Add(-5 * time.Minute) // well past any timeout
	p.mu.Unlock()

	timeout := 90 * time.Second

	r.evictStale(timeout) // strike 1 — grace
	if !providerPresent(r, p.ID) {
		t.Fatal("provider evicted on the first stale sweep (no grace)")
	}

	r.evictStale(timeout) // strike 2 — evict
	if providerPresent(r, p.ID) {
		t.Fatal("provider survived two consecutive stale sweeps")
	}
}

// A provider that recovers (fresh heartbeat) after one stale sweep must have its
// strike reset, so it's never evicted.
func TestEvictStaleStrikeResetsOnRecovery(t *testing.T) {
	r := New(testLogger())
	const model = aliasQAT
	p := registerProviderWithModel(r, "p1", model)
	timeout := 90 * time.Second

	p.mu.Lock()
	p.LastHeartbeat = time.Now().Add(-5 * time.Minute)
	p.mu.Unlock()
	r.evictStale(timeout) // strike 1

	p.mu.Lock()
	p.LastHeartbeat = time.Now() // heartbeat arrived
	p.mu.Unlock()
	r.evictStale(timeout) // not stale — strike reset

	p.mu.Lock()
	p.LastHeartbeat = time.Now().Add(-5 * time.Minute) // stale again
	p.mu.Unlock()
	r.evictStale(timeout) // strike 1 again (reset worked), not evicted

	if !providerPresent(r, p.ID) {
		t.Fatal("provider evicted despite a recovery resetting its strike count")
	}
}

func TestDurationStats(t *testing.T) {
	if a, b, c, d := durationStats(nil); a|b|c|d != 0 {
		t.Fatalf("empty slice should be all zeros, got %v %v %v %v", a, b, c, d)
	}
	ds := []time.Duration{50 * time.Second, 10 * time.Second, 100 * time.Second, 30 * time.Second}
	min, med, p90, max := durationStats(ds)
	if min != 10*time.Second || max != 100*time.Second {
		t.Fatalf("min/max = %v/%v, want 10s/100s", min, max)
	}
	if med <= 0 || med > max {
		t.Fatalf("median %v out of range", med)
	}
	_ = p90
}
