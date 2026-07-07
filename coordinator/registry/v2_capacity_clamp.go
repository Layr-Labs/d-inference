package registry

import (
	"log/slog"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Version-keyed heartbeat sanity clamp — the permanent mixed-fleet audit of the
// v0.7.5 "one engine, fail loud" promise.
//
// Engine V2 providers (>= EIGENINFERENCE_V2_VERSION_FLOOR) truthfully report
// their engine concurrency cap (<= 4 by construction; the legacy scheduler and
// its silent-fallback cap of 24 are DELETED in v0.7.5). If a >=floor box ever
// heartbeats a chat-slot max_concurrency above the v2 ceiling again, the
// silent-legacy-fallback bug (2026-07-06 gemma postmortem, layers 5-6: first
// engine claims the whole KV budget -> later models fall back to the legacy
// scheduler -> cap 24, 2-3 tok/s at batch >=4) has RESURFACED in some form.
// This clamp (a) refuses to route on the bogus capacity by clamping the slot
// down to the ceiling, (b) logs at ERROR, and (c) fires a Datadog tripwire
// counter (via the api-layer hook) so the regression pages a dashboard instead
// of resurfacing as a throughput collapse.
//
// Below-floor providers are UNTOUCHED: their reported 24 is a real legacy
// cap (the per-model quality-concurrency caps are what actually bind them),
// and they keep today's clampBackendCapacity 24-ceiling behavior exactly.
// An empty EIGENINFERENCE_V2_VERSION_FLOOR disables the audit entirely
// (zero behavior change); an empty provider version is below any floor.

// defaultV2MaxConcurrencyCeiling is the ceiling applied to >=floor providers
// when EIGENINFERENCE_V2_MAX_CONCURRENCY_CEILING is unset. Matches the engine's
// productionMaxConcurrentRequests (4) — the v0.7.5 default box-wide cap.
const defaultV2MaxConcurrencyCeiling = 4

// v2VersionFloor / v2MaxConcurrencyCeiling are configured once at startup via
// SetV2ConcurrencyClamp (from EIGENINFERENCE_V2_VERSION_FLOOR /
// _V2_MAX_CONCURRENCY_CEILING) before the coordinator serves, then only read on
// the heartbeat ingest path — same lifecycle as prefillToDecodeRatio.
var (
	v2VersionFloor          = ""
	v2MaxConcurrencyCeiling = defaultV2MaxConcurrencyCeiling
)

// SetV2ConcurrencyClamp configures the version-keyed heartbeat concurrency
// clamp. An empty (or all-blank) floor disables it — today's behavior for the
// whole fleet. Ceilings < 1 are reset to the default (a ceiling of 0 would
// clamp every v2 slot to "unreported", disabling admission math). Must be
// called before serving starts (read-only on ingest paths thereafter).
func SetV2ConcurrencyClamp(floor string, ceiling int) {
	v2VersionFloor = strings.TrimSpace(floor)
	if ceiling < 1 {
		ceiling = defaultV2MaxConcurrencyCeiling
	}
	v2MaxConcurrencyCeiling = ceiling
}

// V2ConcurrencyClampConfig returns the configured (floor, ceiling) pair
// (tests pin the setter's sanitization through it).
func V2ConcurrencyClampConfig() (string, int) {
	return v2VersionFloor, v2MaxConcurrencyCeiling
}

// providerAtOrAboveV2Floor reports whether a provider binary version is at or
// above the configured v2 floor. False when the floor is unset (feature
// disabled) and for an EMPTY provider version — a non-reporting binary is below
// any floor (same convention as the capability version floors), even a floor
// that parses as all-zeros.
func providerAtOrAboveV2Floor(version string) bool {
	if v2VersionFloor == "" || version == "" {
		return false
	}
	return CompareVersions(version, v2VersionFloor) >= 0
}

// v2ConcurrencyTrip records one slot the v2 clamp had to correct: the model and
// the max_concurrency the provider actually reported (pre-clamp). Surfaced to
// the api layer through the tripwire hook for the Datadog counter.
type v2ConcurrencyTrip struct {
	Model    string
	Reported int
}

// clampV2MaxConcurrency applies the version-keyed ceiling to every slot of a
// >=floor provider's reported backend capacity, returning one trip per clamped
// slot. It runs BEFORE the general clampBackendCapacity pass so the trip
// carries the provider's original report (not the 24-clamped value); the
// general pass then still normalizes negatives and below-floor providers
// exactly as today. MaxConcurrency == 0 means "not reported" (omitempty) and is
// never touched. No-op (nil) when the floor is unset or the provider is below
// it.
func clampV2MaxConcurrency(logger *slog.Logger, providerID, version string, bc *protocol.BackendCapacity) []v2ConcurrencyTrip {
	if bc == nil || !providerAtOrAboveV2Floor(version) {
		return nil
	}
	var trips []v2ConcurrencyTrip
	for i := range bc.Slots {
		s := &bc.Slots[i]
		if s.MaxConcurrency <= v2MaxConcurrencyCeiling {
			continue
		}
		trips = append(trips, v2ConcurrencyTrip{Model: s.Model, Reported: s.MaxConcurrency})
		if logger != nil {
			logger.Error("v2 provider reported legacy-scale max_concurrency — silent-legacy-fallback tripwire",
				"provider_id", providerID,
				"provider_version", version,
				"model", s.Model,
				"reported", s.MaxConcurrency,
				"clamped", v2MaxConcurrencyCeiling,
				"v2_version_floor", v2VersionFloor,
			)
		}
		s.MaxConcurrency = v2MaxConcurrencyCeiling
	}
	return trips
}

// SetV2ClampTripwireHook registers an optional callback fired (off the registry
// locks) whenever the version-keyed heartbeat clamp corrects a slot. The api
// layer uses it to emit the Datadog tripwire counter. Set once at startup
// before providers connect; nil clears it. Thread-safe.
func (r *Registry) SetV2ClampTripwireHook(fn func(providerID, version, model string, reported int)) {
	r.mu.Lock()
	r.onV2ClampTrip = fn
	r.mu.Unlock()
}

// fireV2ClampTrips invokes the tripwire hook for each clamped slot. Called from
// Heartbeat with NO locks held (the hook may do I/O — mirror of the
// hard-untrust hook contract).
func (r *Registry) fireV2ClampTrips(providerID, version string, trips []v2ConcurrencyTrip) {
	if len(trips) == 0 {
		return
	}
	r.mu.RLock()
	hook := r.onV2ClampTrip
	r.mu.RUnlock()
	if hook == nil {
		return
	}
	for _, trip := range trips {
		hook(providerID, version, trip.Model, trip.Reported)
	}
}
