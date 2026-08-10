package protocol

import (
	"bytes"
	"encoding/json"
	"testing"
)

func TestBackendSlotCapacityMaxConcurrencyRoundTrip(t *testing.T) {
	msg := HeartbeatMessage{
		Type:   TypeHeartbeat,
		Status: "serving",
		BackendCapacity: &BackendCapacity{
			Slots: []BackendSlotCapacity{{
				Model:          "qwen",
				State:          "running",
				MaxConcurrency: 3,
			}},
		},
	}

	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if !json.Valid(data) {
		t.Fatal("marshaled heartbeat is invalid JSON")
	}

	var decoded HeartbeatMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if decoded.BackendCapacity == nil || len(decoded.BackendCapacity.Slots) != 1 {
		t.Fatalf("decoded slots = %+v", decoded.BackendCapacity)
	}
	if got := decoded.BackendCapacity.Slots[0].MaxConcurrency; got != 3 {
		t.Fatalf("MaxConcurrency=%d, want 3", got)
	}
}

func TestBackendSlotCapacityMaxConcurrencyOmittedCompatibility(t *testing.T) {
	data := []byte(`{
		"type":"heartbeat",
		"status":"serving",
		"active_model":null,
		"stats":{},
		"system_metrics":{},
		"backend_capacity":{"slots":[{"model":"qwen","state":"running"}]}
	}`)

	var decoded HeartbeatMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if decoded.BackendCapacity == nil || len(decoded.BackendCapacity.Slots) != 1 {
		t.Fatalf("decoded slots = %+v", decoded.BackendCapacity)
	}
	if got := decoded.BackendCapacity.Slots[0].MaxConcurrency; got != 0 {
		t.Fatalf("omitted MaxConcurrency=%d, want zero compatibility default", got)
	}
}

func TestBackendSlotCapacityMaxConcurrencyExplicitZeroCompatibility(t *testing.T) {
	data := []byte(`{
		"type":"heartbeat",
		"status":"serving",
		"active_model":null,
		"stats":{},
		"system_metrics":{},
		"backend_capacity":{"slots":[{"model":"qwen","state":"running","max_concurrency":0}]}
	}`)

	var decoded HeartbeatMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if decoded.BackendCapacity == nil || len(decoded.BackendCapacity.Slots) != 1 {
		t.Fatalf("decoded slots = %+v", decoded.BackendCapacity)
	}
	if got := decoded.BackendCapacity.Slots[0].MaxConcurrency; got != 0 {
		t.Fatalf("explicit zero MaxConcurrency=%d, want preserved zero", got)
	}
}

func TestBackendCapacityMarshalRoundtrip(t *testing.T) {
	cap := BackendCapacity{
		Slots: []BackendSlotCapacity{
			{
				Model:              "mlx-community/Qwen2.5-7B-4bit",
				State:              "running",
				NumRunning:         3,
				NumWaiting:         1,
				ActiveTokens:       5000,
				MaxTokensPotential: 12000,
			},
			{
				Model:              "mlx-community/Gemma-4-27B-4bit",
				State:              "idle_shutdown",
				NumRunning:         0,
				NumWaiting:         0,
				ActiveTokens:       0,
				MaxTokensPotential: 0,
			},
		},
		GPUMemoryActiveGB: 45.2,
		GPUMemoryPeakGB:   52.1,
		GPUMemoryCacheGB:  8.3,
		TotalMemoryGB:     128,
	}

	data, err := json.Marshal(cap)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded BackendCapacity
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if len(decoded.Slots) != 2 {
		t.Fatalf("slots len = %d, want 2", len(decoded.Slots))
	}
	if decoded.Slots[0].Model != "mlx-community/Qwen2.5-7B-4bit" {
		t.Errorf("slot[0].model = %q", decoded.Slots[0].Model)
	}
	if decoded.Slots[0].NumRunning != 3 {
		t.Errorf("slot[0].num_running = %d, want 3", decoded.Slots[0].NumRunning)
	}
	if decoded.Slots[1].State != "idle_shutdown" {
		t.Errorf("slot[1].state = %q, want idle_shutdown", decoded.Slots[1].State)
	}
	if decoded.GPUMemoryActiveGB != 45.2 {
		t.Errorf("gpu_memory_active_gb = %f, want 45.2", decoded.GPUMemoryActiveGB)
	}
	if decoded.TotalMemoryGB != 128 {
		t.Errorf("total_memory_gb = %f, want 128", decoded.TotalMemoryGB)
	}
}

