package registry_test

import (
	"math"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/identitygate"
)

const explorationMemoryModel = "explore"

func newExplorationMemoryDirectory() (*identitygate.Directory, *faultGateClock) {
	clock := &faultGateClock{at: time.Date(2026, time.October, 6, 12, 0, 0, 0, time.UTC)}
	options := identitygate.DefaultOptions()
	options.Now = clock.Now
	return identitygate.New(testLogger(), &options), clock
}

func assertExplorationSuppression(t *testing.T, view identitygate.View, now time.Time, duration time.Duration) {
	t.Helper()
	if duration > 0 && !view.Exploration(explorationMemoryModel, now.Add(duration-time.Nanosecond)).Suppressed {
		t.Fatalf("suppression ended before %v", duration)
	}
	if view.Exploration(explorationMemoryModel, now.Add(duration)).Suppressed {
		t.Fatalf("suppression survived its %v boundary", duration)
	}
}

func TestFirstContentExplorationMemoryBackoffDoublesAndHalves(t *testing.T) {
	gates, clock := newExplorationMemoryDirectory()
	gates.Attach("session")
	view := gates.ViewForSession(nil, "session")
	for _, minutes := range []time.Duration{5, 10, 20, 40} {
		gates.RecordFirstContentExplorationOutcome("session", explorationMemoryModel, false)
		assertExplorationSuppression(t, view, clock.Now(), minutes*time.Minute)
	}
	// Four failures and one success must leave more suppression than one failure.
	gates.RecordFirstContentExplorationOutcome("session", explorationMemoryModel, true)
	assertExplorationSuppression(t, view, clock.Now(), 20*time.Minute)
	for _, minutes := range []time.Duration{40, 80, 120, 120, 120, 120, 120, 120} {
		gates.RecordFirstContentExplorationOutcome("session", explorationMemoryModel, false)
		assertExplorationSuppression(t, view, clock.Now(), minutes*time.Minute)
	}
	// Saturation is level six, not an unbounded counter: one success drops to 80m.
	for _, minutes := range []time.Duration{80, 40, 20, 10, 5, 0, 0} {
		gates.RecordFirstContentExplorationOutcome("session", explorationMemoryModel, true)
		assertExplorationSuppression(t, view, clock.Now(), minutes*time.Minute)
	}
	if view.Exploration("another-model", clock.Now()) != (identitygate.ExplorationView{}) {
		t.Fatal("outcomes changed another model")
	}
}

func TestFirstContentExplorationMemorySuccessDoesNotExtendSuppression(t *testing.T) {
	gates, clock := newExplorationMemoryDirectory()
	gates.Attach("session")
	for range 3 {
		gates.RecordFirstContentExplorationOutcome("session", explorationMemoryModel, false)
	}
	clock.Advance(19 * time.Minute)
	gates.RecordFirstContentExplorationOutcome("session", explorationMemoryModel, true)
	view := gates.ViewForSession(nil, "session")
	assertExplorationSuppression(t, view, clock.Now(), time.Minute)
	clock.Advance(time.Minute)
	gates.RecordFirstContentExplorationOutcome("session", explorationMemoryModel, true)
	assertExplorationSuppression(t, view, clock.Now(), 0)
	// The remaining level still matters on a later failed exploration.
	clock.Advance(time.Minute)
	gates.RecordFirstContentExplorationOutcome("session", explorationMemoryModel, false)
	assertExplorationSuppression(t, view, clock.Now(), 10*time.Minute)
}

