package faultstate

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Both keys holding a reset timestamp merge to the LATER one, whichever side
// it is on, so a rebind can never shorten the interval.
func TestMigrateFaultState_ResetTimestampKeepsLater(t *testing.T) {
	older := time.Now().Add(-5 * time.Minute)
	newer := time.Now()
	for _, tc := range []struct {
		name     string
		src, dst time.Time
	}{
		{"newer source wins", newer, older},
		{"newer destination kept", older, newer},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := newTestManager(testLogger())
			withGateForKey(r, "old", func(g *gateState) { g.versionResetAt = tc.src })
			withGateForKey(r, "new", func(g *gateState) { g.versionResetAt = tc.dst })
			r.gatesMu.Lock()
			r.migrateGateLocked(&Session[string]{}, r.gates["old"], r.gates["new"], true)
			got := r.gates["new"].versionResetAt
			ok := !got.IsZero()
			_, orphan := r.gates["old"]
			r.gatesMu.Unlock()
			if !ok || !got.Equal(newer) {
				t.Fatalf("merged reset timestamp = %v (present=%v), want %v", got, ok, newer)
			}
			if orphan {
				t.Fatal("reset timestamp orphaned under the old key")
			}
		})
	}
}

// TestInferenceFlushStrikes_BoundedForSameVersionIdentity: an identity that
// churns on the SAME binary version never triggers the version reset, so its
// disconnect-flush tags were append-only — the main strikes slid out of the
// breaker window and a success deleted them, but every flushed request kept a
// time.Time under the identity forever. Seed 10,000 flushed requests spread
// over hours (each also in the main strike list, exactly as RecordInferenceError
// writes them), record one more flush, and the tag slice must be bounded by
// the breaker window and remain a subset of the strikes; a success clears it.
func TestInferenceFlushStrikes_BoundedForSameVersionIdentity(t *testing.T) {
	r := newTestManager(testLogger())
	attachTestVersionFirst(r, "s1", versionResetStable, "0.9.0")
	key := modelShapeKey{Model: "m", Shape: "base"}
	g := r.gateForSession("s1").g

	const flushed = 10_000
	now := time.Now()
	seed := make([]time.Time, 0, flushed)
	for i := 0; i < flushed; i++ {
		// One flush every 2 s, the newest 2 s ago: ~30 fall inside the 60 s
		// breaker window, the rest are hours old.
		seed = append(seed, now.Add(-time.Duration(flushed-i)*2*time.Second))
	}
	g.mu.Lock()
	g.inferenceErrorStrikes[key] = append([]time.Time(nil), seed...)
	if g.inferenceErrorFlushStrikes == nil {
		g.inferenceErrorFlushStrikes = make(map[modelShapeKey][]time.Time)
	}
	g.inferenceErrorFlushStrikes[key] = append([]time.Time(nil), seed...)
	g.publishLocked()
	g.mu.Unlock()

	r.RecordInferenceError("s1", "m", 502, "base", protocol.CoordinatorCauseProviderDisconnected)

	g.mu.Lock()
	strikes := append([]time.Time(nil), g.inferenceErrorStrikes[key]...)
	flush := append([]time.Time(nil), g.inferenceErrorFlushStrikes[key]...)
	g.publishLocked()
	g.mu.Unlock()
	if len(strikes) == 0 {
		t.Fatal("main strike list is empty after a recorded flush")
	}
	// The bound is the breaker window: everything older than 60 s is gone.
	// 30 seeded entries at most survive (2 s spacing) plus the strike just
	// recorded; allow the wall clock a little drift.
	if len(flush) > int(inferenceErrorWindow/(2*time.Second))+2 {
		t.Fatalf("flush tags = %d after %d historical flushes, want the slice bounded by the %s window", len(flush), flushed, inferenceErrorWindow)
	}
	if len(flush) > len(strikes) {
		t.Fatalf("flush tags (%d) outnumber live strikes (%d)", len(flush), len(strikes))
	}
	for _, ts := range flush {
		if !containsTimestamp(strikes, ts) {
			t.Fatalf("flush tag %v marks a strike that is no longer in the window", ts)
		}
		if now.Sub(ts) >= inferenceErrorWindow+time.Second {
			t.Fatalf("flush tag %v is older than the breaker window", ts)
		}
	}
	if !containsTimestamp(flush, strikes[len(strikes)-1]) {
		t.Fatal("the flush just recorded is not tagged")
	}

	// A served request clears the shape's history — tags included.
	r.RecordInferenceSuccess("s1", "m", "base")
	g.mu.Lock()
	_, strikesLeft := g.inferenceErrorStrikes[key]
	_, flushLeft := g.inferenceErrorFlushStrikes[key]
	g.publishLocked()
	g.mu.Unlock()
	if strikesLeft || flushLeft {
		t.Fatalf("after success: strikes present=%v flush tags present=%v, want both cleared", strikesLeft, flushLeft)
	}
}

// TestInferenceFlushStrikes_NonFlushStrikePrunesTags: the tags slide out of
// the window on EVERY counted strike, not only on a 502, so they can never
// reference a strike the main list has already dropped.
func TestInferenceFlushStrikes_NonFlushStrikePrunesTags(t *testing.T) {
	r := newTestManager(testLogger())
	attachTestVersionFirst(r, "s1", versionResetStable, "0.9.0")
	key := modelShapeKey{Model: "m", Shape: "base"}
	g := r.gateForSession("s1").g

	stale := time.Now().Add(-2 * inferenceErrorWindow)
	g.mu.Lock()
	g.inferenceErrorStrikes[key] = []time.Time{stale}
	g.inferenceErrorFlushStrikes = map[modelShapeKey][]time.Time{key: {stale}}
	g.publishLocked()
	g.mu.Unlock()

	r.RecordInferenceError("s1", "m", 500, "base")

	g.mu.Lock()
	flush, present := g.inferenceErrorFlushStrikes[key]
	g.publishLocked()
	g.mu.Unlock()
	if present {
		t.Fatalf("stale flush tag survived a non-flush strike: %v", flush)
	}
}