func TestHeartbeatWithBackendCapacityMarshal(t *testing.T) {
	cap := &BackendCapacity{
		Slots: []BackendSlotCapacity{
			{
				Model:      "test-model",
				State:      "running",
				NumRunning: 2,
			},
		},
		GPUMemoryActiveGB: 30.5,
		TotalMemoryGB:     64,
	}

	msg := HeartbeatMessage{
		Type:            TypeHeartbeat,
		Status:          "serving",
		Stats:           HeartbeatStats{RequestsServed: 10, TokensGenerated: 5000},
		BackendCapacity: cap,
	}

	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded HeartbeatMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if decoded.BackendCapacity == nil {
		t.Fatal("backend_capacity should not be nil")
	}
	if decoded.BackendCapacity.GPUMemoryActiveGB != 30.5 {
		t.Errorf("gpu_memory_active_gb = %f, want 30.5", decoded.BackendCapacity.GPUMemoryActiveGB)
	}
	if len(decoded.BackendCapacity.Slots) != 1 {
		t.Fatalf("slots len = %d, want 1", len(decoded.BackendCapacity.Slots))
	}
	if decoded.BackendCapacity.Slots[0].NumRunning != 2 {
		t.Errorf("num_running = %d, want 2", decoded.BackendCapacity.Slots[0].NumRunning)
	}
}

func TestHeartbeatWithoutBackendCapacityOmitted(t *testing.T) {
	msg := HeartbeatMessage{
		Type:   TypeHeartbeat,
		Status: "idle",
		Stats:  HeartbeatStats{},
		// BackendCapacity is nil — should be omitted from JSON
	}

	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var m map[string]any
	json.Unmarshal(data, &m)
	if _, ok := m["backend_capacity"]; ok {
		t.Error("backend_capacity should be omitted when nil (omitempty)")
	}
}

func TestProviderMessageUnmarshalHeartbeatWithCapacity(t *testing.T) {
	raw := `{"type":"heartbeat","status":"serving","active_model":"test","stats":{"requests_served":5,"tokens_generated":1000},"system_metrics":{"memory_pressure":0.3,"cpu_usage":0.2,"thermal_state":"nominal"},"backend_capacity":{"slots":[{"model":"test","state":"running","num_running":2,"num_waiting":0,"active_tokens":3000,"max_tokens_potential":8000}],"gpu_memory_active_gb":25.5,"gpu_memory_peak_gb":30.0,"gpu_memory_cache_gb":5.0,"total_memory_gb":64}}`

	var pm ProviderMessage
	if err := json.Unmarshal([]byte(raw), &pm); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	hb := pm.Payload.(*HeartbeatMessage)
	if hb.BackendCapacity == nil {
		t.Fatal("backend_capacity should not be nil")
	}
	if hb.BackendCapacity.TotalMemoryGB != 64 {
		t.Errorf("total_memory_gb = %f, want 64", hb.BackendCapacity.TotalMemoryGB)
	}
	if hb.BackendCapacity.Slots[0].ActiveTokens != 3000 {
		t.Errorf("active_tokens = %d, want 3000", hb.BackendCapacity.Slots[0].ActiveTokens)
	}
}

func TestProviderMessageUnmarshalHeartbeatWithoutCapacity(t *testing.T) {
	// Simulate an old provider that doesn't send backend_capacity
	raw := `{"type":"heartbeat","status":"idle","active_model":null,"stats":{"requests_served":0,"tokens_generated":0},"system_metrics":{"memory_pressure":0.1,"cpu_usage":0.05,"thermal_state":"nominal"}}`

	var pm ProviderMessage
	if err := json.Unmarshal([]byte(raw), &pm); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	hb := pm.Payload.(*HeartbeatMessage)
	if hb.BackendCapacity != nil {
		t.Error("backend_capacity should be nil for old providers")
	}
}

