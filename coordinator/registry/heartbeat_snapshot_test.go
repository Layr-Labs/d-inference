package registry

import (
	"bytes"
	"log/slog"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

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
	reclaimerTelemetry := &protocol.MLXCacheReclaimerTelemetry{
		CacheLimitBytes: 8 << 30,
		SweepSignals:    12,
		Reclaims:        4,
	}
	hb := &protocol.HeartbeatMessage{
		Type:        protocol.TypeHeartbeat,
		Status:      "serving",
		ActiveModel: &activeModel,
		WarmModels:  []string{knownModel, leakSentinel, knownModel},
		BackendCapacity: &protocol.BackendCapacity{
			FreeForLoadGB:     &freeForLoadGB,
			MLXCacheReclaimer: reclaimerTelemetry,
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
	if snapshot.MLXCacheReclaimer == nil || snapshot.MLXCacheReclaimer.Reclaims != 4 {
		t.Fatalf("public reclaimer telemetry snapshot = %+v, want 4 reclaims", snapshot.MLXCacheReclaimer)
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
	reclaimerTelemetry.Reclaims = 99
	snapshot.MLXCacheReclaimer.Reclaims = 88
	p.mu.Lock()
	defer p.mu.Unlock()
	if len(p.WarmModels) != 1 || p.WarmModels[0] != knownModel || p.BackendCapacity.Slots[0].Model != knownModel {
		t.Fatal("registry state aliases the decoded heartbeat")
	}
	if got := *p.BackendCapacity.FreeForLoadGB; got != 24 {
		t.Fatalf("retained free_for_load_gb = %v after decoded value changed, want 24", got)
	}
	if got := p.BackendCapacity.MLXCacheReclaimer.Reclaims; got != 4 {
		t.Fatalf("retained mlx cache reclaims = %d after source/snapshot mutation, want 4", got)
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
