package registry

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
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

// TestHeartbeatAccumulatesUptime is the integration regression: the
// heartbeat handler credits the wall-clock gap since the previous heartbeat as
// uptime (bounded), so an always-online provider's reputation can exceed 0.85.
// This test fails without the registry.go Heartbeat change.
func TestHeartbeatAccumulatesUptime(t *testing.T) {
	reg := New(testLogger())
	p := reg.Register("p1", nil, testRegisterMessage())

	// Simulate ~45s since the last heartbeat (within the 2m credit window).
	p.mu.Lock()
	p.LastHeartbeat = time.Now().Add(-45 * time.Second)
	p.mu.Unlock()

	reg.Heartbeat("p1", &protocol.HeartbeatMessage{Type: protocol.TypeHeartbeat, Status: "idle"})

	p.mu.Lock()
	credited := p.Reputation.TotalUptime
	p.mu.Unlock()
	if credited < 40*time.Second || credited > 50*time.Second {
		t.Fatalf("uptime credited = %v, want ~45s", credited)
	}

	// An oversized gap (provider effectively offline) must NOT be credited.
	p.mu.Lock()
	p.LastHeartbeat = time.Now().Add(-30 * time.Minute)
	before := p.Reputation.TotalUptime
	p.mu.Unlock()

	reg.Heartbeat("p1", &protocol.HeartbeatMessage{Type: protocol.TypeHeartbeat, Status: "idle"})

	p.mu.Lock()
	after := p.Reputation.TotalUptime
	p.mu.Unlock()
	if jump := after - before; jump > time.Minute {
		t.Fatalf("oversized offline gap credited %v of uptime, want it skipped", jump)
	}

	// After enough accumulated uptime + a perfect record, the score must clear
	// the old 0.85 cap.
	p.mu.Lock()
	p.Reputation.RecordUptime(24 * time.Hour)
	p.Reputation.RecordJobSuccess()
	p.Reputation.RecordLatency(300 * time.Millisecond)
	p.Reputation.RecordChallengePass()
	score := p.Reputation.Score()
	p.mu.Unlock()
	if score <= 0.85 {
		t.Fatalf("score = %f, want > 0.85 after accumulated uptime", score)
	}
}

func TestHeartbeatAccumulatesAcrossRestarts(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	p := reg.Register("p1", nil, msg)
	lifetimeStats := protocol.HeartbeatStats{
		RequestsServed:               100,
		TokensGenerated:              2000,
		CancellationsReceived:        7,
		CancellationsBeforeOutput:    3,
		CancellationsPartialComplete: 2,
		GenerationErrorsAfterOutput:  4,
		ChunkEncryptionErrors:        1,
		StreamClosedWithoutTerminal:  5,
		CancelDuringModelLoad:        6,
		UsageGaps:                    8,
	}
	lastSessionStats := lifetimeStats
	lifetimeJSON, _ := json.Marshal(lifetimeStats)
	lastSessionJSON, _ := json.Marshal(lastSessionStats)

	reg.RestoreProviderState(p, &store.ProviderRecord{
		ID:                         "persisted-p1",
		TrustLevel:                 string(TrustHardware),
		Attested:                   true,
		LifetimeRequestsServed:     100,
		LifetimeTokensGenerated:    2000,
		LastSessionRequestsServed:  100,
		LastSessionTokensGenerated: 2000,
		LifetimeStats:              lifetimeJSON,
		LastSessionStats:           lastSessionJSON,
	})

	reg.Heartbeat("p1", &protocol.HeartbeatMessage{
		Type:   protocol.TypeHeartbeat,
		Status: "idle",
		Stats:  protocol.HeartbeatStats{RequestsServed: 100, TokensGenerated: 2000},
	})

	if p.Stats.RequestsServed != 100 {
		t.Fatalf("requests_served after coordinator restart = %d, want 100", p.Stats.RequestsServed)
	}
	if p.Stats.TokensGenerated != 2000 {
		t.Fatalf("tokens_generated after coordinator restart = %d, want 2000", p.Stats.TokensGenerated)
	}
	if p.Stats.CancellationsReceived != 7 || p.Stats.UsageGaps != 8 {
		t.Fatalf("restored outcome counters = %+v, want persisted heartbeat stats", p.Stats)
	}

	reg.Heartbeat("p1", &protocol.HeartbeatMessage{
		Type:   protocol.TypeHeartbeat,
		Status: "idle",
		Stats: protocol.HeartbeatStats{
			RequestsServed:        105,
			TokensGenerated:       2300,
			CancellationsReceived: 9,
			UsageGaps:             11,
		},
	})

	if p.Stats.RequestsServed != 105 {
		t.Fatalf("requests_served after new work = %d, want 105", p.Stats.RequestsServed)
	}
	if p.Stats.TokensGenerated != 2300 {
		t.Fatalf("tokens_generated after new work = %d, want 2300", p.Stats.TokensGenerated)
	}
	if p.Stats.CancellationsReceived != 9 || p.Stats.UsageGaps != 11 {
		t.Fatalf("outcome counters after new work = %+v, want updated counters", p.Stats)
	}

	reg.Heartbeat("p1", &protocol.HeartbeatMessage{
		Type:   protocol.TypeHeartbeat,
		Status: "idle",
		Stats: protocol.HeartbeatStats{
			RequestsServed:        2,
			TokensGenerated:       40,
			CancellationsReceived: 1,
			UsageGaps:             1,
		},
	})

	if p.Stats.RequestsServed != 107 {
		t.Fatalf("requests_served after provider restart = %d, want 107", p.Stats.RequestsServed)
	}
	if p.Stats.TokensGenerated != 2340 {
		t.Fatalf("tokens_generated after provider restart = %d, want 2340", p.Stats.TokensGenerated)
	}
	if p.Stats.CancellationsReceived != 10 || p.Stats.UsageGaps != 12 {
		t.Fatalf("outcome counters after provider restart = %+v, want accumulated counters", p.Stats)
	}
}