func TestBackendSlotCapacityTokenBudgetFields(t *testing.T) {
	slot := BackendSlotCapacity{
		Model:                 "mlx-community/Qwen2.5-7B-4bit",
		State:                 "running",
		NumRunning:            3,
		NumWaiting:            1,
		ActiveTokens:          5000,
		MaxTokensPotential:    12000,
		ObservedDecodeTPS:     85.5,
		ObservedPrefillTPS:    412.0,
		ActiveTokenBudgetUsed: 28000,
		ActiveTokenBudgetMax:  32768,
		QueuedTokenBudget:     4096,
		ModelLoadTimeMS:       9300,
	}

	data, err := json.Marshal(slot)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded BackendSlotCapacity
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if decoded.ObservedDecodeTPS != 85.5 {
		t.Errorf("observed_decode_tps = %f, want 85.5", decoded.ObservedDecodeTPS)
	}
	if decoded.ObservedPrefillTPS != 412.0 {
		t.Errorf("observed_prefill_tps = %f, want 412.0", decoded.ObservedPrefillTPS)
	}
	if decoded.ModelLoadTimeMS != 9300 {
		t.Errorf("model_load_time_ms = %d, want 9300", decoded.ModelLoadTimeMS)
	}
	if decoded.ActiveTokenBudgetUsed != 28000 {
		t.Errorf("active_token_budget_used = %d, want 28000", decoded.ActiveTokenBudgetUsed)
	}
	if decoded.ActiveTokenBudgetMax != 32768 {
		t.Errorf("active_token_budget_max = %d, want 32768", decoded.ActiveTokenBudgetMax)
	}
	if decoded.QueuedTokenBudget != 4096 {
		t.Errorf("queued_token_budget = %d, want 4096", decoded.QueuedTokenBudget)
	}
}

func TestBackendSlotCapacityOmitsZeroTokenBudget(t *testing.T) {
	slot := BackendSlotCapacity{
		Model:      "test-model",
		State:      "running",
		NumRunning: 1,
	}

	data, err := json.Marshal(slot)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var m map[string]any
	json.Unmarshal(data, &m)

	for _, key := range []string{"observed_decode_tps", "observed_prefill_tps", "active_token_budget_used", "active_token_budget_max", "queued_token_budget", "model_load_time_ms"} {
		if _, ok := m[key]; ok {
			t.Errorf("%s should be omitted when zero (omitempty)", key)
		}
	}
}

func TestBackendSlotCapacityBackwardCompatDecode(t *testing.T) {
	// Old provider sends a slot without the new token-budget fields.
	raw := `{"model":"test","state":"running","num_running":2,"num_waiting":0,"active_tokens":3000,"max_tokens_potential":8000}`

	var slot BackendSlotCapacity
	if err := json.Unmarshal([]byte(raw), &slot); err != nil {
		t.Fatalf("unmarshal old-format slot: %v", err)
	}
	if slot.ObservedDecodeTPS != 0 {
		t.Errorf("observed_decode_tps = %f, want 0 (absent from JSON)", slot.ObservedDecodeTPS)
	}
	if slot.ObservedPrefillTPS != 0 {
		t.Errorf("observed_prefill_tps = %f, want 0 (absent from JSON)", slot.ObservedPrefillTPS)
	}
	if slot.ModelLoadTimeMS != 0 {
		t.Errorf("model_load_time_ms = %d, want 0 (absent from JSON)", slot.ModelLoadTimeMS)
	}
	if slot.ActiveTokenBudgetUsed != 0 {
		t.Errorf("active_token_budget_used = %d, want 0", slot.ActiveTokenBudgetUsed)
	}
	if slot.ActiveTokenBudgetMax != 0 {
		t.Errorf("active_token_budget_max = %d, want 0", slot.ActiveTokenBudgetMax)
	}
	if slot.QueuedTokenBudget != 0 {
		t.Errorf("queued_token_budget = %d, want 0", slot.QueuedTokenBudget)
	}
	if slot.NumRunning != 2 {
		t.Errorf("num_running = %d, want 2", slot.NumRunning)
	}
}