func TestFirstContentExplorationMemoryDecodeCorroborationAndCap(t *testing.T) {
	gates, clock := newExplorationMemoryDirectory()
	session := gates.Attach("session")
	ref := gates.ReferenceForSession(session, "session")
	view := gates.ViewForSession(session, "session")
	for i, rate := range []float64{10, 11, 12, 13, 14, 15, 16, 17, 30, 31, 32, 33} {
		gates.RecordFirstContentDecodeObservation(ref, explicitDecodeObservation(explorationMemoryModel, rate, int64(i+1), clock.Now()), 80, clock.Now())
		got := view.Exploration(explorationMemoryModel, clock.Now())
		if want := min(i+1, 8); got.DecodeSamples != want {
			t.Fatalf("observation %d: samples=%d, want %d", i+1, got.DecodeSamples, want)
		}
		if i < 4 && (got.DecodeMedian != 0 || got.RememberedSlow(80)) {
			t.Fatalf("uncorroborated slow evidence gated exploration: %+v", got)
		}
		if i == 4 && (got.DecodeMedian != 12 || !got.RememberedSlow(80)) {
			t.Fatalf("five slow observations did not gate exploration: %+v", got)
		}
	}
	// The eight latest are 14,15,16,17,30,31,32,33; use the upper median.
	got := view.Exploration(explorationMemoryModel, clock.Now())
	if got.DecodeMedian != 30 || got.RememberedSlow(80) {
		t.Fatalf("old samples still dominate the bounded window: %+v", got)
	}
	for _, tc := range []struct {
		fleet float64
		slow  bool
	}{
		{120, false}, // exactly one quarter is not slow
		{121, true},
		{0, false},
		{-1, false},
		{math.NaN(), false},
	} {
		if got.RememberedSlow(tc.fleet) != tc.slow {
			t.Fatalf("median 30 relative to fleet %v: want slow=%v", tc.fleet, tc.slow)
		}
	}
	for _, rate := range []float64{0, -1, math.NaN(), math.Inf(1), math.Inf(-1)} {
		gates.RecordFirstContentDecodeObservation(ref, explicitDecodeObservation(explorationMemoryModel, rate, 20, clock.Now()), 80, clock.Now())
	}
	gates.RecordFirstContentDecodeObservation(ref, explicitDecodeObservation("", 10, 20, clock.Now()), 80, clock.Now())
	if after := view.Exploration(explorationMemoryModel, clock.Now()); after != got {
		t.Fatalf("invalid measurements changed memory: before=%+v after=%+v", got, after)
	}
	if view.Exploration("", clock.Now()) != (identitygate.ExplorationView{}) {
		t.Fatal("an empty model acquired decode memory")
	}
}

func TestFirstContentExplorationMemoryHealthyDecodeClearsOnlyRates(t *testing.T) {
	gates, clock := newExplorationMemoryDirectory()
	session := gates.Attach("session")
	ref := gates.ReferenceForSession(session, "session")
	for i := range 5 {
		gates.RecordFirstContentDecodeObservation(ref, explicitDecodeObservation(explorationMemoryModel, 10, int64(i+1), clock.Now()), 80, clock.Now())
		gates.RecordFirstContentDecodeObservation(ref, explicitDecodeObservation("other-model", 11, int64(i+1), clock.Now()), 80, clock.Now())
	}
	gates.RecordFirstContentExplorationOutcome("session", explorationMemoryModel, false)
	view := gates.ViewForSession(nil, "session")
	before := view.Exploration(explorationMemoryModel, clock.Now())
	gates.RecordFirstContentDecodeObservation(ref, explicitDecodeObservation(explorationMemoryModel, 39.9, 6, clock.Now()), 80, clock.Now())
	if got := view.Exploration(explorationMemoryModel, clock.Now()); got.DecodeSamples != 6 {
		t.Fatalf("below-half-fleet observation cleared memory: %+v", got)
	}
	gates.RecordFirstContentDecodeObservation(ref, explicitDecodeObservation(explorationMemoryModel, 40, 7, clock.Now()), 80, clock.Now())
	if got := view.Exploration(explorationMemoryModel, clock.Now()); got.DecodeSamples != 0 || got.DecodeMedian != 0 || !got.Suppressed {
		t.Fatalf("healthy decode must clear rates, not failure backoff: %+v", got)
	}
	if got := view.Exploration("other-model", clock.Now()); got.DecodeSamples != 5 || !got.RememberedSlow(80) {
		t.Fatalf("healthy observation cleared another model: %+v", got)
	}
	if before.DecodeSamples != 5 || !before.RememberedSlow(80) || !before.Suppressed {
		t.Fatal("the copied exploration view changed with its gate")
	}
	// Without a fleet baseline even a fast rate is evidence, not recovery proof.
	gates.RecordFirstContentDecodeObservation(ref, explicitDecodeObservation(explorationMemoryModel, 100, 8, clock.Now()), 0, clock.Now())
	if got := view.Exploration(explorationMemoryModel, clock.Now()); got.DecodeSamples != 1 {
		t.Fatalf("unknown fleet median discarded a valid observation: %+v", got)
	}
}

