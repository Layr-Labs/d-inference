package registry

import (
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
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

func evictStrikesSnapshot(r *Registry) map[string]int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make(map[string]int, len(r.evictStrikes))
	for id, n := range r.evictStrikes {
		out[id] = n
	}
	return out
}

// TestEvictStaleReapsExactlyTheStaleSet is the behavioral pin for the
// read-lock scan: a mixed fleet must lose exactly its two-strike stale
// providers, a provider that goes stale one sweep later must survive with a
// single strike, and recovery must clear the strike.
func TestEvictStaleReapsExactlyTheStaleSet(t *testing.T) {
	r := New(testLogger())
	const model = aliasQAT
	var ids []string
	for i := 0; i < 30; i++ {
		id := fmt.Sprintf("p%02d", i)
		registerProviderWithModel(r, id, model)
		ids = append(ids, id)
	}
	setHeartbeatAge := func(id string, age time.Duration) {
		p := r.GetProvider(id)
		p.mu.Lock()
		p.LastHeartbeat = time.Now().Add(-age)
		p.mu.Unlock()
	}
	stale := map[string]bool{}
	for i, id := range ids {
		if i%3 == 0 {
			stale[id] = true
			setHeartbeatAge(id, 5*time.Minute)
		}
	}
	timeout := 90 * time.Second

	if before := evictStrikesSnapshot(r); len(before) != 0 {
		t.Fatalf("fresh registry carries strikes: %v", before)
	}
	r.evictStale(timeout) // strike 1 — grace for everyone
	for _, id := range ids {
		if !providerPresent(r, id) {
			t.Fatalf("%s evicted on the first stale sweep", id)
		}
	}
	strikes := evictStrikesSnapshot(r)
	if len(strikes) != len(stale) {
		t.Fatalf("strikes after sweep 1 = %v, want exactly the %d stale providers", strikes, len(stale))
	}
	for id := range stale {
		if strikes[id] != 1 {
			t.Fatalf("strike for %s = %d, want 1", id, strikes[id])
		}
	}

	late := "p01" // goes stale only now: one strike, must survive sweep 2
	setHeartbeatAge(late, 5*time.Minute)
	r.evictStale(timeout) // strike 2 for the original set — reaped
	for _, id := range ids {
		present := providerPresent(r, id)
		if stale[id] && present {
			t.Fatalf("%s survived two consecutive stale sweeps", id)
		}
		if !stale[id] && !present {
			t.Fatalf("%s evicted despite being fresh (or late by one sweep)", id)
		}
	}
	if strikes := evictStrikesSnapshot(r); len(strikes) != 1 || strikes[late] != 1 {
		t.Fatalf("strikes after sweep 2 = %v, want {%s:1}", strikes, late)
	}

	setHeartbeatAge(late, 0) // recovered
	r.evictStale(timeout)
	if !providerPresent(r, late) {
		t.Fatalf("%s evicted after recovering", late)
	}
	if strikes := evictStrikesSnapshot(r); len(strikes) != 0 {
		t.Fatalf("strikes after recovery = %v, want none", strikes)
	}
	if r.ProviderCount() != len(ids)-len(stale) {
		t.Fatalf("fleet = %d, want %d", r.ProviderCount(), len(ids)-len(stale))
	}
}

// TestEvictStaleConcurrentWithHeartbeats runs sweeps against a fleet that is
// heartbeating, being listed, AND churning (extra providers registered and
// disconnected, which mutate r.providers under the write lock) concurrently.
// Under -race this proves the read-lock scan introduces no data race with the
// writers of LastHeartbeat, the other read-lock walks, or the map writers —
// dropping the RLock around the scan fails this test.
func TestEvictStaleConcurrentWithHeartbeats(t *testing.T) {
	r := New(testLogger())
	const model = aliasQAT
	var ids []string
	for i := 0; i < 40; i++ {
		id := fmt.Sprintf("hb%02d", i)
		p := registerProviderWithModel(r, id, model)
		makeProviderRoutable(p)
		ids = append(ids, id)
	}
	stop := make(chan struct{})
	var wg sync.WaitGroup
	for w := 0; w < 4; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			for n := 0; ; n++ {
				select {
				case <-stop:
					return
				default:
				}
				r.Heartbeat(ids[(n*7+w)%len(ids)], &protocol.HeartbeatMessage{Type: protocol.TypeHeartbeat, Status: "idle"})
				if n%16 == 0 {
					_ = r.ListModels()
					_ = r.PublicProviderModels()
				}
			}
		}(w)
	}
	// Churn: register and disconnect extra providers for the whole run so the
	// provider map is written while the sweep iterates it. Every iteration
	// ends with the disconnect, so the fleet is back to ids when it stops.
	wg.Add(1)
	go func() {
		defer wg.Done()
		for n := 0; ; n++ {
			select {
			case <-stop:
				return
			default:
			}
			id := fmt.Sprintf("churn%03d", n%50)
			registerProviderWithModel(r, id, model)
			r.Disconnect(id)
		}
	}()
	deadline := time.Now().Add(150 * time.Millisecond)
	for time.Now().Before(deadline) {
		r.evictStale(90 * time.Second)
	}
	close(stop)
	wg.Wait()
	if r.ProviderCount() != len(ids) {
		t.Fatalf("fleet = %d after concurrent no-evict sweeps, want %d", r.ProviderCount(), len(ids))
	}
	if strikes := evictStrikesSnapshot(r); len(strikes) != 0 {
		t.Fatalf("fresh fleet carries strikes: %v", strikes)
	}
}
