package registry

import (
	"math"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestTTFTPendingPromptSizesThroughScheduler(t *testing.T) {
	for _, tc := range []struct {
		name          string
		pendingPrompt int
		incoming      int
		ceiling       float64
		wantMs        float64
		wantSelected  bool
	}{
		{"long ahead of short", 8_000, 100, 5_000, 8_110, false},
		{"short ahead of long", 100, 4_000, 5_000, 4_110, true},
		{"equal sizes", 2_000, 2_000, 5_000, 4_010, true},
		{"unknown pending keeps proxy", 0, 4_000, 5_000, 8_010, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			resetCalibrator(t)
			reg := New(testLogger())
			const model = "pending-prompt-model"
			p := calibrationTestProvider(t, reg, "provider", model, 100, 1_000)
			p.AddPending(&PendingRequest{RequestID: "ahead", Model: model, EstimatedPromptTokens: tc.pendingPrompt, RequestedMaxTokens: 128})
			_, _, _, preflight, hasTTFT := reg.QuickCapacityCheckWithTTFTForRequest(model, tc.incoming, 128, RequestTraits{}, false)
			if !hasTTFT || math.Abs(float64(preflight.Microseconds())/1000-tc.wantMs) > .01 {
				t.Fatalf("preflight=%v hasTTFT=%v, want %.2fms", preflight, hasTTFT, tc.wantMs)
			}
			pr := &PendingRequest{RequestID: "incoming", Model: model, EstimatedPromptTokens: tc.incoming, RequestedMaxTokens: 128, MaxTTFTMs: tc.ceiling}
			selected, decision := reg.ReserveProviderEx(model, pr)
			if (selected != nil) != tc.wantSelected {
				t.Fatalf("selected=%v, want selected=%v; decision=%+v", selected != nil, tc.wantSelected, decision)
			}
			prediction := decision.BestTTFTMs
			if selected != nil {
				prediction = decision.RawTTFTMs
			}
			if math.Abs(prediction-tc.wantMs) > .01 {
				t.Fatalf("scheduler=%.2fms, want %.2fms", prediction, tc.wantMs)
			}
			t.Logf("pending=%d incoming=%d raw_ms=%.0f ceiling_ms=%.0f selected=%v", tc.pendingPrompt, tc.incoming, prediction, tc.ceiling, selected != nil)
		})
	}
}

func TestTTFTPendingWorkWithZeroIncomingEstimate(t *testing.T) {
	snap := routingSnapshot{pendingForModel: 1, pendingAfterHeartbeat: 1, pendingPrefillTokens: 8_000}
	if got := queuedPrefillTokensAhead(&snap, 0); got != 8_000 {
		t.Fatalf("queued work=%v, want 8000 even without an incoming estimate", got)
	}
}

func TestTTFTPendingPrefillIgnoresStaleCapacityFrames(t *testing.T) {
	resetCalibrator(t)
	reg := New(testLogger())
	const model = "ordered-capacity-prompt-model"
	p := calibrationTestProvider(t, reg, "provider", model, 100, 1_000)
	heartbeat := func(seq uint64, waiting int) {
		reg.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: &protocol.BackendCapacity{CapacitySeq: seq, TotalMemoryGB: 64, Slots: []protocol.BackendSlotCapacity{{Model: model, State: "running", MaxConcurrency: 8, NumWaiting: waiting}}}})
	}
	heartbeat(10, 0)
	p.AddPending(&PendingRequest{RequestID: "ahead", Model: model, EstimatedPromptTokens: 8_000, RequestedMaxTokens: 128})
	p.mu.Lock()
	appliedAt := p.capacitySnapshotAt
	p.mu.Unlock()
	for _, seq := range []uint64{9, 10} {
		heartbeat(seq, 1)
		p.mu.Lock()
		stamp, liveness := p.capacitySnapshotAt, p.LastHeartbeat
		p.mu.Unlock()
		if !stamp.Equal(appliedAt) || !liveness.After(appliedAt) {
			t.Fatalf("stale seq %d changed snapshot time or failed to refresh liveness", seq)
		}
		_, _, _, got, has := reg.QuickCapacityCheckWithTTFTForRequest(model, 100, 128, RequestTraits{}, false)
		if !has || got != 8_110*time.Millisecond {
			t.Fatalf("stale seq %d erased known prompt: TTFT=%v has=%v", seq, got, has)
		}
	}
	// A newly applied snapshot changes the identity boundary; its waiting row
	// is anonymous, so the legacy proxy applies without adding the request twice.
	heartbeat(11, 1)
	_, _, _, got, has := reg.QuickCapacityCheckWithTTFTForRequest(model, 100, 128, RequestTraits{}, false)
	if !has || got != 210*time.Millisecond {
		t.Fatalf("new snapshot reconciliation: TTFT=%v has=%v", got, has)
	}
	reg.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle"})
	p.mu.Lock()
	cleared := p.BackendCapacity == nil && p.capacitySnapshotAt.IsZero()
	p.mu.Unlock()
	if !cleared {
		t.Fatal("nil capacity must clear its provenance")
	}
	_, _, _, _, has = reg.QuickCapacityCheckWithTTFTForRequest(model, 100, 128, RequestTraits{}, false)
	if has {
		t.Fatal("nil capacity must retain the unknown-TTFT fallback")
	}
}