func TestFirstContentExplorationMemorySweepTTL(t *testing.T) {
	gates, clock := newExplorationMemoryDirectory()
	session := gates.Attach("session")
	gates.Bind(session, "serial:explore", "")
	ref := gates.ReferenceForSession(session, "session")
	for i := range 5 {
		gates.RecordFirstContentDecodeObservation(ref, explicitDecodeObservation(explorationMemoryModel, 10, int64(i+1), clock.Now()), 80, clock.Now())
	}
	clock.Advance(6*time.Hour - time.Nanosecond)
	gates.Maintain(clock.Now())
	view := gates.ViewForSession(nil, "session")
	if got := view.Exploration(explorationMemoryModel, clock.Now()); got.DecodeSamples != 5 {
		t.Fatalf("memory expired before six hours: %+v", got)
	}
	gates.RecordFirstContentExplorationOutcome("session", "active-model", false)
	clock.Advance(time.Nanosecond)
	gates.Maintain(clock.Now())
	if got := view.Exploration(explorationMemoryModel, clock.Now()); got != (identitygate.ExplorationView{}) {
		t.Fatalf("six-hour memory survived pruning or a read refreshed it: %+v", got)
	}
	if !view.Exploration("active-model", clock.Now()).Suppressed {
		t.Fatal("sweep discarded active suppression")
	}
	// Identity memory retains a disconnected gate after ordinary idle grace.
	gates.Detach(session, "serial:explore")
	clock.Advance(time.Hour)
	if report := gates.Maintain(clock.Now()); report.Retained != 1 || report.Retired != 0 {
		t.Fatalf("disconnected exploration memory retired too soon: %+v", report)
	}
	clock.Advance(5 * time.Hour)
	if report := gates.Maintain(clock.Now()); report.Retained != 0 || report.Retired != 1 || report.RetiredIndexed != 0 {
		t.Fatalf("expired exploration memory retained its gate: %+v", report)
	}
}

func TestFirstContentExplorationMemoryMigrationKeepsStricterStateAndNewerRates(t *testing.T) {
	for _, newerSource := range []bool{false, true} {
		name := "newer-destination"
		if newerSource {
			name = "newer-source"
		}
		t.Run(name, func(t *testing.T) {
			gates, clock := newExplorationMemoryDirectory()
			source := gates.Attach("source")
			destination := gates.Attach("destination")
			gates.Bind(source, "sekey:explore", "v1")
			gates.Bind(destination, "serial:explore", "v1")
			sourceRef := gates.ReferenceForSession(source, "source")
			for range 3 {
				gates.RecordFirstContentExplorationOutcome("source", explorationMemoryModel, false)
			}
			for i := range 5 {
				gates.RecordFirstContentDecodeObservation(sourceRef, explicitDecodeObservation(explorationMemoryModel, 10, int64(i+1), clock.Now()), 100, clock.Now())
			}
			clock.Advance(18 * time.Minute)
			gates.RecordFirstContentExplorationOutcome("destination", explorationMemoryModel, false)
			for i := range 5 {
				gates.RecordFirstContentDecodeObservation(gates.ReferenceForSession(destination, "destination"), explicitDecodeObservation(explorationMemoryModel, 30, int64(i+1), clock.Now()), 100, clock.Now())
			}
			clock.Advance(time.Second)
			wantMedian, wantSamples := 30.0, 5
			if newerSource {
				gates.RecordFirstContentDecodeObservation(sourceRef, explicitDecodeObservation(explorationMemoryModel, 10, 6, clock.Now()), 100, clock.Now())
				wantMedian, wantSamples = 10, 6
			}
			gates.Bind(source, "serial:explore", "v1")
			view := gates.ViewForSession(nil, "source")
			assertExplorationSuppression(t, view, clock.Now(), 5*time.Minute-time.Second)
			if got := view.Exploration(explorationMemoryModel, clock.Now()); got.DecodeMedian != wantMedian || got.DecodeSamples != wantSamples {
				t.Fatalf("migration did not choose newer rates: %+v", got)
			}
			// The destination's later expiry and the source's higher level both survive.
			gates.RecordFirstContentExplorationOutcome("source", explorationMemoryModel, false)
			assertExplorationSuppression(t, view, clock.Now(), 40*time.Minute)
			gates.RecordFirstContentExplorationOutcome("source", explorationMemoryModel, true)
			assertExplorationSuppression(t, view, clock.Now(), 20*time.Minute)
		})
	}
}