// TestBackendSlotCapacityWedgeFields verifies the engine-health (first-token
// wedge) signals round-trip with the exact snake_case keys the Swift WedgeMonitor
// emits, and that each is omitempty so a legacy/idle slot keeps the prior wire
// shape (Go omission ↔ Swift's encodeIfNonZero / false-omit).
func TestBackendSlotCapacityWedgeFields(t *testing.T) {
	slot := BackendSlotCapacity{
		Model:                      "gpt-oss-20b",
		State:                      "running",
		NumRunning:                 0,
		StepsExecuted:              4321,
		Admits:                     7,
		FirstTokensEmitted:         0,
		SecondsSinceLastStep:       12.5,
		SecondsSinceLastFirstToken: 13.0,
		WedgeSuspected:             true,
		EvalInFlightMs:             11000,
		IdleClearInFlightMs:        1500,
	}

	data, err := json.Marshal(slot)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	for _, want := range []string{
		`"steps_executed":4321`,
		`"admits":7`,
		`"seconds_since_last_step":12.5`,
		`"seconds_since_last_first_token":13`,
		`"wedge_suspected":true`,
		`"eval_in_flight_ms":11000`,
		`"idle_clear_in_flight_ms":1500`,
	} {
		if !bytes.Contains(data, []byte(want)) {
			t.Fatalf("expected %s in JSON, got %s", want, data)
		}
	}
	// first_tokens_emitted == 0 is omitted (this is the wedge: admits>0, 0 first
	// tokens), so its ABSENCE — not a zero — is the on-wire signal.
	if bytes.Contains(data, []byte("first_tokens_emitted")) {
		t.Fatalf("zero first_tokens_emitted should be omitted, got %s", data)
	}

	var decoded BackendSlotCapacity
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if decoded.StepsExecuted != 4321 || decoded.Admits != 7 || decoded.FirstTokensEmitted != 0 {
		t.Fatalf("counter round-trip mismatch: %+v", decoded)
	}
	if decoded.SecondsSinceLastStep != 12.5 || decoded.SecondsSinceLastFirstToken != 13.0 {
		t.Fatalf("seconds round-trip mismatch: %+v", decoded)
	}
	if !decoded.WedgeSuspected {
		t.Fatal("wedge_suspected should round-trip true")
	}
	if decoded.EvalInFlightMs != 11000 || decoded.IdleClearInFlightMs != 1500 {
		t.Fatalf("eval/idle-clear in-flight round-trip mismatch: %+v", decoded)
	}

	// All-zero/false slot: every wedge field is omitted (legacy-compatible wire).
	zero := BackendSlotCapacity{Model: "m", State: "idle", NumRunning: 0}
	zeroData, err := json.Marshal(zero)
	if err != nil {
		t.Fatalf("marshal zero: %v", err)
	}
	for _, key := range []string{
		"steps_executed", "admits", "first_tokens_emitted",
		"seconds_since_last_step", "seconds_since_last_first_token", "wedge_suspected",
		"eval_in_flight_ms", "idle_clear_in_flight_ms",
	} {
		if bytes.Contains(zeroData, []byte(key)) {
			t.Fatalf("zero wedge field %q should be omitted, got %s", key, zeroData)
		}
	}

	// Pre-instrumentation provider: a payload without any wedge field decodes to
	// the zero values (never a panic, never a spurious wedge).
	var legacy BackendSlotCapacity
	if err := json.Unmarshal([]byte(`{"model":"m","state":"running","num_running":1}`), &legacy); err != nil {
		t.Fatalf("unmarshal legacy: %v", err)
	}
	if legacy.StepsExecuted != 0 || legacy.Admits != 0 || legacy.WedgeSuspected {
		t.Fatalf("legacy slot should default wedge fields to zero/false, got %+v", legacy)
	}
}

// The v0.8.0 paged-KV rollout discriminator. `KVBackend` is a *string, not a
// string, for exactly one reason: a pre-0.8.0 provider omits `kv_backend`
// entirely and nil must read as UNKNOWN. A plain string would decode omission
// to "", making "old provider" indistinguishable from any value a provider
// actually sent — and a rollout dashboard that folds unknown into contiguous
// reports an A/B comparison that is simply false. The three tests below pin
// present, omitted and explicit-empty as three DIFFERENT decoded states.

