package registry

import (
	"testing"
	"time"
)

const explorationGateModel = "explore"

// longIdleExplorable makes the idle provider of explorationPair explorable:
// no evidence, connected long enough ago to be past the exploration bound.
func longIdleExplorable(p *Provider, now time.Time) {
	p.firstContentMeasurements = nil
	p.registeredAt = now.Add(-10 * time.Minute)
}

func explorationGatePair(t *testing.T) (*Registry, *Provider, *Provider) {
	t.Helper()
	r := New(testLogger())
	qualified, idle := explorationPair(t, r, explorationGateModel, longIdleExplorable)
	return r, qualified, idle
}

func reserveExplore(t *testing.T, r *Registry) *Provider {
	t.Helper()
	selected, _ := r.ReserveProviderEx(explorationGateModel, deadlineRequest())
	if selected != nil {
		selected.RemovePending("request")
	}
	return selected
}

func setFleetMedian(r *Registry, p *Provider, tps float64) {
	for range 5 {
		r.tpsRegistry.Record(explorationGateModel, p.Hardware.ChipFamily, tps)
	}
}

func rememberDecode(p *Provider, rates ...float64) {
	now := time.Now()
	for _, rate := range rates {
		p.gate.Load().recordFirstContentDecodeObservation(explorationGateModel, rate, 80, now)
	}
}

// A provider whose engine keeps resetting is explorable again every few
// minutes, and first-content timeouts reach no breaker. One failed
// exploration must keep it from being explored again straight away.
func TestFirstContentExplorationBackoffSuppressesAfterFailure(t *testing.T) {
	r, qualified, idle := explorationGatePair(t)
	if got := reserveExplore(t, r); got != idle {
		t.Fatalf("setup: selected=%v, want the explorable idle provider", got)
	}
	r.RecordFirstContentExplorationOutcome(idle.ID, explorationGateModel, false)
	if got := reserveExplore(t, r); got != qualified {
		t.Fatalf("after a failed exploration selected=%v, want qualified evidence", got)
	}
}

func TestFirstContentExplorationBackoffDoublesAndHalves(t *testing.T) {
	r, _, idle := explorationGatePair(t)
	entry := func() *firstContentExplorationEntry {
		g := idle.gate.Load().lockResolved()
		defer g.mu.Unlock()
		return g.exploration[explorationGateModel]
	}
	want := func(level int, backoff time.Duration) {
		t.Helper()
		e := entry()
		if e.level != level {
			t.Fatalf("level=%d, want %d", e.level, level)
		}
		if got := time.Until(e.until); got > backoff || got < backoff-time.Minute {
			t.Fatalf("level %d: suppressed for %v, want about %v", level, got, backoff)
		}
	}
	for i, d := range []time.Duration{5, 10, 20, 40} {
		r.RecordFirstContentExplorationOutcome(idle.ID, explorationGateModel, false)
		want(i+1, d*time.Minute)
	}
	// An 80%-failure provider must drift upward, not reset: four failures and
	// one success leave it more suppressed than one failure did.
	r.RecordFirstContentExplorationOutcome(idle.ID, explorationGateModel, true)
	want(3, 20*time.Minute)
	for range 10 {
		r.RecordFirstContentExplorationOutcome(idle.ID, explorationGateModel, false)
	}
	if got := firstContentExplorationBackoff(entry().level); got != firstContentExplorationBackoffMax {
		t.Fatalf("backoff=%v, want the %v cap", got, firstContentExplorationBackoffMax)
	}
	for range 20 {
		r.RecordFirstContentExplorationOutcome(idle.ID, explorationGateModel, true)
	}
	if e := entry(); e.level != 0 || !e.until.IsZero() {
		t.Fatalf("recovered provider still suppressed: level=%d until=%v", e.level, e.until)
	}
	if got := reserveExplore(t, r); got != idle {
		t.Fatalf("recovered provider selected=%v, want it explorable again", got)
	}
}

// The suspenders: a corroborated remembered decode rate far below the fleet
// median keeps a provider out of exploration before any exploration fails.
func TestFirstContentExplorationRememberedSlowDecodeGates(t *testing.T) {
	r, qualified, idle := explorationGatePair(t)
	setFleetMedian(r, idle, 80)
	rememberDecode(idle, 10.0, 11.7, 10.1, 11.7, 12.0)
	if got := reserveExplore(t, r); got != qualified {
		t.Fatalf("selected=%v, want qualified evidence over a remembered 11 tok/s provider", got)
	}
}