func TestTTFTPendingPrefillResetsOnReconnect(t *testing.T) {
	reg := New(testLogger())
	first := reg.Register("provider", nil, testRegisterMessage())
	reg.Heartbeat(first.ID, seqHeartbeat(10, 0))
	first.AddPending(&PendingRequest{RequestID: "old-attempt", Model: seqTestModel, EstimatedPromptTokens: 8_000, ErrorCh: make(chan protocol.InferenceErrorMessage, 1)})
	reg.Disconnect(first.ID)
	second := reg.Register(first.ID, nil, testRegisterMessage())
	second.mu.Lock()
	defer second.mu.Unlock()
	if second == first || !second.capacitySnapshotAt.IsZero() || len(second.pendingReqs) != 0 {
		t.Fatal("reconnect retained applied capacity or old pending work")
	}
}

func TestTTFTPendingPrefillHeartbeatBoundaries(t *testing.T) {
	for _, tc := range []struct {
		name      string
		heartbeat string
		running   int
		waiting   int
		content   bool
		wantMs    float64
	}{
		{"after idle heartbeat", "before", 0, 0, false, 8_110},
		{"fresh heartbeat reports pending waiting", "after", 0, 1, false, 210},
		{"fresh heartbeat reports pending running", "after", 1, 0, false, 113.9},
		{"equal instant is not known new", "equal", 0, 1, false, 210},
		{"unknown heartbeat uses legacy proxy", "missing", 0, 0, false, 210},
		{"old running count cannot hide new work", "before", 1, 0, false, 8_113.9},
		{"old waiting count cannot absorb new work", "before", 0, 1, false, 8_210},
		{"known content stops prefill before next heartbeat", "before", 0, 0, true, 110},
	} {
		t.Run(tc.name, func(t *testing.T) {
			resetCalibrator(t)
			reg := New(testLogger())
			const model = "heartbeat-prompt-model"
			p := calibrationTestProvider(t, reg, "provider", model, 100, 1_000)
			pr := &PendingRequest{RequestID: "ahead", Model: model, EstimatedPromptTokens: 8_000, RequestedMaxTokens: 128}
			p.AddPending(pr)
			p.mu.Lock()
			switch tc.heartbeat {
			case "before":
				p.capacitySnapshotAt = pr.reservedAt.Add(-time.Second)
			case "after":
				p.capacitySnapshotAt = pr.reservedAt.Add(time.Millisecond)
			case "equal":
				p.capacitySnapshotAt = pr.reservedAt
			case "missing":
				p.capacitySnapshotAt = time.Time{}
			}
			p.BackendCapacity.Slots[0].NumRunning = tc.running
			p.BackendCapacity.Slots[0].NumWaiting = tc.waiting
			p.mu.Unlock()
			if tc.content {
				pr.FinishProviderChunkIngress(pr.BeginProviderChunkIngress(), true)
			}
			_, _, _, got, hasTTFT := reg.QuickCapacityCheckWithTTFTForRequest(model, 100, 128, RequestTraits{}, false)
			if !hasTTFT || math.Abs(float64(got.Microseconds())/1000-tc.wantMs) > .01 {
				t.Fatalf("TTFT=%v has=%v, want %.2fms", got, hasTTFT, tc.wantMs)
			}
		})
	}
}