func TestRestoreProviderStateKeepsFreshChallengeVerification(t *testing.T) {
	reg := New(testLogger())
	p := reg.Register("p1", nil, testRegisterMessage())
	fresh := time.Now()
	stale := fresh.Add(-10 * time.Minute)
	p.SetLastChallengeVerified(fresh)

	reg.RestoreProviderState(p, &store.ProviderRecord{
		ID:                    "persisted-p1",
		TrustLevel:            string(TrustHardware),
		Attested:              true,
		LastChallengeVerified: &stale,
	})

	if !p.LastChallengeVerified.Equal(fresh) {
		t.Fatalf("LastChallengeVerified = %v, want fresh registration value %v", p.LastChallengeVerified, fresh)
	}
}

func TestRestoreProviderStateAcceptsNewerChallengeVerification(t *testing.T) {
	reg := New(testLogger())
	p := reg.Register("p1", nil, testRegisterMessage())
	old := time.Now().Add(-10 * time.Minute)
	newer := old.Add(5 * time.Minute)
	p.SetLastChallengeVerified(old)

	reg.RestoreProviderState(p, &store.ProviderRecord{
		ID:                    "persisted-p1",
		TrustLevel:            string(TrustSelfSigned),
		Attested:              true,
		LastChallengeVerified: &newer,
	})

	if !p.LastChallengeVerified.Equal(newer) {
		t.Fatalf("LastChallengeVerified = %v, want newer stored value %v", p.LastChallengeVerified, newer)
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

func TestHeartbeatDropsUnregisteredModelIdentifiersBeforeStateAndMetrics(t *testing.T) {
	var logs bytes.Buffer
	reg := New(slog.New(slog.NewTextHandler(&logs, nil)))
	msg := testRegisterMessage()
	p := reg.Register("p1", nil, msg)

	const leakSentinel = "LEAK_SENTINEL_prompt-and-url_https://attacker.invalid/private"
	knownModel := msg.Models[0].ID
	activeModel := leakSentinel
	knownKVBackend := KVBackendPaged
	unknownKVBackend := KVBackendContiguous
	freeForLoadGB := 24.0
	hb := &protocol.HeartbeatMessage{
		Type:        protocol.TypeHeartbeat,
		Status:      "serving",
		ActiveModel: &activeModel,
		WarmModels:  []string{knownModel, leakSentinel, knownModel},
		BackendCapacity: &protocol.BackendCapacity{
			FreeForLoadGB: &freeForLoadGB,
			Slots: []protocol.BackendSlotCapacity{
				{
					Model:             leakSentinel,
					State:             "running",
					NumRunning:        1,
					MaxConcurrency:    maxReportedMaxConcurrency + 100,
					ObservedDecodeTPS: 99,
					KVBackend:         &unknownKVBackend,
				},
				{
					Model:             knownModel,
					State:             "running",
					NumRunning:        1,
					ObservedDecodeTPS: 12,
					KVBackend:         &knownKVBackend,
				},
				{
					Model:             knownModel,
					State:             "running",
					ObservedDecodeTPS: 321,
				},
			},
		},
	}

	reg.Heartbeat("p1", hb)

	p.mu.Lock()
	if len(p.WarmModels) != 1 || p.WarmModels[0] != knownModel {
		t.Fatalf("warm models = %q, want only registered model %q", p.WarmModels, knownModel)
	}
	if p.CurrentModel != "" {
		t.Fatalf("current model = %q, want unknown active model dropped", p.CurrentModel)
	}
	if p.BackendCapacity == nil || len(p.BackendCapacity.Slots) != 1 || p.BackendCapacity.Slots[0].Model != knownModel {
		t.Fatalf("backend slots = %+v, want only registered model %q", p.BackendCapacity, knownModel)
	}
	if _, leaked := p.kvBackends[leakSentinel]; leaked {
		t.Fatalf("unknown model was recorded in KV state: %q", leakSentinel)
	}
	p.mu.Unlock()
	snapshot := p.BackendCapacitySnapshot()
	if snapshot == nil || len(snapshot.Slots) != 1 || snapshot.Slots[0].Model != knownModel {
		t.Fatalf("public capacity snapshot = %+v, want only registered model %q", snapshot, knownModel)
	}
	if strings.Contains(snapshot.Slots[0].Model, leakSentinel) {
		t.Fatalf("unknown model reached public capacity snapshot: %+v", snapshot)
	}

	if got := reg.tpsRegistry.Median(leakSentinel, msg.Hardware.ChipFamily); got != 0 {
		t.Fatalf("unknown model TPS = %v, want no sample", got)
	}
	if got := reg.tpsRegistry.Median(knownModel, msg.Hardware.ChipFamily); got != 12 {
		t.Fatalf("known model TPS = %v, want 12", got)
	}
	if _, observed := reg.SlotKVBackend("p1", leakSentinel); observed {
		t.Fatalf("unknown model has a KV observation: %q", leakSentinel)
	}
	if got, observed := reg.SlotKVBackend("p1", knownModel); !observed || got != knownKVBackend {
		t.Fatalf("known model KV observation = (%q, %v), want (%q, true)", got, observed, knownKVBackend)
	}
	if strings.Contains(logs.String(), leakSentinel) {
		t.Fatalf("unknown model reached coordinator logs: %s", logs.String())
	}

	// The decoded frame remains untouched and does not alias retained registry
	// state. In particular, the out-of-range field on the rejected slot was not
	// clamped before the slot was discarded.
	if hb.ActiveModel == nil || *hb.ActiveModel != leakSentinel || len(hb.WarmModels) != 3 || len(hb.BackendCapacity.Slots) != 3 {
		t.Fatalf("decoded heartbeat was mutated: %+v", hb)
	}
	if got := hb.BackendCapacity.Slots[0].MaxConcurrency; got != maxReportedMaxConcurrency+100 {
		t.Fatalf("rejected decoded slot was mutated: max_concurrency=%d", got)
	}
	hb.WarmModels[0] = leakSentinel
	hb.BackendCapacity.Slots[1].Model = leakSentinel
	snapshot.Slots[0].Model = leakSentinel
	freeForLoadGB = 1
	p.mu.Lock()
	defer p.mu.Unlock()
	if len(p.WarmModels) != 1 || p.WarmModels[0] != knownModel || p.BackendCapacity.Slots[0].Model != knownModel {
		t.Fatal("registry state aliases the decoded heartbeat")
	}
	if got := *p.BackendCapacity.FreeForLoadGB; got != 24 {
		t.Fatalf("retained free_for_load_gb = %v after decoded value changed, want 24", got)
	}
}

func TestHeartbeatCanonicalizationPreservesNilAndEmptySnapshots(t *testing.T) {
	reg := New(testLogger())
	p := reg.Register("p1", nil, testRegisterMessage())

	reg.Heartbeat("p1", &protocol.HeartbeatMessage{
		Type:            protocol.TypeHeartbeat,
		Status:          "idle",
		WarmModels:      []string{},
		BackendCapacity: &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{}},
	})
	p.mu.Lock()
	if p.WarmModels == nil || len(p.WarmModels) != 0 {
		t.Fatalf("present empty warm_models became %#v, want non-nil empty", p.WarmModels)
	}
	if p.BackendCapacity == nil || p.BackendCapacity.Slots == nil || len(p.BackendCapacity.Slots) != 0 {
		t.Fatalf("present empty backend slots became %#v, want non-nil empty", p.BackendCapacity)
	}
	p.mu.Unlock()

	reg.Heartbeat("p1", &protocol.HeartbeatMessage{Type: protocol.TypeHeartbeat, Status: "idle"})
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.WarmModels != nil {
		t.Fatalf("nil warm_models became %#v, want nil", p.WarmModels)
	}
	if p.BackendCapacity != nil {
		t.Fatalf("nil backend_capacity became %#v, want nil", p.BackendCapacity)
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
