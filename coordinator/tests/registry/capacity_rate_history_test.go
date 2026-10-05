package registry_test

import (
	"fmt"
	"math"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/identitygate"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// Identity enrichment merges stale source evidence into an already-fresh
// destination. All four histories must remain chronological across the real
// sekey -> serial rebind, including the rate evidence used by maintenance.
func TestFaultTimestampHistoriesStayOrderedAcrossIdentityRebind(t *testing.T) {
	clock := time.Now()
	r, gates := newCapacityRateRegistry(func() time.Time { return clock })
	const (
		provider  = "rate-rebind-session"
		model     = "gemma-4-26b-qat-4bit"
		publicKey = "PK-RATE-REBIND"
		serial    = "SER-RATE-REBIND"
	)

	p := makeSchedulerProvider(t, r, provider, model, 100)
	p.SetAttestationResult(&attestation.VerificationResult{Valid: true, PublicKey: publicKey})
	oldID := "sekey:" + publicKey
	newID := "serial:" + serial
	if got := gates.FaultKeyForSession(provider); got != oldID {
		t.Fatalf("initial fault key = %q, want %q", got, oldID)
	}

	now := time.Now()
	expired := now.Add(-identitygate.CapacityRateWindow - time.Minute)
	fresh := now.Add(-time.Minute)
	for _, evidence := range []struct {
		identity string
		at       time.Time
	}{{oldID, expired}, {newID, fresh}} {
		clock = evidence.at
		// Accept first so the same-time reject remains in the strike history.
		ref, _, _ := gates.PrepareCapacityAccept(evidence.identity, model, true)
		gates.ApplyCapacityAccept(ref, model, clock, true, time.Time{}, 0, false)
		gates.RecordCapacityRejectProjected(evidence.identity, model, true, false, false)
		gates.RecordInferenceError(evidence.identity, model, 500, "base")
	}
	for i := 0; i < 1024; i++ {
		identity := fmt.Sprintf("expired-rate-%d", i)
		clock = expired
		ref, _, _ := gates.PrepareCapacityAccept(identity, model, true)
		gates.ApplyCapacityAccept(ref, model, clock, true, time.Time{}, 0, false)
		gates.RecordCapacityRejectProjected(identity, model, true, false, false)
		// A neutral outcome updates activity without feeding the health ring.
		// Keep the original idle-grace-plus-one-minute activity age separately
		// from the six-minute-old rate evidence.
		clock = identitygate.DefaultRetention(now).IdleBefore.Add(-time.Minute)
		gates.RecordProviderOutcome(identity, false, 429, "")
	}

	clock = now
	p.SetAttestationResult(&attestation.VerificationResult{
		Valid: true, PublicKey: publicKey, SerialNumber: serial,
	})
	if got := gates.FaultKeyForSession(provider); got != newID {
		t.Fatalf("enriched fault key = %q, want %q", got, newID)
	}

	view := gates.ViewIdentity(newID)
	mergedInference, _ := view.InferenceHistory(model, "base")
	mergedCapacity := view.CapacityAssessment(model).Strikes
	mergedRejects, mergedAccepts := view.RateHistory(model)
	old := gates.ViewIdentity(oldID)
	oldInference, _ := old.InferenceHistory(model, "base")
	oldCapacity := old.CapacityAssessment(model).Strikes
	oldRejects, oldAccepts := old.RateHistory(model)
	oldInferenceRemains, oldCapacityRemains := len(oldInference) != 0, len(oldCapacity) != 0
	oldRejectsRemain, oldAcceptsRemain := len(oldRejects) != 0, len(oldAccepts) != 0

	report := gates.Maintain(now)
	view = gates.ViewIdentity(newID)
	if !view.Present() {
		t.Fatal("the live identity's gate must survive the sweep")
	}
	assessment := view.CapacityRateAssessment(model, now)
	freshRejects, freshAccepts := assessment.Rejects, assessment.Accepts
	if n := report.Retained; n > 8 {
		t.Fatalf("expired identities not swept: %d gates remain", n)
	}

	for name, history := range map[string][]time.Time{
		"inference strikes": mergedInference,
		"capacity strikes":  mergedCapacity,
		"rate rejects":      mergedRejects,
		"rate accepts":      mergedAccepts,
	} {
		if len(history) != 2 || history[0] != expired || history[1] != fresh {
			t.Errorf("%s after rebind = %v, want [expired, fresh]", name, history)
		}
	}
	if oldInferenceRemains || oldCapacityRemains || oldRejectsRemain || oldAcceptsRemain {
		t.Fatalf("source identity retained timestamp state: inference=%v capacity=%v rejects=%v accepts=%v",
			oldInferenceRemains, oldCapacityRemains, oldRejectsRemain, oldAcceptsRemain)
	}
	if freshRejects != 1 || freshAccepts != 1 {
		t.Fatalf("fresh migrated rate history was lost by bounded sweep: rejects=%d accepts=%d, want 1/1", freshRejects, freshAccepts)
	}
}

// Pruning runs while the gate lock is held. Once a hot pair reaches
// the five-minute horizon, an expired prefix is normal on nearly every accept;
// the helper must advance the slice rather than copy the whole live window back
// to index zero each time.
func TestPruneWindowedOutcomesDropsPrefixWithoutCompaction(t *testing.T) {
	now := time.Now()
	outcomes := []time.Time{
		now.Add(-identitygate.CapacityRateWindow - time.Second),
		now.Add(-time.Minute),
		now,
	}
	pruned := identitygate.PruneWindowedOutcomes(outcomes, now)
	if len(pruned) != 2 {
		t.Fatalf("pruned length = %d, want 2", len(pruned))
	}
	if &pruned[0] != &outcomes[1] {
		t.Fatal("pruning compacted the live window instead of advancing the expired prefix")
	}
}

func TestMergeChronologicalTimestampsPreservesEqualOutcomes(t *testing.T) {
	ts := time.Now()
	merged := identitygate.MergeChronologicalTimestamps([]time.Time{ts}, []time.Time{ts})
	if len(merged) != 2 || merged[0] != ts || merged[1] != ts {
		t.Fatalf("equal timestamp merge = %v, want two distinct outcomes", merged)
	}
}

// Rate calculation must depend only on the five-minute multiset, not whether
// the healthy traffic came before, after, or between the rejects.
func TestCapacityRateIsIndependentOfOutcomeOrder(t *testing.T) {
	const model = "gemma-4-26b-qat-4bit"
	for _, tc := range []struct {
		name   string
		record func(r *production.Registry, provider string)
	}{
		{
			name: "accepts first",
			record: func(r *production.Registry, provider string) {
				seedRateOutcomes(r, provider, model, 0, 12)
				seedRateOutcomes(r, provider, model, 4, 0)
			},
		},
		{
			name: "rejects first",
			record: func(r *production.Registry, provider string) {
				seedRateOutcomes(r, provider, model, 4, 12)
			},
		},
		{
			name: "interleaved",
			record: func(r *production.Registry, provider string) {
				for i := 0; i < 4; i++ {
					r.RecordCapacityReject(provider, model)
					for j := 0; j < 3; j++ {
						r.RecordCapacityAccept(provider, model)
					}
				}
			},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := production.New(testLogger())
			provider := "prov-order-" + tc.name
			tc.record(r, provider)
			rate, samples := r.CapacityRejectRate(provider, model)
			if samples != 16 || math.Abs(rate-0.25) > 1e-12 {
				t.Fatalf("rate window = (%v, %d), want (0.25, 16)", rate, samples)
			}
		})
	}
}