func TestFirstContentExplorationMemoryRetainedReferencesFollowRebind(t *testing.T) {
	for _, shared := range []bool{false, true} {
		name := "orphan-forward"
		if shared {
			name = "shared-source"
		}
		t.Run(name, func(t *testing.T) {
			gates, clock := newExplorationMemoryDirectory()
			session := gates.Attach("session")
			gates.Bind(session, "sekey:explore", "v1")
			if shared {
				gates.Bind(gates.Attach("sibling"), "sekey:explore", "v1")
			}
			ref := gates.ReferenceForSession(session, "session")
			stale := gates.ViewForSession(session, "session")
			for i := range 5 {
				gates.RecordFirstContentDecodeObservation(ref, explicitDecodeObservation(explorationMemoryModel, 10, int64(i+1), clock.Now()), 80, clock.Now())
			}
			gates.RecordFirstContentExplorationOutcome("session", explorationMemoryModel, false)
			gates.Bind(session, "serial:explore", "v1")
			target := gates.ViewForSession(nil, "session")
			if shared {
				if got := gates.ViewForSession(nil, "sibling").Exploration(explorationMemoryModel, clock.Now()); got != (identitygate.ExplorationView{}) {
					t.Fatalf("shared source retained migrated state: %+v", got)
				}
				if !stale.Confirm() || !stale.SameIdentity(target) {
					t.Fatal("the routing view did not confirm its session's new identity")
				}
			} else if stale.Exploration(explorationMemoryModel, clock.Now()) != target.Exploration(explorationMemoryModel, clock.Now()) {
				t.Fatal("stale routing view did not follow the orphan forward")
			}
			gates.RecordFirstContentDecodeObservation(ref, explicitDecodeObservation(explorationMemoryModel, 11, 6, clock.Now()), 80, clock.Now())
			if got := target.Exploration(explorationMemoryModel, clock.Now()); got.DecodeSamples != 6 {
				t.Fatalf("stale observation missed the rebound identity: %+v", got)
			}
			// A cleared source flag must not short-circuit recovery on its new identity.
			gates.RecordFirstContentDecodeObservation(ref, explicitDecodeObservation(explorationMemoryModel, 40, 7, clock.Now()), 80, clock.Now())
			if got := target.Exploration(explorationMemoryModel, clock.Now()); got.DecodeSamples != 0 || !got.Suppressed {
				t.Fatalf("stale recovery did not clear the live gate's rates: %+v", got)
			}
		})
	}
}

func TestFirstContentExplorationMemoryEmptyViewFollowsForward(t *testing.T) {
	gates, clock := newExplorationMemoryDirectory()
	session := gates.Attach("session")
	stale := gates.ViewForSession(session, "session")
	destination := gates.Attach("destination")
	gates.Bind(destination, "serial:explore", "v1")
	gates.RecordFirstContentExplorationOutcome("destination", explorationMemoryModel, false)
	gates.Bind(session, "serial:explore", "v1")
	if !stale.Exploration(explorationMemoryModel, clock.Now()).Suppressed {
		t.Fatal("empty pre-migration flag hid the destination's suppression")
	}
}