// One slow observation must never gate: a single slow final decode pinning a
// healthy provider is the lock-out exploration exists to escape (#1238).
func TestFirstContentExplorationSingleSlowObservationDoesNotGate(t *testing.T) {
	r, _, idle := explorationGatePair(t)
	setFleetMedian(r, idle, 80)
	rememberDecode(idle, 16.2, 15.0, 14.0, 13.0) // below the corroboration count
	if got := reserveExplore(t, r); got != idle {
		t.Fatalf("selected=%v, want the provider explorable on uncorroborated evidence", got)
	}
}

func TestFirstContentExplorationHealthyObservationClearsMemory(t *testing.T) {
	r, _, idle := explorationGatePair(t)
	setFleetMedian(r, idle, 80)
	rememberDecode(idle, 10, 10, 10, 10, 10)
	rememberDecode(idle, 60) // at least half the fleet median
	if got := reserveExplore(t, r); got != idle {
		t.Fatalf("selected=%v, want memory cleared by a healthy observation", got)
	}
}

// Suppression changes only exploration: with no feasible candidate the
// provider still serves through the ordinary unknown fallback.
func TestFirstContentExplorationSuppressionIsNotQuarantine(t *testing.T) {
	r := New(testLogger())
	idle := planTestProvider(t, r, "idle", explorationGateModel, 0)
	idle.mu.Lock()
	longIdleExplorable(idle, time.Now())
	idle.mu.Unlock()
	r.RecordFirstContentExplorationOutcome(idle.ID, explorationGateModel, false)
	if got := reserveExplore(t, r); got != idle {
		t.Fatalf("selected=%v, want the suppressed provider as the only candidate", got)
	}
}

func TestFirstContentExplorationClearedByVersionChange(t *testing.T) {
	r, _, idle := explorationGatePair(t)
	g := idle.gate.Load()
	g = g.lockResolved()
	g.noteIdentityVersionLocked(r, "0.9.11")
	g.mu.Unlock()
	r.RecordFirstContentExplorationOutcome(idle.ID, explorationGateModel, false)
	g = g.lockResolved()
	g.noteIdentityVersionLocked(r, "0.9.12")
	remaining := len(g.exploration)
	g.mu.Unlock()
	if remaining != 0 || g.hasPairState(gateFlagExploration) {
		t.Fatalf("new binary kept exploration memory: entries=%d", remaining)
	}
}

func TestFirstContentExplorationMigrationKeepsStricterState(t *testing.T) {
	now := time.Now()
	dst, src := newGateState("dst"), newGateState("src")
	dst.explorationEntryLocked(explorationGateModel, now.Add(-time.Hour)).level = 1
	s := src.explorationEntryLocked(explorationGateModel, now)
	s.level, s.until, s.decode = 3, now.Add(20*time.Minute), []float64{10, 11, 12}
	dst.mergeExplorationLocked(src)
	e := dst.exploration[explorationGateModel]
	if e.level != 3 || !e.until.Equal(s.until) || len(e.decode) != 3 {
		t.Fatalf("merge lost the stricter state: %+v", e)
	}
}

func TestFirstContentExplorationSweepKeepsActiveAndDropsExpired(t *testing.T) {
	now := time.Now()
	g := newGateState("k")
	g.explorationEntryLocked("active", now).until = now.Add(time.Minute)
	g.explorationEntryLocked("old", now.Add(-7*time.Hour))
	if live := g.pruneExplorationLocked(now); !live || len(g.exploration) != 1 || g.exploration["active"] == nil {
		t.Fatalf("prune kept %v", g.exploration)
	}
}

// The heartbeat must remember each newly measured decode rate once: an
// unchanged repeated report is not a new observation.
func TestFirstContentExplorationHeartbeatRecordsOnlyNewObservations(t *testing.T) {
	r, _, idle := explorationGatePair(t)
	count := func() int {
		g := idle.gate.Load().lockResolved()
		defer g.mu.Unlock()
		if e := g.exploration[explorationGateModel]; e != nil {
			return len(e.decode)
		}
		return 0
	}
	idle.mu.Lock()
	defer idle.mu.Unlock()
	now := time.Now()
	for i, rate := range []float64{10, 10, 11, 11, 12} {
		before := idle.firstContentDecodeMarksLocked()
		idle.firstContentMeasurements = map[string]firstContentMeasurement{explorationGateModel: {rate: 120, decodeRate: rate}}
		r.noteFirstContentDecodeObservationsLocked(idle, before, now)
		idle.mu.Unlock()
		got := count()
		idle.mu.Lock()
		if want := []int{1, 1, 2, 2, 3}[i]; got != want {
			t.Fatalf("after report %d (rate %v): %d observations, want %d", i, rate, got, want)
		}
	}
}