func TestTTFTPendingPrefillModelIsolationAndRelease(t *testing.T) {
	resetCalibrator(t)
	reg := New(testLogger())
	const model = "prompt-model-a"
	p := calibrationTestProvider(t, reg, "provider", model, 100, 1_000)
	p.AddPending(&PendingRequest{RequestID: "other-model", Model: "prompt-model-b", EstimatedPromptTokens: 30_000, RequestedMaxTokens: 128})
	p.AddPending(&PendingRequest{RequestID: "same-model", Model: model, EstimatedPromptTokens: 2_000, RequestedMaxTokens: 128})
	check := func(wantMs float64) {
		t.Helper()
		_, _, _, got, has := reg.QuickCapacityCheckWithTTFTForRequest(model, 100, 128, RequestTraits{}, false)
		if !has || math.Abs(float64(got.Microseconds())/1000-wantMs) > .01 {
			t.Fatalf("TTFT=%v has=%v, want %.2fms", got, has, wantMs)
		}
	}
	check(2_110)
	p.RemovePending("same-model")
	check(110)
}

func TestTTFTPendingPromptUsesObservedRateAndExistingCalibration(t *testing.T) {
	resetCalibrator(t)
	reg := New(testLogger())
	const model = "calibrated-prompt-model"
	p := calibrationTestProvider(t, reg, "provider", model, 100, 1_000)
	p.mu.Lock()
	p.BackendCapacity.Slots[0].ObservedPrefillTPS = 2_000
	p.Hardware.ChipFamily = "M4"
	p.mu.Unlock()
	feedObservations(t, model, "M4", ttftCalibrationWarmupObs, .5)
	p.AddPending(&PendingRequest{RequestID: "ahead", Model: model, EstimatedPromptTokens: 8_000, RequestedMaxTokens: 128})
	pr := &PendingRequest{RequestID: "incoming", Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 128, MaxTTFTMs: 5_000}
	selected, decision := reg.ReserveProviderEx(model, pr)
	if selected == nil || math.Abs(decision.RawTTFTMs-4_060) > .01 || math.Abs(decision.TTFTMs-2_030) > .01 || decision.TTFTCalibrationRatio != .5 {
		t.Fatalf("observed rate/calibrator not reused: %+v", decision)
	}
}

func TestTTFTPendingPromptDoesNotSpendOutputReservationsAsCompute(t *testing.T) {
	resetCalibrator(t)
	reg := New(testLogger())
	const model = "prompt-vs-output-model"
	p := calibrationTestProvider(t, reg, "provider", model, 100, 1_000)
	p.mu.Lock()
	p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 100_000
	p.mu.Unlock()
	pr := &PendingRequest{RequestID: "ahead", Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 50_000}
	p.AddPending(pr)
	_, _, _, got, has := reg.QuickCapacityCheckWithTTFTForRequest(model, 100, 128, RequestTraits{}, false)
	if !has || got != 210*time.Millisecond {
		t.Fatalf("TTFT=%v has=%v, want 210ms without the output reservation", got, has)
	}
	// Completion of prefill does not release this large KV reservation.
	pr.FinishProviderChunkIngress(pr.BeginProviderChunkIngress(), true)
	p.mu.Lock()
	p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 1_000
	p.mu.Unlock()
	selected, _ := reg.ReserveProviderEx(model, &PendingRequest{RequestID: "must-not-fit", Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 128})
	if selected != nil {
		t.Fatal("prefill progress released the pending KV reservation")
	}
}

func TestTTFTPendingPromptRetainsVisionGateExemption(t *testing.T) {
	resetCalibrator(t)
	reg := New(testLogger())
	const model = "vision-prompt-model"
	p := calibrationTestProvider(t, reg, "provider", model, 100, 1_000)
	p.mu.Lock()
	p.Models[0].IsVision = true
	p.BackendCapacity.Slots[0] = protocol.BackendSlotCapacity{Model: model, State: "running", MaxConcurrency: 8}
	p.mu.Unlock()
	p.AddPending(&PendingRequest{RequestID: "ahead", Model: model, EstimatedPromptTokens: 8_000, RequestedMaxTokens: 128})
	selected, decision := reg.ReserveProviderEx(model, &PendingRequest{RequestID: "vision", Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 128, RequiresVision: true, MaxTTFTMs: 1})
	if selected == nil {
		t.Fatalf("text-prefill correction gated an unsupported vision prediction: %+v", decision)
	}
}