func TestFirstContentExplorationMemoryDisconnectedReferencesFollowEnrichment(t *testing.T) {
	gates, clock := newExplorationMemoryDirectory()
	session := gates.Attach("session")
	enriched := gates.Attach("enriched")
	for _, s := range []*identitygate.Session{session, enriched, gates.Attach("sibling")} {
		gates.Bind(s, "sekey:explore", "v1")
	}
	liveRef := gates.ReferenceForSession(session, "session")
	for i := range 5 {
		gates.RecordFirstContentDecodeObservation(liveRef, explicitDecodeObservation(explorationMemoryModel, 10, int64(i+1), clock.Now()), 80, clock.Now())
	}
	gates.Detach(session, "sekey:explore")
	cachedRef := gates.ResolveSession("session", false)
	gates.Bind(enriched, "serial:explore", "v1")
	for i, ref := range []identitygate.Reference{liveRef, cachedRef} {
		gates.RecordFirstContentDecodeObservation(ref, explicitDecodeObservation(explorationMemoryModel, 11, int64(6+i), clock.Now()), 80, clock.Now())
	}
	if got := gates.ViewForSession(nil, "enriched").Exploration(explorationMemoryModel, clock.Now()); got.DecodeSamples != 7 {
		t.Fatalf("disconnected reference lost the enrichment redirect: %+v", got)
	}
	if got := gates.ViewForSession(nil, "sibling").Exploration(explorationMemoryModel, clock.Now()); got != (identitygate.ExplorationView{}) {
		t.Fatalf("trailing observations polluted the old shared identity: %+v", got)
	}
	gates.RecordFirstContentExplorationOutcome("session", explorationMemoryModel, false)
	if !gates.ViewForSession(nil, "enriched").Exploration(explorationMemoryModel, clock.Now()).Suppressed {
		t.Fatal("a trailing exploration outcome missed the enriched identity")
	}
}

func TestFirstContentExplorationMemoryRetiredReferenceResolvesAgain(t *testing.T) {
	gates, clock := newExplorationMemoryDirectory()
	ref := gates.ResolveIdentity("serial:explore")
	stale := gates.ViewReference(ref)
	gates.RecordFirstContentDecodeObservation(ref, explicitDecodeObservation(explorationMemoryModel, 10, 1, clock.Now()), 80, clock.Now())
	clock.Advance(6 * time.Hour)
	if report := gates.Maintain(clock.Now()); report.Retired != 1 || report.Retained != 0 {
		t.Fatalf("setup did not retire the expired identity: %+v", report)
	}
	gates.RecordFirstContentDecodeObservation(ref, explicitDecodeObservation(explorationMemoryModel, 11, 2, clock.Now()), 80, clock.Now())
	current := gates.ViewIdentity("serial:explore")
	if !current.Present() || current.SameIdentity(stale) || current.Exploration(explorationMemoryModel, clock.Now()).DecodeSamples != 1 {
		t.Fatal("recorder wrote to retired memory instead of the indexed identity")
	}
	if got := stale.Exploration(explorationMemoryModel, clock.Now()); got != (identitygate.ExplorationView{}) {
		t.Fatalf("retired gate received a trailing observation: %+v", got)
	}
}

func TestFirstContentExplorationMemoryReconnectAndVersionReset(t *testing.T) {
	gates, clock := newExplorationMemoryDirectory()
	session := gates.Attach("session")
	gates.Bind(session, "serial:explore", "v1")
	ref := gates.ReferenceForSession(session, "session")
	for i := range 5 {
		gates.RecordFirstContentDecodeObservation(ref, explicitDecodeObservation(explorationMemoryModel, 10, int64(i+1), clock.Now()), 80, clock.Now())
	}
	gates.RecordFirstContentExplorationOutcome("session", explorationMemoryModel, false)
	gates.Detach(session, "serial:explore")
	session = gates.Attach("reconnected")
	gates.Bind(session, "serial:explore", "v1")
	view := gates.ViewForSession(nil, "reconnected")
	before := view.Exploration(explorationMemoryModel, clock.Now())
	if !before.Suppressed || !before.RememberedSlow(80) {
		t.Fatalf("reconnect lost identity memory: %+v", before)
	}
	for _, version := range []string{"", "v1"} {
		gates.ObserveVersion(session, version)
		if got := view.Exploration(explorationMemoryModel, clock.Now()); got != before {
			t.Fatalf("version %q changed existing memory: %+v", version, got)
		}
	}
	for _, version := range []string{"v2", "v3"} {
		gates.ObserveVersion(session, version)
		if got := view.Exploration(explorationMemoryModel, clock.Now()); got != (identitygate.ExplorationView{}) {
			t.Fatalf("new binary %s retained exploration memory: %+v", version, got)
		}
		// Even the rapid v3 change clears memory despite fault-reset throttling.
		gates.RecordFirstContentExplorationOutcome("reconnected", explorationMemoryModel, false)
		assertExplorationSuppression(t, view, clock.Now(), 5*time.Minute)
		ref = gates.ReferenceForSession(session, "reconnected")
		gates.RecordFirstContentDecodeObservation(ref, explicitDecodeObservation(explorationMemoryModel, 10, 1, clock.Now()), 80, clock.Now())
	}
}

