package registry

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// The coordinator's observed-prefill ceiling is 20,000 tok/s (the provider's
// own plausibility ceiling). With the former 5,000 cap, a heartbeat reporting
// a genuinely fast prefill (6,500 tok/s: the M5 Max gemma tier) was zeroed
// and the slot fell back to decode×12 ≈ 1,000 tok/s — ranked below a slower
// box and TTFT-gated on long prompts. These tests deliver the rate through
// the real heartbeat path so the ingest clamp is exercised.

func prefillHeartbeat(model string, prefillTPS float64) *protocol.HeartbeatMessage {
	active := model
	return &protocol.HeartbeatMessage{
		Type:        protocol.TypeHeartbeat,
		Status:      "idle",
		ActiveModel: &active,
		WarmModels:  []string{model},
		SystemMetrics: protocol.SystemMetrics{
			MemoryPressure: 0.1, CPUUsage: 0.1, ThermalState: "nominal",
		},
		BackendCapacity: &protocol.BackendCapacity{
			TotalMemoryGB: 64,
			Slots: []protocol.BackendSlotCapacity{{
				Model: model, State: "running",
				ActiveTokenBudgetMax: 1_000_000,
				ObservedDecodeTPS:    80,
				ObservedPrefillTPS:   prefillTPS,
			}},
		},
	}
}

// TestHeartbeatKeepsFastTierPrefill: a 6,500 tok/s observed prefill survives
// ingest (it was zeroed by the 5,000 cap); 25,000 is still ignored.
func TestHeartbeatKeepsFastTierPrefill(t *testing.T) {
	reg := New(testLogger())
	model := "prefill-ceiling-model"
	p := makeTokenBudgetProvider(t, reg, "fast", model, 80, 0, 1_000_000, 80)
	reg.Heartbeat(p.ID, prefillHeartbeat(model, 6_500))
	p.mu.Lock()
	got := p.BackendCapacity.Slots[0].ObservedPrefillTPS
	p.mu.Unlock()
	if got != 6_500 {
		t.Fatalf("observed prefill after heartbeat = %v, want 6500 kept", got)
	}
	reg.Heartbeat(p.ID, prefillHeartbeat(model, 25_000))
	p.mu.Lock()
	got = p.BackendCapacity.Slots[0].ObservedPrefillTPS
	p.mu.Unlock()
	if got != 0 {
		t.Fatalf("observed prefill 25,000 after heartbeat = %v, want 0 (ignored above the ceiling)", got)
	}
}

// TestFasterPrefillSlotRanksAheadOnLongPrompt: cost is monotone in the
// observed prefill rate — a 6,500 tok/s slot beats an otherwise identical
// 4,000 tok/s slot on a 60K-token prompt (9.2 s vs 15 s of prefill, outside
// the 3 s near-tie window; with the old cap the 6,500 slot was zeroed to the
// ~1,000 tok/s fallback and lost).
func TestFasterPrefillSlotRanksAheadOnLongPrompt(t *testing.T) {
	reg := New(testLogger())
	model := "prefill-rank-model"
	fast := makeTokenBudgetProvider(t, reg, "fast", model, 80, 0, 1_000_000, 80)
	slow := makeTokenBudgetProvider(t, reg, "slow", model, 80, 0, 1_000_000, 80)
	reg.Heartbeat(fast.ID, prefillHeartbeat(model, 6_500))
	reg.Heartbeat(slow.ID, prefillHeartbeat(model, 4_000))

	pr := &PendingRequest{RequestID: "long", Model: model, EstimatedPromptTokens: 60_000, RequestedMaxTokens: 256}
	p, decision := reg.ReserveProviderEx(model, pr)
	if p == nil {
		t.Fatalf("reservation failed: %+v", decision)
	}
	defer p.RemovePending(pr.RequestID)
	if p.ID != "fast" {
		t.Fatalf("winner=%s (cost %.0f ms, thisReq %.0f ms), want the 6,500 tok/s slot", p.ID, decision.CostMs, decision.ThisReqMs)
	}
	// 60,000 / 6,500 ≈ 9.2 s of prefill plus 256 / 80 = 3.2 s of decode.
	if decision.ThisReqMs > 14_000 {
		t.Fatalf("ThisReqMs=%.0f, want ≈ 12,400 (prefill priced at the observed 6,500 tok/s)", decision.ThisReqMs)
	}
}

// TestFastPrefillSlotNotTTFTGatedOnLongPrompt: with the hard TTFT gate on
// (pr.MaxTTFTMs set), a 6,500 tok/s slot's 30K-prompt estimate (~4.6 s +
// first decode) passes a 10 s ceiling; with the rate zeroed to the ~1,000
// tok/s fallback the estimate was ~31 s and the slot was excluded outright.
func TestFastPrefillSlotNotTTFTGatedOnLongPrompt(t *testing.T) {
	reg := New(testLogger())
	model := "prefill-gate-model"
	fast := makeTokenBudgetProvider(t, reg, "fast", model, 80, 0, 1_000_000, 80)
	reg.Heartbeat(fast.ID, prefillHeartbeat(model, 6_500))

	pr := &PendingRequest{RequestID: "gated", Model: model, EstimatedPromptTokens: 30_000, RequestedMaxTokens: 256, MaxTTFTMs: 10_000}
	p, decision := reg.ReserveProviderEx(model, pr)
	if p == nil {
		t.Fatalf("the 6,500 tok/s slot was TTFT-gated on a 30K prompt: %+v", decision)
	}
	defer p.RemovePending(pr.RequestID)
	if decision.TTFTMs <= 0 || decision.TTFTMs > 10_000 {
		t.Fatalf("TTFTMs=%.0f, want ≈ 4,600 + first decode, under the 10 s ceiling", decision.TTFTMs)
	}
}
