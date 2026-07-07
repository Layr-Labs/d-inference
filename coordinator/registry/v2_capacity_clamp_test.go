package registry

import (
	"sync"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// enableV2ConcurrencyClamp configures the version-keyed heartbeat clamp for a
// test and restores the package defaults on cleanup (the knobs are
// startup-configured package vars, mirroring enablePerModelQualityCap's
// hygiene).
func enableV2ConcurrencyClamp(t *testing.T, floor string, ceiling int) {
	t.Helper()
	t.Cleanup(func() {
		v2VersionFloor = ""
		v2MaxConcurrencyCeiling = defaultV2MaxConcurrencyCeiling
	})
	SetV2ConcurrencyClamp(floor, ceiling)
}

// v2TripRecorder captures tripwire hook invocations.
type v2TripRecorder struct {
	mu    sync.Mutex
	trips []struct {
		providerID, version, model string
		reported                   int
	}
}

func (rec *v2TripRecorder) hook(providerID, version, model string, reported int) {
	rec.mu.Lock()
	defer rec.mu.Unlock()
	rec.trips = append(rec.trips, struct {
		providerID, version, model string
		reported                   int
	}{providerID, version, model, reported})
}

func (rec *v2TripRecorder) count() int {
	rec.mu.Lock()
	defer rec.mu.Unlock()
	return len(rec.trips)
}

// v2ClampHeartbeat drives the REAL heartbeat ingest path with a single slot
// reporting the given max_concurrency and returns the post-ingest value.
func v2ClampHeartbeat(t *testing.T, reg *Registry, id, model string, reportedMaxConcurrency int) int {
	t.Helper()
	reg.Heartbeat(id, &protocol.HeartbeatMessage{
		Type:   protocol.TypeHeartbeat,
		Status: "serving",
		BackendCapacity: &protocol.BackendCapacity{
			TotalMemoryGB: 64,
			Slots: []protocol.BackendSlotCapacity{
				{Model: model, State: "running", MaxConcurrency: reportedMaxConcurrency},
			},
		},
	})
	reg.mu.RLock()
	p := reg.providers[id]
	reg.mu.RUnlock()
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.BackendCapacity.Slots[0].MaxConcurrency
}

// TestV2ClampAtOrAboveFloorClampsAndTrips is the core tripwire regression: a
// >=floor provider heartbeating the legacy max_concurrency of 24 (the
// silent-legacy-fallback signature) is clamped to the v2 ceiling and the
// tripwire hook fires with the original report. Fails without the fix (the
// legacy clamp keeps any value <= 24 untouched for every provider).
func TestV2ClampAtOrAboveFloorClampsAndTrips(t *testing.T) {
	enableV2ConcurrencyClamp(t, "0.7.5", 4)
	reg := New(testLogger())
	rec := &v2TripRecorder{}
	reg.SetV2ClampTripwireHook(rec.hook)
	p := makeSchedulerProvider(t, reg, "v2-box", gptossBuild, 30)
	setProviderVersion(p, "0.7.5")

	if got := v2ClampHeartbeat(t, reg, "v2-box", gptossBuild, 24); got != 4 {
		t.Fatalf("post-heartbeat max_concurrency = %d, want 4 (clamped to the v2 ceiling)", got)
	}
	if rec.count() != 1 {
		t.Fatalf("tripwire fired %d times, want 1", rec.count())
	}
	trip := rec.trips[0]
	if trip.providerID != "v2-box" || trip.version != "0.7.5" || trip.model != gptossBuild || trip.reported != 24 {
		t.Fatalf("trip = %+v, want (v2-box, 0.7.5, %s, 24)", trip, gptossBuild)
	}

	// Above the floor (0.7.6 > 0.7.5) trips too.
	setProviderVersion(p, "0.7.6")
	if got := v2ClampHeartbeat(t, reg, "v2-box", gptossBuild, 24); got != 4 {
		t.Fatalf("0.7.6 post-heartbeat max_concurrency = %d, want 4", got)
	}
	if rec.count() != 2 {
		t.Fatalf("tripwire fired %d times, want 2", rec.count())
	}
}

// TestV2ClampOriginalReportSurvivesLegacyClamp: a >=floor provider reporting an
// out-of-range 30 is clamped straight to the v2 ceiling with the trip carrying
// the ORIGINAL 30 — not the 24 the legacy sanity clamp would have produced
// first.
func TestV2ClampOriginalReportSurvivesLegacyClamp(t *testing.T) {
	enableV2ConcurrencyClamp(t, "0.7.5", 4)
	reg := New(testLogger())
	rec := &v2TripRecorder{}
	reg.SetV2ClampTripwireHook(rec.hook)
	setProviderVersion(makeSchedulerProvider(t, reg, "v2-box", gptossBuild, 30), "0.7.5")

	if got := v2ClampHeartbeat(t, reg, "v2-box", gptossBuild, 30); got != 4 {
		t.Fatalf("post-heartbeat max_concurrency = %d, want 4", got)
	}
	if rec.count() != 1 || rec.trips[0].reported != 30 {
		t.Fatalf("trips = %+v, want one trip with reported=30", rec.trips)
	}
}

// TestV2ClampBelowFloorKeepsLegacyBehavior: below-floor providers keep today's
// clamp exactly — 24 passes through, out-of-range 30 clamps to the legacy 24
// (not the v2 ceiling), and the tripwire never fires.
func TestV2ClampBelowFloorKeepsLegacyBehavior(t *testing.T) {
	enableV2ConcurrencyClamp(t, "0.7.5", 4)
	reg := New(testLogger())
	rec := &v2TripRecorder{}
	reg.SetV2ClampTripwireHook(rec.hook)
	setProviderVersion(makeSchedulerProvider(t, reg, "legacy-box", gptossBuild, 30), "0.7.4")

	if got := v2ClampHeartbeat(t, reg, "legacy-box", gptossBuild, 24); got != 24 {
		t.Fatalf("below-floor max_concurrency = %d, want 24 (legacy report is real)", got)
	}
	if got := v2ClampHeartbeat(t, reg, "legacy-box", gptossBuild, 30); got != maxReportedMaxConcurrency {
		t.Fatalf("below-floor out-of-range report = %d, want the legacy ceiling %d", got, maxReportedMaxConcurrency)
	}
	if rec.count() != 0 {
		t.Fatalf("tripwire fired %d times for a below-floor provider, want 0", rec.count())
	}
}

// TestV2ClampEmptyVersionIsBelowFloor: a provider that reports no version at
// all sits below any floor (the trait-floor convention), so its 24 is treated
// as legacy — clamped only by the legacy 24 ceiling, no tripwire.
func TestV2ClampEmptyVersionIsBelowFloor(t *testing.T) {
	enableV2ConcurrencyClamp(t, "0.7.5", 4)
	reg := New(testLogger())
	rec := &v2TripRecorder{}
	reg.SetV2ClampTripwireHook(rec.hook)
	makeSchedulerProvider(t, reg, "versionless", gptossBuild, 30)

	if got := v2ClampHeartbeat(t, reg, "versionless", gptossBuild, 24); got != 24 {
		t.Fatalf("empty-version max_concurrency = %d, want 24", got)
	}
	if rec.count() != 0 {
		t.Fatalf("tripwire fired %d times for an empty-version provider, want 0", rec.count())
	}
}

// TestV2ClampDisabledWhenFloorEmpty: the default (empty floor env) is zero
// behavior change even for a v2-version provider reporting 24.
func TestV2ClampDisabledWhenFloorEmpty(t *testing.T) {
	enableV2ConcurrencyClamp(t, "", 4)
	reg := New(testLogger())
	rec := &v2TripRecorder{}
	reg.SetV2ClampTripwireHook(rec.hook)
	setProviderVersion(makeSchedulerProvider(t, reg, "v2-box", gptossBuild, 30), "0.7.5")

	if got := v2ClampHeartbeat(t, reg, "v2-box", gptossBuild, 24); got != 24 {
		t.Fatalf("floor-disabled max_concurrency = %d, want 24 (no behavior change)", got)
	}
	if rec.count() != 0 {
		t.Fatalf("tripwire fired %d times with the floor disabled, want 0", rec.count())
	}
}

// TestV2ClampAtOrBelowCeilingUntouched: a >=floor provider truthfully reporting
// at/below the ceiling (or omitting the field) is never clamped or counted.
func TestV2ClampAtOrBelowCeilingUntouched(t *testing.T) {
	enableV2ConcurrencyClamp(t, "0.7.5", 4)
	reg := New(testLogger())
	rec := &v2TripRecorder{}
	reg.SetV2ClampTripwireHook(rec.hook)
	setProviderVersion(makeSchedulerProvider(t, reg, "v2-box", gptossBuild, 30), "0.7.5")

	if got := v2ClampHeartbeat(t, reg, "v2-box", gptossBuild, 4); got != 4 {
		t.Fatalf("honest report = %d, want 4 untouched", got)
	}
	if got := v2ClampHeartbeat(t, reg, "v2-box", gptossBuild, 0); got != 0 {
		t.Fatalf("unreported (0) = %d, want 0 untouched", got)
	}
	if rec.count() != 0 {
		t.Fatalf("tripwire fired %d times for honest reports, want 0", rec.count())
	}
}

// TestSetV2ConcurrencyClampSanitizes: ceilings < 1 reset to the default and the
// floor is trimmed.
func TestSetV2ConcurrencyClampSanitizes(t *testing.T) {
	t.Cleanup(func() {
		v2VersionFloor = ""
		v2MaxConcurrencyCeiling = defaultV2MaxConcurrencyCeiling
	})
	SetV2ConcurrencyClamp("  0.7.5  ", 0)
	floor, ceiling := V2ConcurrencyClampConfig()
	if floor != "0.7.5" || ceiling != defaultV2MaxConcurrencyCeiling {
		t.Fatalf("config = (%q, %d), want (0.7.5, %d)", floor, ceiling, defaultV2MaxConcurrencyCeiling)
	}
}
