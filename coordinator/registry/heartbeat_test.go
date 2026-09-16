package registry

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestHeartbeat(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	reg.Register("p1", nil, msg)

	hb := &protocol.HeartbeatMessage{
		Type:   protocol.TypeHeartbeat,
		Status: "idle",
		Stats: protocol.HeartbeatStats{
			RequestsServed:               5,
			TokensGenerated:              1000,
			CancellationsReceived:        1,
			CancellationsBeforeOutput:    2,
			CancellationsPartialComplete: 3,
			GenerationErrorsAfterOutput:  4,
			ChunkEncryptionErrors:        5,
			StreamClosedWithoutTerminal:  6,
			CancelDuringModelLoad:        7,
			UsageGaps:                    8,
		},
	}

	reg.Heartbeat("p1", hb)

	p := reg.GetProvider("p1")
	if p.Stats.RequestsServed != 5 {
		t.Errorf("requests_served = %d, want 5", p.Stats.RequestsServed)
	}
	if p.Stats.TokensGenerated != 1000 {
		t.Errorf("tokens_generated = %d, want 1000", p.Stats.TokensGenerated)
	}
	if p.Stats.CancellationsReceived != 1 {
		t.Errorf("cancellations_received = %d, want 1", p.Stats.CancellationsReceived)
	}
	if p.Stats.CancellationsBeforeOutput != 2 {
		t.Errorf("cancellations_before_output = %d, want 2", p.Stats.CancellationsBeforeOutput)
	}
	if p.Stats.CancellationsPartialComplete != 3 {
		t.Errorf("cancellations_partial_complete = %d, want 3", p.Stats.CancellationsPartialComplete)
	}
	if p.Stats.GenerationErrorsAfterOutput != 4 {
		t.Errorf("generation_errors_after_output = %d, want 4", p.Stats.GenerationErrorsAfterOutput)
	}
	if p.Stats.ChunkEncryptionErrors != 5 {
		t.Errorf("chunk_encryption_errors = %d, want 5", p.Stats.ChunkEncryptionErrors)
	}
	if p.Stats.StreamClosedWithoutTerminal != 6 {
		t.Errorf("stream_closed_without_terminal = %d, want 6", p.Stats.StreamClosedWithoutTerminal)
	}
	if p.Stats.CancelDuringModelLoad != 7 {
		t.Errorf("cancel_during_model_load = %d, want 7", p.Stats.CancelDuringModelLoad)
	}
	if p.Stats.UsageGaps != 8 {
		t.Errorf("usage_gaps = %d, want 8", p.Stats.UsageGaps)
	}
}

func TestHeartbeatUnknownProvider(t *testing.T) {
	reg := New(testLogger())
	hb := &protocol.HeartbeatMessage{
		Type:   protocol.TypeHeartbeat,
		Status: "idle",
	}
	// Should not panic.
	reg.Heartbeat("unknown", hb)
}

func TestHeartbeatUpdatesWarmModels(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	reg.Register("p1", nil, msg)

	model := "mlx-community/Qwen3.5-9B-Instruct-4bit"
	hb := &protocol.HeartbeatMessage{
		Type:        protocol.TypeHeartbeat,
		Status:      "serving",
		ActiveModel: &model,
		Stats:       protocol.HeartbeatStats{},
		WarmModels:  []string{"mlx-community/Qwen3.5-9B-Instruct-4bit"},
	}

	reg.Heartbeat("p1", hb)

	p := reg.GetProvider("p1")
	if len(p.WarmModels) != 1 {
		t.Errorf("warm_models len = %d, want 1", len(p.WarmModels))
	}
	if p.CurrentModel != model {
		t.Errorf("current_model = %q, want %q", p.CurrentModel, model)
	}
}

func TestHeartbeatUpdatesSystemMetrics(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	reg.Register("p1", nil, msg)

	hb := &protocol.HeartbeatMessage{
		Type:   protocol.TypeHeartbeat,
		Status: "idle",
		Stats:  protocol.HeartbeatStats{},
		SystemMetrics: protocol.SystemMetrics{
			MemoryPressure: 0.55,
			CPUUsage:       0.22,
			ThermalState:   "fair",
		},
	}
	reg.Heartbeat("p1", hb)

	p := reg.GetProvider("p1")
	if p.SystemMetrics.MemoryPressure != 0.55 {
		t.Errorf("memory_pressure = %f, want 0.55", p.SystemMetrics.MemoryPressure)
	}
	if p.SystemMetrics.ThermalState != "fair" {
		t.Errorf("thermal_state = %q, want fair", p.SystemMetrics.ThermalState)
	}
}

func TestHeartbeatDoesNotReviveUntrusted(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	reg.Register("p1", nil, msg)

	if reg.OnlineCount() != 1 {
		t.Fatalf("OnlineCount = %d, want 1 after register", reg.OnlineCount())
	}

	reg.MarkUntrusted("p1")
	if reg.OnlineCount() != 0 {
		t.Errorf("OnlineCount = %d, want 0 after MarkUntrusted", reg.OnlineCount())
	}

	p := reg.GetProvider("p1")
	if p.Status != StatusUntrusted {
		t.Fatalf("status = %q, want %q", p.Status, StatusUntrusted)
	}

	// Heartbeat with idle status must not revive an untrusted provider
	reg.Heartbeat("p1", &protocol.HeartbeatMessage{Status: "idle"})
	p = reg.GetProvider("p1")
	if p.Status != StatusUntrusted {
		t.Errorf("status = %q after heartbeat, want %q (untrusted must not revive)", p.Status, StatusUntrusted)
	}
	if reg.OnlineCount() != 0 {
		t.Errorf("OnlineCount = %d after heartbeat on untrusted, want 0", reg.OnlineCount())
	}

	// Disconnect should NOT decrement again (no double-decrement)
	reg.Disconnect("p1")
	if reg.OnlineCount() != 0 {
		t.Errorf("OnlineCount = %d after disconnect, want 0 (no double-decrement)", reg.OnlineCount())
	}
}
