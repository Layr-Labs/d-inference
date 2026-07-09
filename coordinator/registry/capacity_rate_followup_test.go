package registry

import (
	"fmt"
	"math"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
)

// Recent accepts must already be in the denominator when a pair records its
// first capacity reject. Otherwise a short reject burst after sustained healthy
// traffic reads as a 100% reject rate and applies the maximum derating penalty.
func TestCapacityRateFirstRejectIncludesRecentAccepts(t *testing.T) {
	r := New(testLogger())
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
	if penalty, _ := capacityRatePenaltyOf(r, provider, model); penalty != 0 {
		t.Fatalf("penalty = %v at healthy-window rate %v, want 0", penalty, rate)
	}
}

// The first reject prunes accept-only history against the same strict window
// boundary: exactly-window-old outcomes are excluded, while a newer outcome is
// retained. Use a fixed clock so nanosecond boundary behavior is deterministic.
func TestCapacityRateFirstRejectPrunesExpiredAccepts(t *testing.T) {
	r := New(testLogger())
	const provider, model = "prov-accept-window", "gemma-4-26b-qat-4bit"
	now := time.Now()
	key := capacityRejectKey{ProviderID: provider, ModelID: model}

	r.mu.Lock()
	r.capacityRateAccepts[key] = []time.Time{
		now.Add(-capacityRateWindow - time.Nanosecond),
		now.Add(-capacityRateWindow),
		now.Add(-capacityRateWindow + time.Nanosecond),
	}
	r.recordCapacityRateRejectLocked(key, now)
	rejects := countInWindow(r.capacityRateRejects[key], now)
	accepts := countInWindow(r.capacityRateAccepts[key], now)
	r.mu.Unlock()

	if rejects != 1 || accepts != 1 {
		t.Fatalf("windowed outcomes = rejects %d accepts %d, want 1/1", rejects, accepts)
	}
}

// Pruning runs while the global registry lock is held. Once a hot pair reaches
// the five-minute horizon, an expired prefix is normal on nearly every accept;
// the helper must advance the slice rather than copy the whole live window back
// to index zero each time.
func TestPruneWindowedOutcomesDropsPrefixWithoutCompaction(t *testing.T) {
	now := time.Now()
	outcomes := []time.Time{
		now.Add(-capacityRateWindow - time.Second),
		now.Add(-time.Minute),
		now,
	}
	pruned := pruneWindowedOutcomes(outcomes, now)
	if len(pruned) != 2 {
		t.Fatalf("pruned length = %d, want 2", len(pruned))
	}
	if &pruned[0] != &outcomes[1] {
		t.Fatal("pruning compacted the live window instead of advancing the expired prefix")
	}
}

func TestMergeChronologicalTimestampsPreservesEqualOutcomes(t *testing.T) {
	ts := time.Now()
	merged := mergeChronologicalTimestamps([]time.Time{ts}, []time.Time{ts})
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
		record func(r *Registry, provider string)
	}{
		{
			name: "accepts first",
			record: func(r *Registry, provider string) {
				seedRateOutcomes(r, provider, model, 0, 12)
				seedRateOutcomes(r, provider, model, 4, 0)
			},
		},
		{
			name: "rejects first",
			record: func(r *Registry, provider string) {
				seedRateOutcomes(r, provider, model, 4, 12)
			},
		},
		{
			name: "interleaved",
			record: func(r *Registry, provider string) {
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
			r := New(testLogger())
			provider := "prov-order-" + tc.name
			tc.record(r, provider)
			rate, samples := r.CapacityRejectRate(provider, model)
			if samples != 16 || math.Abs(rate-0.25) > 1e-12 {
				t.Fatalf("rate window = (%v, %d), want (0.25, 16)", rate, samples)
			}
		})
	}
}

// Identity enrichment can merge a stale source history into a destination
// that already has fresh state from a previous connection. Every timestamp
// history must remain oldest-to-newest because the bounded-map sweeps use the
// tail as the newest outcome. This exercises the real sekey -> serial rebind
// and the >1024 cleanup consequence for both rate maps.
func TestFaultTimestampHistoriesStayOrderedAcrossIdentityRebind(t *testing.T) {
	r := New(testLogger())
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
	if got := faultKeyOf(r, provider); got != oldID {
		t.Fatalf("initial fault key = %q, want %q", got, oldID)
	}

	now := time.Now()
	expired := now.Add(-capacityRateWindow - time.Minute)
	fresh := now.Add(-time.Minute)
	oldRateKey := capacityRejectKey{ProviderID: oldID, ModelID: model}
	newRateKey := capacityRejectKey{ProviderID: newID, ModelID: model}
	oldInferenceKey := inferenceErrorKey{ProviderID: oldID, ModelID: model, Shape: "base"}
	newInferenceKey := inferenceErrorKey{ProviderID: newID, ModelID: model, Shape: "base"}

	r.mu.Lock()
	r.inferenceErrorStrikes[oldInferenceKey] = []time.Time{expired}
	r.inferenceErrorStrikes[newInferenceKey] = []time.Time{fresh}
	r.capacityRejectStrikes[oldRateKey] = []time.Time{expired}
	r.capacityRejectStrikes[newRateKey] = []time.Time{fresh}
	r.capacityRateRejects[oldRateKey] = []time.Time{expired}
	r.capacityRateRejects[newRateKey] = []time.Time{fresh}
	r.capacityRateAccepts[oldRateKey] = []time.Time{expired}
	r.capacityRateAccepts[newRateKey] = []time.Time{fresh}
	for i := 0; i < 1024; i++ {
		key := capacityRejectKey{ProviderID: fmt.Sprintf("expired-rate-%d", i), ModelID: model}
		r.capacityRateRejects[key] = []time.Time{expired}
		r.capacityRateAccepts[key] = []time.Time{expired}
	}
	r.mu.Unlock()

	p.SetAttestationResult(&attestation.VerificationResult{
		Valid: true, PublicKey: publicKey, SerialNumber: serial,
	})
	if got := faultKeyOf(r, provider); got != newID {
		t.Fatalf("enriched fault key = %q, want %q", got, newID)
	}

	r.mu.Lock()
	mergedInference := append([]time.Time(nil), r.inferenceErrorStrikes[newInferenceKey]...)
	mergedCapacity := append([]time.Time(nil), r.capacityRejectStrikes[newRateKey]...)
	mergedRejects := append([]time.Time(nil), r.capacityRateRejects[newRateKey]...)
	mergedAccepts := append([]time.Time(nil), r.capacityRateAccepts[newRateKey]...)
	_, oldInferenceRemains := r.inferenceErrorStrikes[oldInferenceKey]
	_, oldCapacityRemains := r.capacityRejectStrikes[oldRateKey]
	_, oldRejectsRemain := r.capacityRateRejects[oldRateKey]
	_, oldAcceptsRemain := r.capacityRateAccepts[oldRateKey]
	sweepCapacityRateMapLocked(r.capacityRateRejects, now)
	sweepCapacityRateMapLocked(r.capacityRateAccepts, now)
	freshRejects := countInWindow(r.capacityRateRejects[newRateKey], now)
	freshAccepts := countInWindow(r.capacityRateAccepts[newRateKey], now)
	r.mu.Unlock()

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