func TestFirstContentExplorationMemoryHealthyReadFastPath(t *testing.T) {
	for _, reset := range []string{"new", "version", "sweep"} {
		t.Run(reset, func(t *testing.T) {
			var block atomic.Bool
			entered, release, held := make(chan struct{}), make(chan struct{}), make(chan struct{})
			options := identitygate.DefaultOptions()
			options.Now = func() time.Time {
				if block.CompareAndSwap(true, false) {
					close(entered)
					<-release
				}
				return time.Now()
			}
			gates := identitygate.New(testLogger(), &options)
			session := gates.Attach("session")
			gates.Bind(session, "serial:explore", "v1")
			ref := gates.ReferenceForSession(session, "session")
			now := time.Now()
			if reset != "new" {
				gates.RecordFirstContentDecodeObservation(ref, explicitDecodeObservation(explorationMemoryModel, 10, 1, now.Add(-6*time.Hour)), 80, now.Add(-6*time.Hour))
				if reset == "version" {
					gates.ObserveVersion(session, "v2")
				} else {
					gates.Maintain(now)
				}
			}
			// Healthy writes retain a mergeable tombstone and replay watermark.
			// These require serialization, but must not slow down routing reads.
			gates.RecordFirstContentDecodeObservation(ref, explicitDecodeObservation(explorationMemoryModel, 40, 2, now), 80, now)
			view := gates.ViewForSession(session, "session")
			var waits atomic.Int32
			gates.SetGateWaitObserver(func(string, time.Duration) { waits.Add(1) })
			block.Store(true)
			go func() {
				defer close(held)
				// The real neutral-outcome recorder samples Now while holding gate.mu.
				gates.RecordProviderOutcomeRef(ref, false, 429, "")
			}()
			<-entered
			defer func() {
				close(release)
				<-held
			}()
			done := make(chan identitygate.ExplorationView, 1)
			go func() {
				done <- view.Exploration(explorationMemoryModel, now)
			}()
			select {
			case got := <-done:
				if got != (identitygate.ExplorationView{}) || waits.Load() != 0 {
					t.Fatalf("healthy-only routing view waited: %+v, waits=%d", got, waits.Load())
				}
			case <-time.After(5 * time.Second):
				t.Fatal("healthy-only routing snapshot blocked on the held gate")
			}
		})
	}
}

func TestFirstContentExplorationMemoryEmptyInputs(t *testing.T) {
	gates, clock := newExplorationMemoryDirectory()
	gates.RecordFirstContentExplorationOutcome("", explorationMemoryModel, false)
	gates.RecordFirstContentExplorationOutcome("session", "", false)
	gates.RecordFirstContentDecodeObservation(identitygate.Reference{}, explicitDecodeObservation(explorationMemoryModel, 10, 1, clock.Now()), 80, clock.Now())
	if got := gates.ViewForSession(nil, "session").Exploration(explorationMemoryModel, clock.Now()); got != (identitygate.ExplorationView{}) {
		t.Fatalf("invalid input created memory: %+v", got)
	}
	if got := (identitygate.View{}).Exploration(explorationMemoryModel, clock.Now()); got != (identitygate.ExplorationView{}) {
		t.Fatalf("zero view returned memory: %+v", got)
	}
	if report := gates.Maintain(clock.Now()); report.Retained != 0 {
		t.Fatalf("empty inputs allocated an identity: %+v", report)
	}
}