func TestBackendSlotCapacityKVBackendRoundTrip(t *testing.T) {
	paged := "paged"
	msg := HeartbeatMessage{
		Type:   TypeHeartbeat,
		Status: "serving",
		BackendCapacity: &BackendCapacity{
			Slots: []BackendSlotCapacity{{
				Model:     "gemma-4-26b-qat-4bit",
				State:     "running",
				KVBackend: &paged,
			}},
		},
	}

	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if !bytes.Contains(data, []byte(`"kv_backend":"paged"`)) {
		t.Fatalf("kv_backend missing from wire: %s", data)
	}

	var decoded HeartbeatMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if decoded.BackendCapacity == nil || len(decoded.BackendCapacity.Slots) != 1 {
		t.Fatalf("decoded slots = %+v", decoded.BackendCapacity)
	}
	got := decoded.BackendCapacity.Slots[0].KVBackend
	if got == nil {
		t.Fatal("KVBackend decoded nil, want \"paged\"")
	}
	if *got != "paged" {
		t.Fatalf("KVBackend=%q, want \"paged\"", *got)
	}

	// The other shipped kind, so the field is not accidentally paged-only and a
	// contiguous slot is a POSITIVE observation rather than an absence.
	contiguous := "contiguous"
	slotData, err := json.Marshal(BackendSlotCapacity{
		Model: "gpt-oss-20b", State: "running", KVBackend: &contiguous,
	})
	if err != nil {
		t.Fatalf("marshal contiguous: %v", err)
	}
	var contiguousSlot BackendSlotCapacity
	if err := json.Unmarshal(slotData, &contiguousSlot); err != nil {
		t.Fatalf("unmarshal contiguous: %v", err)
	}
	if contiguousSlot.KVBackend == nil || *contiguousSlot.KVBackend != "contiguous" {
		t.Fatalf("contiguous round-trip = %v", contiguousSlot.KVBackend)
	}
}

func TestBackendSlotCapacityKVBackendOmittedCompatibility(t *testing.T) {
	// Exactly the pre-0.8.0 heartbeat shape.
	data := []byte(`{
		"type":"heartbeat",
		"status":"serving",
		"active_model":null,
		"stats":{},
		"system_metrics":{},
		"backend_capacity":{"slots":[{"model":"qwen","state":"running"}]}
	}`)

	var decoded HeartbeatMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if decoded.BackendCapacity == nil || len(decoded.BackendCapacity.Slots) != 1 {
		t.Fatalf("decoded slots = %+v", decoded.BackendCapacity)
	}
	// nil, i.e. UNKNOWN — not "", not "contiguous". A legacy provider is not a
	// contiguous data point.
	if got := decoded.BackendCapacity.Slots[0].KVBackend; got != nil {
		t.Fatalf("omitted kv_backend decoded to %q, want nil (unknown)", *got)
	}

	// Reverse direction: a slot that never sets it keeps the prior wire shape,
	// so a 0.8.0 coordinator stays byte-compatible with pre-0.8.0 consumers.
	legacyShape, err := json.Marshal(BackendSlotCapacity{Model: "qwen", State: "running"})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if bytes.Contains(legacyShape, []byte("kv_backend")) {
		t.Fatalf("nil KVBackend should be omitted, got %s", legacyShape)
	}
}

func TestBackendSlotCapacityKVBackendExplicitEmptyCompatibility(t *testing.T) {
	data := []byte(`{
		"type":"heartbeat",
		"status":"serving",
		"active_model":null,
		"stats":{},
		"system_metrics":{},
		"backend_capacity":{"slots":[{"model":"qwen","state":"running","kv_backend":""}]}
	}`)

	var decoded HeartbeatMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if decoded.BackendCapacity == nil || len(decoded.BackendCapacity.Slots) != 1 {
		t.Fatalf("decoded slots = %+v", decoded.BackendCapacity)
	}
	got := decoded.BackendCapacity.Slots[0].KVBackend
	if got == nil {
		t.Fatal("explicit empty kv_backend decoded to nil: omission and an explicit empty value must stay distinguishable")
	}
	if *got != "" {
		t.Fatalf("explicit empty kv_backend = %q, want \"\"", *got)
	}

	// `omitempty` on a POINTER tests the pointer, not the pointee, so an
	// explicit "" survives a re-marshal instead of collapsing into omission.
	// This is the mechanism the whole present/omitted/empty distinction rests
	// on: a plain `string` field would drop the key here and silently downgrade
	// an authoritative empty value to "unknown".
	empty := ""
	reencoded, err := json.Marshal(BackendSlotCapacity{
		Model: "qwen", State: "running", KVBackend: &empty,
	})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if !bytes.Contains(reencoded, []byte(`"kv_backend":""`)) {
		t.Fatalf("explicit empty kv_backend should survive marshal, got %s", reencoded)
	}
}

