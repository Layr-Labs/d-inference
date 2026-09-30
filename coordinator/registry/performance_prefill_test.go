package registry

import (
	"math"
	"testing"
	"time"
)

func TestResolvePrefillTPSKeepsQualifiedRate(t *testing.T) {
	p, profile := reviewedProfileFixture(t)
	profile.BatchCurve = []servingBatchPoint{
		{Width: 1, DecodeP10TPS: 90, AggregateDecodeTPS: 100, PrefillTPS: 6000, FirstContentP95MS: 1200},
		{Width: 4, DecodeP10TPS: 50, AggregateDecodeTPS: 250, PrefillTPS: 3000, FirstContentP95MS: 1500},
		{Width: 16, DecodeP10TPS: 35, AggregateDecodeTPS: 700, PrefillTPS: 1000, FirstContentP95MS: 2800},
	}
	r := New(testLogger())
	for _, tc := range []struct {
		name     string
		running  int
		observed float64
		want     float64
	}{
		{"solo with hot EWMA", 0, 18000, 6000},
		{"intermediate width with hot EWMA", 2, 18000, 3000},
		{"largest qualified width with hot EWMA", 15, 18000, 1000},
		{"solo with slower EWMA", 0, 500, 6000},
	} {
		t.Run(tc.name, func(t *testing.T) {
			now := time.Now()
			r.mu.RLock()
			p.mu.Lock()
			p.PrefillTPS = 700
			p.BackendCapacity.Slots[0].State = "idle"
			p.BackendCapacity.Slots[0].NumRunning = tc.running
			p.BackendCapacity.Slots[0].ObservedPrefillTPS = tc.observed
			var snap routingSnapshot
			r.fillRoutingSnapshotPLocked(&snap, p, profile.ModelID, now)
			p.mu.Unlock()
			r.mu.RUnlock()
			if snap.performanceProfile != profile {
				t.Fatal("exact reviewed identity did not reach routing snapshot")
			}
			if got := resolvePrefillTPS(&snap); got != tc.want {
				t.Fatalf("prefill TPS = %v, want qualified %v", got, tc.want)
			}
			if tc.running == 0 {
				candidate := routingCandidate{snapshot: snap}
				r.estimateFirstContent(&candidate, &PendingRequest{EstimatedPromptTokens: 6000, RequestedMaxTokens: 1}, now)
				want := firstContentHandoffMs + 6000/tc.want*1000 + 1000/profile.BatchCurve[0].DecodeP10TPS
				if math.Abs(candidate.firstContent.ExpectedMs-want) > 1e-6 {
					t.Fatalf("first-content forecast = %v ms, want qualified %v ms", candidate.firstContent.ExpectedMs, want)
				}
			}
		})
	}
}

func TestResolvePrefillTPSFallsBackWithoutQualifiedPoint(t *testing.T) {
	for _, noPoint := range []string{"unmatched artifact", "width beyond qualification"} {
		t.Run(noPoint, func(t *testing.T) {
			p, profile := reviewedProfileFixture(t)
			r := New(testLogger())
			r.mu.RLock()
			p.mu.Lock()
			p.PrefillTPS = 700
			p.BackendCapacity.Slots[0].ObservedPrefillTPS = 18000
			if noPoint == "unmatched artifact" {
				p.Models[0].WeightHash = "unverified"
			} else {
				p.BackendCapacity.Slots[0].NumRunning = profile.MaxConcurrency
			}
			var snap routingSnapshot
			r.fillRoutingSnapshotPLocked(&snap, p, profile.ModelID, time.Now())
			p.mu.Unlock()
			r.mu.RUnlock()
			if got := resolvePrefillTPS(&snap); got != 18000 {
				t.Fatalf("live fallback = %v, want 18000", got)
			}
			snap.observedPrefillTPS = 0
			if got := resolvePrefillTPS(&snap); got != 700 {
				t.Fatalf("static fallback = %v, want 700", got)
			}
		})
	}
}
