package store

import (
	"testing"
	"time"
)

func TestRouteCandidatesAndCapacitySamples_Memory(t *testing.T) {
	s := NewMemory(Config{})
	testRouteCandidatesAndCapacitySamples(t, s)
}

func TestRouteCandidatesAndCapacitySamples_Postgres(t *testing.T) {
	s := testPostgresStore(t)
	testRouteCandidatesAndCapacitySamples(t, s)
}

func testRouteCandidatesAndCapacitySamples(t *testing.T, s Store) {
	t.Helper()

	cands := []InferenceRouteCandidateRecord{
		{
			RequestID: "req-cal-1", Attempt: 0, ProviderID: "p-win",
			Rank: 0, Selected: true, Eligible: true,
			CostMs: 1200, StateMs: 0, QueueMs: 300, EffectiveTPS: 40, BatchSize: 2,
			ChipFamily: "M4", HardwareTier: "Max", MemoryGB: 64, SlotState: "running",
		},
		{
			RequestID: "req-cal-1", Attempt: 0, ProviderID: "p-lose",
			Rank: 1, Selected: false, Eligible: true,
			CostMs: 1800, HealthMs: 400, EffectiveTPS: 28, BatchSize: 3,
			ChipFamily: "M3", HardwareTier: "Pro", MemoryGB: 36, SlotState: "idle",
		},
		{
			RequestID: "req-cal-1", Attempt: 0, ProviderID: "p-full",
			Rank: -1, Selected: false, Eligible: false,
			RejectionReason: CandidateRejectCapacity, MemoryGB: 24, SlotState: "running",
		},
	}
	if err := s.RecordInferenceRouteCandidates(cands); err != nil {
		t.Fatalf("RecordInferenceRouteCandidates: %v", err)
	}
	got := s.InferenceRouteCandidatesSince(time.Time{})
	if len(got) != 3 {
		t.Fatalf("candidates = %d, want 3", len(got))
	}
	foundWin := false
	for _, rec := range got {
		if rec.ProviderID == "p-win" {
			foundWin = true
			if !rec.Selected || rec.CostMs != 1200 || rec.ChipFamily != "M4" {
				t.Fatalf("winner snapshot = %+v", rec)
			}
		}
		if rec.ProviderID == "p-full" && rec.RejectionReason != CandidateRejectCapacity {
			t.Fatalf("rejected reason = %q", rec.RejectionReason)
		}
	}
	if !foundWin {
		t.Fatal("winning candidate missing")
	}

	sample := &ProviderCapacitySample{
		ProviderID:         "p-win",
		ProviderVersion:    "0.8.13",
		HardwareChipFamily: "M4",
		HardwareTier:       "Max",
		MemoryGB:           64,
		BackendRunning:     2,
		ObservedDecodeTPS:  41.5,
		ThermalState:       "nominal",
		WedgeSuspected:     false,
	}
	if err := s.RecordProviderCapacitySample(sample); err != nil {
		t.Fatalf("RecordProviderCapacitySample: %v", err)
	}
	samples := s.ProviderCapacitySamplesSince(time.Time{})
	if len(samples) != 1 {
		t.Fatalf("capacity samples = %d, want 1", len(samples))
	}
	if samples[0].ProviderID != "p-win" || samples[0].ObservedDecodeTPS != 41.5 {
		t.Fatalf("sample = %+v", samples[0])
	}

	// Upsert on the same (request, attempt, provider) must not duplicate.
	cands[0].CostMs = 1100
	if err := s.RecordInferenceRouteCandidates(cands[:1]); err != nil {
		t.Fatalf("upsert candidates: %v", err)
	}
	got = s.InferenceRouteCandidatesSince(time.Time{})
	if len(got) != 3 {
		t.Fatalf("candidates after upsert = %d, want 3", len(got))
	}
	for _, rec := range got {
		if rec.ProviderID == "p-win" && rec.CostMs != 1100 {
			t.Fatalf("upserted winner cost = %f, want 1100", rec.CostMs)
		}
	}

	old := s.InferenceRouteCandidatesSince(time.Now().Add(time.Hour))
	if len(old) != 0 {
		t.Fatalf("future candidate window = %d, want 0", len(old))
	}
}

func TestMergeInferenceRouteOutcomeCacheAndDimensions(t *testing.T) {
	dst := InferenceRouteOutcome{FinalStatus: "success"}
	src := InferenceRouteOutcome{
		CacheOutcome:       "hit",
		CacheTier:          "ssd",
		CachedTokens:       128,
		PrefillTokensSaved: 96,
		CacheStageMs:       4.5,
		ClientOutcome:      "completed",
		ProviderOutcome:    "completed",
		BillingOutcome:     "charged",
		ResponseCommitted:  true,
		MediaFetchMs:       12,
		IsFinalAttempt:     true,
		TotalAttempts:      2,
	}
	mergeInferenceRouteOutcome(&dst, &src)
	if dst.CacheOutcome != "hit" || dst.CachedTokens != 128 || dst.ClientOutcome != "completed" || dst.MediaFetchMs != 12 || dst.TotalAttempts != 2 {
		t.Fatalf("merged = %+v", dst)
	}
	srcBill := InferenceRouteOutcome{ReservedMicroUSD: 10, SettledMicroUSD: 8, RefundMicroUSD: 2, TerminalSource: "provider"}
	mergeInferenceRouteOutcome(&dst, &srcBill)
	if dst.ReservedMicroUSD != 10 || dst.SettledMicroUSD != 8 || dst.RefundMicroUSD != 2 || dst.TerminalSource != "provider" {
		t.Fatalf("billing merge = %+v", dst)
	}
	// Zero-value update must not erase cache telemetry.
	mergeInferenceRouteOutcome(&dst, &InferenceRouteOutcome{FinalStatus: "success"})
	if dst.CacheOutcome != "hit" || dst.ClientOutcome != "completed" {
		t.Fatalf("zero merge erased cache/dimensions: %+v", dst)
	}
}