// Recent accepts must already be in the denominator when a pair records its
// first capacity reject. Otherwise a short reject burst after sustained healthy
// traffic reads as a 100% reject rate and applies the maximum derating penalty.
func TestCapacityRateFirstRejectIncludesRecentAccepts(t *testing.T) {
	r, gates := newCapacityRateRegistry(nil)
	const provider, model = "prov-pre-reject-accepts", "gemma-4-26b-qat-4bit"

	for i := 0; i < 100; i++ {
		if recorded := r.RecordCapacityAccept(provider, model); !recorded {
			t.Fatalf("healthy accept %d was not retained for a later reject window", i+1)
		}
	}
	if rate, samples := r.CapacityRejectRate(provider, model); rate != 0 || samples != 0 {
		t.Fatalf("accept-only history must stay observationally inactive: rate=%v samples=%d, want 0/0", rate, samples)
	}

	for i := 0; i < capacityRateMinSample; i++ {
		r.RecordCapacityReject(provider, model)
	}

	rate, samples := r.CapacityRejectRate(provider, model)
	wantRate := float64(capacityRateMinSample) / float64(100+capacityRateMinSample)
	if samples != 100+capacityRateMinSample {
		t.Fatalf("samples = %d, want %d recent accepts + rejects", samples, 100+capacityRateMinSample)
	}
	if math.Abs(rate-wantRate) > 1e-12 {
		t.Fatalf("rate = %v, want %v", rate, wantRate)
	}
	if penalty, _ := capacityRatePenaltyOf(gates, provider, model); penalty != 0 {
		t.Fatalf("penalty = %v at healthy-window rate %v, want 0", penalty, rate)
	}
}

// The first reject prunes accept-only history against the same strict window
// boundary: exactly-window-old outcomes are excluded, while a newer outcome is
// retained. Use a fixed clock so nanosecond boundary behavior is deterministic.
func TestCapacityRateFirstRejectPrunesExpiredAccepts(t *testing.T) {
	const provider, model = "prov-accept-window", "gemma-4-26b-qat-4bit"
	now := time.Now()
	clock := now
	r, gates := newCapacityRateRegistry(func() time.Time { return clock })

	for _, stamp := range []time.Time{
		now.Add(-identitygate.CapacityRateWindow - time.Nanosecond),
		now.Add(-identitygate.CapacityRateWindow),
		now.Add(-identitygate.CapacityRateWindow + time.Nanosecond),
	} {
		clock = stamp
		r.RecordCapacityAccept(provider, model)
	}
	clock = now
	r.RecordCapacityReject(provider, model)
	assessment := gates.ViewForSession(nil, provider).CapacityRateAssessment(model, now)
	rejects, accepts := assessment.Rejects, assessment.Accepts

	if rejects != 1 || accepts != 1 {
		t.Fatalf("windowed outcomes = rejects %d accepts %d, want 1/1", rejects, accepts)
	}
}