// `kv_backend_fallback_reason` is the OTHER half of the rollout discriminator,
// and its omission semantics are the INVERSE of `kv_backend`'s: absent means
// the slot did NOT degrade, not that the answer is unknown. Both halves are
// pinned here in one test because a field that is always present is not a
// signal — the degraded case proving the reason arrives is worth nothing
// unless the clean case proves the key stays off the wire.
func TestBackendSlotCapacityKVBackendFallbackReasonRoundTrip(t *testing.T) {
	// 1. DEGRADED — the slot was configured paged, paged did not happen, it
	//    serves contiguous and SAYS SO. Without the reason this row is
	//    byte-identical to an operator who configured contiguous on purpose.
	contiguous := "contiguous"
	reason := "pool_construction_capacity: needed 3221225472, available 2147483648"
	msg := HeartbeatMessage{
		Type:   TypeHeartbeat,
		Status: "serving",
		BackendCapacity: &BackendCapacity{
			Slots: []BackendSlotCapacity{{
				Model:                   "gemma-4-26b-qat-4bit",
				State:                   "running",
				KVBackend:               &contiguous,
				KVBackendFallbackReason: &reason,
			}},
		},
	}
	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if !bytes.Contains(data, []byte(`"kv_backend_fallback_reason":"pool_construction_capacity:`)) {
		t.Fatalf("kv_backend_fallback_reason missing from wire: %s", data)
	}
	var decoded HeartbeatMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if decoded.BackendCapacity == nil || len(decoded.BackendCapacity.Slots) != 1 {
		t.Fatalf("decoded slots = %+v", decoded.BackendCapacity)
	}
	slot := decoded.BackendCapacity.Slots[0]
	if slot.KVBackendFallbackReason == nil {
		t.Fatal("degraded slot decoded a nil reason — the degrade is invisible again")
	}
	if *slot.KVBackendFallbackReason != reason {
		t.Fatalf("reason = %q, want %q", *slot.KVBackendFallbackReason, reason)
	}
	// The resolved kind is unchanged by the degrade: the slot really is
	// serving contiguous. The pair is what carries the meaning.
	if slot.KVBackend == nil || *slot.KVBackend != contiguous {
		t.Fatalf("degraded slot's resolved kind = %v, want contiguous", slot.KVBackend)
	}

	// 2. NOT DEGRADED — an operator who chose contiguous. Same model, same
	//    state, same resolved kind, and the key must be ABSENT from the wire:
	//    not "", not "none". Encoded from a slot IDENTICAL to the degraded one
	//    apart from the reason, so the byte comparison below is exactly the
	//    question the rollout dashboard asks.
	degradedSlot, err := json.Marshal(BackendSlotCapacity{
		Model: "gemma-4-26b-qat-4bit", State: "running",
		KVBackend: &contiguous, KVBackendFallbackReason: &reason,
	})
	if err != nil {
		t.Fatalf("marshal degraded slot: %v", err)
	}
	clean, err := json.Marshal(BackendSlotCapacity{
		Model: "gemma-4-26b-qat-4bit", State: "running", KVBackend: &contiguous,
	})
	if err != nil {
		t.Fatalf("marshal clean: %v", err)
	}
	if bytes.Contains(clean, []byte("kv_backend_fallback_reason")) {
		t.Fatalf("a slot that did not degrade must omit the key entirely, got %s", clean)
	}
	var cleanSlot BackendSlotCapacity
	if err := json.Unmarshal(clean, &cleanSlot); err != nil {
		t.Fatalf("unmarshal clean: %v", err)
	}
	if cleanSlot.KVBackendFallbackReason != nil {
		t.Fatalf("clean slot decoded reason %q, want nil", *cleanSlot.KVBackendFallbackReason)
	}
	// The whole ticket in one assertion: before this field, these two slots
	// were the same bytes and the fleet could not tell a choice from a
	// regression.
	if bytes.Equal(degradedSlot, clean) {
		t.Fatalf("degraded and deliberate contiguous slots are byte-identical: %s", clean)
	}

	// 3. PRE-0.8.0 — neither key. Reading absence as "did not degrade" here
	//    would be wrong, which is why the pair is read together: no
	//    `kv_backend` at all is the UNKNOWN state.
	var legacy BackendSlotCapacity
	if err := json.Unmarshal([]byte(`{"model":"qwen","state":"running"}`), &legacy); err != nil {
		t.Fatalf("unmarshal legacy: %v", err)
	}
	if legacy.KVBackend != nil || legacy.KVBackendFallbackReason != nil {
		t.Fatalf("legacy slot decoded %+v, want both nil", legacy)
	}
}
