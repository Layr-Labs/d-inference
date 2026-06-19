package protocol

import (
	"bytes"
	"encoding/json"
	"net/http"
	"testing"
)

// TestModelInfoIsVisionSymmetry verifies the v0.6.0 is_vision field round-trips
// and is omitted when false, so a text-only build is wire-compatible with
// pre-0.6.0 providers (which never send it and decode it as false).
func TestModelInfoIsVisionSymmetry(t *testing.T) {
	// Vision build: is_vision present and true.
	vis := ModelInfo{ID: "gemma-4-26b-qat-4bit", SizeBytes: 1, IsVision: true}
	b, err := json.Marshal(vis)
	if err != nil {
		t.Fatalf("marshal vision: %v", err)
	}
	if !bytes.Contains(b, []byte(`"is_vision":true`)) {
		t.Fatalf("expected is_vision:true in JSON, got %s", b)
	}
	var back ModelInfo
	if err := json.Unmarshal(b, &back); err != nil {
		t.Fatalf("unmarshal vision: %v", err)
	}
	if !back.IsVision {
		t.Fatal("expected IsVision=true after round-trip")
	}

	// Text-only build: is_vision omitted entirely (omitempty), and a payload with
	// no is_vision key decodes to false.
	text := ModelInfo{ID: "gpt-oss-20b", SizeBytes: 1}
	b, err = json.Marshal(text)
	if err != nil {
		t.Fatalf("marshal text: %v", err)
	}
	if bytes.Contains(b, []byte("is_vision")) {
		t.Fatalf("expected is_vision to be omitted for a text-only build, got %s", b)
	}
	var legacy ModelInfo
	if err := json.Unmarshal([]byte(`{"id":"gpt-oss-20b","size_bytes":1}`), &legacy); err != nil {
		t.Fatalf("unmarshal legacy: %v", err)
	}
	if legacy.IsVision {
		t.Fatal("expected IsVision=false when the field is absent (pre-0.6.0 provider)")
	}
}

// TestModelInfoTemplateRenderOKSymmetry verifies the tri-state
// template_render_ok field survives the wire: true encodes, FALSE ENCODES
// (pointer false is the exclusion signal — omitempty must not drop it), nil is
// omitted entirely, and an absent key decodes back to nil (pre-0.6.5 provider,
// no opinion).
func TestModelInfoTemplateRenderOKSymmetry(t *testing.T) {
	// Self-check passed: template_render_ok present and true.
	renderOK := true
	pass := ModelInfo{ID: "gemma-4-26b-qat-4bit", SizeBytes: 1, TemplateRenderOK: &renderOK}
	b, err := json.Marshal(pass)
	if err != nil {
		t.Fatalf("marshal render-ok: %v", err)
	}
	if !bytes.Contains(b, []byte(`"template_render_ok":true`)) {
		t.Fatalf("expected template_render_ok:true in JSON, got %s", b)
	}
	var back ModelInfo
	if err := json.Unmarshal(b, &back); err != nil {
		t.Fatalf("unmarshal render-ok: %v", err)
	}
	if back.TemplateRenderOK == nil || !*back.TemplateRenderOK {
		t.Fatalf("expected TemplateRenderOK=*true after round-trip, got %v", back.TemplateRenderOK)
	}

	// Self-check FAILED: pointer false must encode and round-trip — it is the
	// signal that excludes the provider from tool-bearing requests.
	renderBroken := false
	fail := ModelInfo{ID: "gemma-4-26b-qat-4bit", SizeBytes: 1, TemplateRenderOK: &renderBroken}
	b, err = json.Marshal(fail)
	if err != nil {
		t.Fatalf("marshal render-broken: %v", err)
	}
	if !bytes.Contains(b, []byte(`"template_render_ok":false`)) {
		t.Fatalf("pointer false must survive omitempty and encode, got %s", b)
	}
	back = ModelInfo{}
	if err := json.Unmarshal(b, &back); err != nil {
		t.Fatalf("unmarshal render-broken: %v", err)
	}
	if back.TemplateRenderOK == nil || *back.TemplateRenderOK {
		t.Fatalf("expected TemplateRenderOK=*false after round-trip, got %v", back.TemplateRenderOK)
	}

	// Pre-0.6.5 provider: nil omits the key, and a payload without the key
	// decodes to nil (no opinion), never to false.
	legacy := ModelInfo{ID: "gpt-oss-20b", SizeBytes: 1}
	b, err = json.Marshal(legacy)
	if err != nil {
		t.Fatalf("marshal legacy: %v", err)
	}
	if bytes.Contains(b, []byte("template_render_ok")) {
		t.Fatalf("expected template_render_ok to be omitted when nil, got %s", b)
	}
	var decoded ModelInfo
	if err := json.Unmarshal([]byte(`{"id":"gpt-oss-20b","size_bytes":1}`), &decoded); err != nil {
		t.Fatalf("unmarshal legacy: %v", err)
	}
	if decoded.TemplateRenderOK != nil {
		t.Fatalf("expected TemplateRenderOK=nil when the field is absent, got %v", *decoded.TemplateRenderOK)
	}
}

func TestRegisterMessageMarshal(t *testing.T) {
	msg := RegisterMessage{
		Type: TypeRegister,
		Hardware: Hardware{
			MachineModel:       "Mac15,8",
			ChipName:           "Apple M3 Max",
			ChipFamily:         "M3",
			ChipTier:           "Max",
			MemoryGB:           64,
			MemoryAvailableGB:  60,
			CPUCores:           CPUCores{Total: 16, Performance: 12, Efficiency: 4},
			GPUCores:           40,
			MemoryBandwidthGBs: 400,
		},
		Models: []ModelInfo{
			{
				ID:           "mlx-community/Qwen3.5-9B-Instruct-4bit",
				SizeBytes:    5700000000,
				ModelType:    "qwen3",
				Quantization: "4bit",
			},
		},
		Backend:                 "vllm_mlx",
		EncryptedResponseChunks: true,
	}

	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded RegisterMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if decoded.Type != TypeRegister {
		t.Errorf("type = %q, want %q", decoded.Type, TypeRegister)
	}
	if decoded.Hardware.ChipName != "Apple M3 Max" {
		t.Errorf("chip = %q, want %q", decoded.Hardware.ChipName, "Apple M3 Max")
	}
	if len(decoded.Models) != 1 {
		t.Fatalf("models len = %d, want 1", len(decoded.Models))
	}
	if decoded.Models[0].ID != "mlx-community/Qwen3.5-9B-Instruct-4bit" {
		t.Errorf("model id = %q", decoded.Models[0].ID)
	}
	if decoded.Backend != "vllm_mlx" {
		t.Errorf("backend = %q, want %q", decoded.Backend, "vllm_mlx")
	}
	if !decoded.EncryptedResponseChunks {
		t.Error("encrypted_response_chunks should round-trip")
	}
}

// TestRegisterMessagePrivateOnlySymmetry verifies the coordinator decodes the
// private_only flag the Swift provider emits (snake_case key, only present when
// true), and that the Go side round-trips it. Protects the Go↔Swift protocol
// symmetry for the self-route "private machine" mode.
func TestRegisterMessagePrivateOnlySymmetry(t *testing.T) {
	// A minimal register payload exactly as the Swift ProviderMessage encoder
	// emits it (private_only present and true).
	swiftJSON := `{
		"type": "register",
		"hardware": {"chip_name": "Apple M3 Max", "memory_gb": 64},
		"models": [{"id": "m", "model_type": "qwen3", "quantization": "4bit"}],
		"backend": "mlx",
		"public_key": "abc",
		"auth_token": "tok",
		"private_only": true
	}`
	var decoded RegisterMessage
	if err := json.Unmarshal([]byte(swiftJSON), &decoded); err != nil {
		t.Fatalf("unmarshal swift payload: %v", err)
	}
	if !decoded.PrivateOnly {
		t.Fatal("private_only=true from the Swift payload did not decode")
	}

	// Omitted private_only must default to false (Swift omits it when false).
	withoutFlag := `{"type":"register","hardware":{},"models":[],"backend":"mlx"}`
	var d2 RegisterMessage
	if err := json.Unmarshal([]byte(withoutFlag), &d2); err != nil {
		t.Fatalf("unmarshal without flag: %v", err)
	}
	if d2.PrivateOnly {
		t.Fatal("private_only should default to false when omitted")
	}

	// Go round-trip: false is omitted (omitempty), true survives.
	data, _ := json.Marshal(RegisterMessage{Type: TypeRegister, PrivateOnly: false})
	if contains(string(data), "private_only") {
		t.Errorf("private_only=false should be omitted, got %s", data)
	}
	data, _ = json.Marshal(RegisterMessage{Type: TypeRegister, PrivateOnly: true})
	var back RegisterMessage
	if err := json.Unmarshal(data, &back); err != nil || !back.PrivateOnly {
		t.Errorf("private_only=true round-trip failed: %v / %s", err, data)
	}
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}

func TestRegisterMessageAPNsFieldsSymmetry(t *testing.T) {
	// A register payload exactly as the Swift ProviderMessage encoder emits it
	// with the v0.6.0 APNs code-identity fields present.
	swiftJSON := `{
		"type": "register",
		"hardware": {},
		"models": [],
		"backend": "mlx",
		"public_key": "abc",
		"apns_device_token": "cb1ceb489ec9",
		"apns_environment": "production"
	}`
	var decoded RegisterMessage
	if err := json.Unmarshal([]byte(swiftJSON), &decoded); err != nil {
		t.Fatalf("unmarshal swift payload: %v", err)
	}
	if decoded.APNsDeviceToken != "cb1ceb489ec9" {
		t.Errorf("apns_device_token did not decode: %q", decoded.APNsDeviceToken)
	}
	if decoded.APNsEnvironment != "production" {
		t.Errorf("apns_environment did not decode: %q", decoded.APNsEnvironment)
	}

	// Both fields are omitempty: an empty register must not emit them (Swift omits
	// them when nil, so the Go encoder must too, or symmetry tests drift).
	data, _ := json.Marshal(RegisterMessage{Type: TypeRegister})
	if contains(string(data), "apns_device_token") || contains(string(data), "apns_environment") {
		t.Errorf("empty APNs fields should be omitted, got %s", data)
	}

	// Round-trip with values.
	data, _ = json.Marshal(RegisterMessage{Type: TypeRegister, APNsDeviceToken: "tok", APNsEnvironment: "development"})
	var back RegisterMessage
	if err := json.Unmarshal(data, &back); err != nil {
		t.Fatalf("round-trip unmarshal: %v", err)
	}
	if back.APNsDeviceToken != "tok" || back.APNsEnvironment != "development" {
		t.Errorf("APNs fields round-trip failed: %+v from %s", back, data)
	}
}

func TestCodeAttestationResponseMessageMarshal(t *testing.T) {
	msg := CodeAttestationResponseMessage{
		Type:      TypeCodeAttestationResponse,
		Nonce:     "bm9uY2U=",
		Signature: "c2ln",
	}
	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	// Decode via the ProviderMessage envelope — the discriminator path the
	// coordinator's read loop uses to route this message.
	var pm ProviderMessage
	if err := json.Unmarshal(data, &pm); err != nil {
		t.Fatalf("envelope unmarshal: %v", err)
	}
	if pm.Type != TypeCodeAttestationResponse {
		t.Errorf("type = %q, want %q", pm.Type, TypeCodeAttestationResponse)
	}
	got, ok := pm.Payload.(*CodeAttestationResponseMessage)
	if !ok {
		t.Fatalf("payload type = %T, want *CodeAttestationResponseMessage", pm.Payload)
	}
	if got.Nonce != "bm9uY2U=" || got.Signature != "c2ln" {
		t.Errorf("round-trip mismatch: %+v", got)
	}
}

func TestHeartbeatMessageMarshal(t *testing.T) {
	msg := HeartbeatMessage{
		Type:        TypeHeartbeat,
		Status:      "idle",
		ActiveModel: nil,
		Stats: HeartbeatStats{
			RequestsServed:  10,
			TokensGenerated: 5000,
		},
	}

	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded HeartbeatMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if decoded.Status != "idle" {
		t.Errorf("status = %q, want %q", decoded.Status, "idle")
	}
	if decoded.ActiveModel != nil {
		t.Errorf("active_model = %v, want nil", decoded.ActiveModel)
	}
	if decoded.Stats.RequestsServed != 10 {
		t.Errorf("requests_served = %d, want 10", decoded.Stats.RequestsServed)
	}
}

func TestHeartbeatMessageAPNsFieldsSymmetry(t *testing.T) {
	// A heartbeat payload exactly as the Swift ProviderMessage encoder emits it
	// once a late/changed APNs device token is carried in the heartbeat (W5 Fix 2).
	swiftJSON := `{
		"type": "heartbeat",
		"status": "idle",
		"active_model": null,
		"stats": {"requests_served": 0, "tokens_generated": 0},
		"system_metrics": {"memory_pressure": 0, "cpu_usage": 0, "thermal_state": "nominal"},
		"apns_device_token": "cb1ceb489ec9",
		"apns_environment": "production"
	}`
	var decoded HeartbeatMessage
	if err := json.Unmarshal([]byte(swiftJSON), &decoded); err != nil {
		t.Fatalf("unmarshal swift payload: %v", err)
	}
	if decoded.APNsDeviceToken != "cb1ceb489ec9" {
		t.Errorf("apns_device_token did not decode: %q", decoded.APNsDeviceToken)
	}
	if decoded.APNsEnvironment != "production" {
		t.Errorf("apns_environment did not decode: %q", decoded.APNsEnvironment)
	}

	// Both fields are omitempty: a token-less heartbeat (the steady state, and
	// what the Swift encoder emits when nil) must NOT emit them, or the symmetry
	// tests on the Swift side drift.
	data, _ := json.Marshal(HeartbeatMessage{Type: TypeHeartbeat, Status: "idle"})
	if contains(string(data), "apns_device_token") || contains(string(data), "apns_environment") {
		t.Errorf("empty APNs heartbeat fields should be omitted, got %s", data)
	}

	// Round-trip with values.
	data, _ = json.Marshal(HeartbeatMessage{Type: TypeHeartbeat, Status: "idle", APNsDeviceToken: "tok", APNsEnvironment: "development"})
	var back HeartbeatMessage
	if err := json.Unmarshal(data, &back); err != nil {
		t.Fatalf("round-trip unmarshal: %v", err)
	}
	if back.APNsDeviceToken != "tok" || back.APNsEnvironment != "development" {
		t.Errorf("APNs heartbeat fields round-trip failed: %+v from %s", back, data)
	}
}

func TestHeartbeatStatsOutcomeCountersSymmetry(t *testing.T) {
	stats := HeartbeatStats{
		RequestsServed:               11,
		TokensGenerated:              22,
		CancellationsReceived:        3,
		CancellationsBeforeOutput:    4,
		CancellationsPartialComplete: 5,
		GenerationErrorsAfterOutput:  6,
		ChunkEncryptionErrors:        7,
		StreamClosedWithoutTerminal:  8,
		CancelDuringModelLoad:        9,
		UsageGaps:                    10,
	}

	data, err := json.Marshal(stats)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	for _, field := range []string{
		`"cancellations_received":3`,
		`"cancellations_before_output":4`,
		`"cancellations_partial_complete":5`,
		`"generation_errors_after_output":6`,
		`"chunk_encryption_errors":7`,
		`"stream_closed_without_terminal":8`,
		`"cancel_during_model_load":9`,
		`"usage_gaps":10`,
	} {
		if !bytes.Contains(data, []byte(field)) {
			t.Fatalf("expected %s in JSON, got %s", field, data)
		}
	}

	var decoded HeartbeatStats
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if decoded != stats {
		t.Fatalf("decoded stats = %+v, want %+v", decoded, stats)
	}

	zeroData, err := json.Marshal(HeartbeatStats{})
	if err != nil {
		t.Fatalf("marshal zero: %v", err)
	}
	for _, field := range []string{
		"cancellations_received",
		"cancellations_before_output",
		"cancellations_partial_complete",
		"generation_errors_after_output",
		"chunk_encryption_errors",
		"stream_closed_without_terminal",
		"cancel_during_model_load",
		"usage_gaps",
	} {
		if bytes.Contains(zeroData, []byte(field)) {
			t.Fatalf("expected zero-value field %q to be omitted, got %s", field, zeroData)
		}
	}

	var legacy HeartbeatStats
	if err := json.Unmarshal([]byte(`{"requests_served":1,"tokens_generated":2}`), &legacy); err != nil {
		t.Fatalf("unmarshal legacy: %v", err)
	}
	if legacy.RequestsServed != 1 || legacy.TokensGenerated != 2 || legacy.UsageGaps != 0 {
		t.Fatalf("legacy stats = %+v, want old counters plus zero outcome counters", legacy)
	}
}

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

func TestHeartbeatWithActiveModel(t *testing.T) {
	model := "qwen3.5-9b"
	msg := HeartbeatMessage{
		Type:        TypeHeartbeat,
		Status:      "serving",
		ActiveModel: &model,
		Stats:       HeartbeatStats{RequestsServed: 1, TokensGenerated: 100},
	}

	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded HeartbeatMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if decoded.ActiveModel == nil {
		t.Fatal("active_model is nil")
	}
	if *decoded.ActiveModel != "qwen3.5-9b" {
		t.Errorf("active_model = %q, want %q", *decoded.ActiveModel, "qwen3.5-9b")
	}
}

func TestProviderMessageUnmarshalLoadModelStatus(t *testing.T) {
	data := []byte(`{"type":"load_model_status","model_id":"qwen","status":"failed","error":"GPU OOM"}`)

	var msg ProviderMessage
	if err := json.Unmarshal(data, &msg); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if msg.Type != TypeLoadModelStatus {
		t.Fatalf("Type=%q, want %q", msg.Type, TypeLoadModelStatus)
	}
	status, ok := msg.Payload.(*LoadModelStatusMessage)
	if !ok {
		t.Fatalf("Payload=%T, want *LoadModelStatusMessage", msg.Payload)
	}
	if status.ModelID != "qwen" || status.Status != LoadModelStatusFailed || status.Error != "GPU OOM" {
		t.Fatalf("decoded status = %+v", status)
	}
}

func TestPrefetchModelMessageMarshal(t *testing.T) {
	msg := PrefetchModelMessage{
		Type:     TypePrefetchModel,
		ModelID:  "mlx-community/gemma-4-26B-A4B-it-qat-4bit",
		Priority: 5,
	}
	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var out PrefetchModelMessage
	if err := json.Unmarshal(data, &out); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if out.Type != TypePrefetchModel || out.ModelID != msg.ModelID || out.Priority != 5 {
		t.Fatalf("round-trip mismatch: %+v", out)
	}

	// Priority is omitempty: a zero priority must not appear on the wire so
	// the Swift `if p.priority != 0` mirror stays byte-compatible.
	zero, _ := json.Marshal(PrefetchModelMessage{Type: TypePrefetchModel, ModelID: "m"})
	if bytes.Contains(zero, []byte("priority")) {
		t.Fatalf("zero priority should be omitted: %s", zero)
	}
}

func TestProviderMessageUnmarshalPrefetchModelStatus(t *testing.T) {
	data := []byte(`{"type":"prefetch_model_status","model_id":"gemma","status":"downloading","bytes_done":1048576,"bytes_total":15600000000}`)

	var msg ProviderMessage
	if err := json.Unmarshal(data, &msg); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if msg.Type != TypePrefetchModelStatus {
		t.Fatalf("Type=%q, want %q", msg.Type, TypePrefetchModelStatus)
	}
	status, ok := msg.Payload.(*PrefetchModelStatusMessage)
	if !ok {
		t.Fatalf("Payload=%T, want *PrefetchModelStatusMessage", msg.Payload)
	}
	if status.ModelID != "gemma" || status.Status != PrefetchModelStatusDownloading {
		t.Fatalf("decoded status = %+v", status)
	}
	if status.BytesDone != 1048576 || status.BytesTotal != 15600000000 {
		t.Fatalf("byte counts = %d/%d", status.BytesDone, status.BytesTotal)
	}
}

func TestProviderMessageUnmarshalModelsUpdate(t *testing.T) {
	// The wire form a provider sends after a verified prefetch (mirrors the
	// Swift ModelInfo encoding used by `register`).
	data := []byte(`{"type":"models_update","models":[{"id":"mlx-community/gemma-4-26B-A4B-it-qat-4bit","size_bytes":15600000000,"model_type":"chat","quantization":"4bit","weight_hash":"abc123"}]}`)

	var msg ProviderMessage
	if err := json.Unmarshal(data, &msg); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if msg.Type != TypeModelsUpdate {
		t.Fatalf("Type=%q, want %q", msg.Type, TypeModelsUpdate)
	}
	upd, ok := msg.Payload.(*ModelsUpdateMessage)
	if !ok {
		t.Fatalf("Payload=%T, want *ModelsUpdateMessage", msg.Payload)
	}
	if len(upd.Models) != 1 {
		t.Fatalf("models len = %d, want 1", len(upd.Models))
	}
	m := upd.Models[0]
	if m.ID != "mlx-community/gemma-4-26B-A4B-it-qat-4bit" || m.ModelType != "chat" || m.WeightHash != "abc123" {
		t.Fatalf("decoded model = %+v", m)
	}
}

func TestPrefetchModelStatusVerifiedRoundTrip(t *testing.T) {
	msg := PrefetchModelStatusMessage{
		Type:    TypePrefetchModelStatus,
		ModelID: "gemma",
		Status:  PrefetchModelStatusVerified,
	}
	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	// Zero byte counts are omitempty (terminal "verified" carries no progress).
	if bytes.Contains(data, []byte("bytes_done")) || bytes.Contains(data, []byte("bytes_total")) {
		t.Fatalf("zero byte counts should be omitted: %s", data)
	}
	var pm ProviderMessage
	if err := json.Unmarshal(data, &pm); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	status := pm.Payload.(*PrefetchModelStatusMessage)
	if status.Status != PrefetchModelStatusVerified || status.BytesDone != 0 {
		t.Fatalf("decoded = %+v", status)
	}
}

func TestInferenceResponseChunkMarshal(t *testing.T) {
	msg := InferenceResponseChunkMessage{
		Type:      TypeInferenceResponseChunk,
		RequestID: "req-123",
		Data:      "data: {\"id\":\"chatcmpl-xxx\",\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n",
	}

	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded InferenceResponseChunkMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if decoded.RequestID != "req-123" {
		t.Errorf("request_id = %q, want %q", decoded.RequestID, "req-123")
	}
	if decoded.Data == "" {
		t.Error("data is empty")
	}
}

func TestInferenceCompleteMarshal(t *testing.T) {
	msg := InferenceCompleteMessage{
		Type:      TypeInferenceComplete,
		RequestID: "req-456",
		Usage:     UsageInfo{PromptTokens: 50, CompletionTokens: 100},
	}

	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded InferenceCompleteMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if decoded.Usage.PromptTokens != 50 {
		t.Errorf("prompt_tokens = %d, want 50", decoded.Usage.PromptTokens)
	}
	if decoded.Usage.CompletionTokens != 100 {
		t.Errorf("completion_tokens = %d, want 100", decoded.Usage.CompletionTokens)
	}
}

func TestInferenceErrorMarshal(t *testing.T) {
	msg := InferenceErrorMessage{
		Type:       TypeInferenceError,
		RequestID:  "req-789",
		Error:      "model not loaded",
		StatusCode: 500,
	}

	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded InferenceErrorMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if decoded.Error != "model not loaded" {
		t.Errorf("error = %q", decoded.Error)
	}
	if decoded.StatusCode != http.StatusInternalServerError {
		t.Errorf("status_code = %d, want 500", decoded.StatusCode)
	}
}

func TestInferenceRequestMarshal(t *testing.T) {
	msg := InferenceRequestMessage{
		Type:      TypeInferenceRequest,
		RequestID: "req-abc",
		Body: InferenceRequestBody{
			Model: "qwen3.5-9b",
			Messages: []ChatMessage{
				{Role: "user", Content: "hello"},
			},
			Stream: true,
		},
	}

	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded InferenceRequestMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if decoded.RequestID != "req-abc" {
		t.Errorf("request_id = %q", decoded.RequestID)
	}
	if decoded.Body.Model != "qwen3.5-9b" {
		t.Errorf("model = %q", decoded.Body.Model)
	}
	if !decoded.Body.Stream {
		t.Error("stream should be true")
	}
	if len(decoded.Body.Messages) != 1 || decoded.Body.Messages[0].Content != "hello" {
		t.Errorf("messages = %+v", decoded.Body.Messages)
	}
}

func TestCancelMarshal(t *testing.T) {
	msg := CancelMessage{
		Type:      TypeCancel,
		RequestID: "req-cancel",
	}

	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded CancelMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if decoded.RequestID != "req-cancel" {
		t.Errorf("request_id = %q", decoded.RequestID)
	}
}

func TestProviderMessageUnmarshalRegister(t *testing.T) {
	raw := `{"type":"register","hardware":{"machine_model":"Mac15,8","chip_name":"Apple M3 Max","chip_family":"M3","chip_tier":"Max","memory_gb":64,"memory_available_gb":60,"cpu_cores":{"total":16,"performance":12,"efficiency":4},"gpu_cores":40,"memory_bandwidth_gbs":400},"models":[{"id":"mlx-community/Qwen3.5-9B-Instruct-4bit","size_bytes":5700000000,"model_type":"qwen3","quantization":"4bit"}],"backend":"vllm_mlx"}`

	var pm ProviderMessage
	if err := json.Unmarshal([]byte(raw), &pm); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if pm.Type != TypeRegister {
		t.Errorf("type = %q, want %q", pm.Type, TypeRegister)
	}

	reg, ok := pm.Payload.(*RegisterMessage)
	if !ok {
		t.Fatalf("payload type = %T, want *RegisterMessage", pm.Payload)
	}

	if reg.Hardware.MemoryGB != 64 {
		t.Errorf("memory_gb = %d, want 64", reg.Hardware.MemoryGB)
	}
}

func TestProviderMessageUnmarshalHeartbeat(t *testing.T) {
	raw := `{"type":"heartbeat","status":"idle","active_model":null,"stats":{"requests_served":0,"tokens_generated":0}}`

	var pm ProviderMessage
	if err := json.Unmarshal([]byte(raw), &pm); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if pm.Type != TypeHeartbeat {
		t.Errorf("type = %q, want %q", pm.Type, TypeHeartbeat)
	}

	hb, ok := pm.Payload.(*HeartbeatMessage)
	if !ok {
		t.Fatalf("payload type = %T, want *HeartbeatMessage", pm.Payload)
	}

	if hb.Status != "idle" {
		t.Errorf("status = %q, want %q", hb.Status, "idle")
	}
}

func TestProviderMessageUnmarshalChunk(t *testing.T) {
	raw := `{"type":"inference_response_chunk","request_id":"abc","data":"data: {\"id\":\"chatcmpl-xxx\"}\n\n"}`

	var pm ProviderMessage
	if err := json.Unmarshal([]byte(raw), &pm); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if pm.Type != TypeInferenceResponseChunk {
		t.Errorf("type = %q", pm.Type)
	}
	chunk := pm.Payload.(*InferenceResponseChunkMessage)
	if chunk.RequestID != "abc" {
		t.Errorf("request_id = %q", chunk.RequestID)
	}
}

func TestProviderMessageUnmarshalComplete(t *testing.T) {
	raw := `{"type":"inference_complete","request_id":"xyz","usage":{"prompt_tokens":50,"completion_tokens":100}}`

	var pm ProviderMessage
	if err := json.Unmarshal([]byte(raw), &pm); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	complete := pm.Payload.(*InferenceCompleteMessage)
	if complete.Usage.CompletionTokens != 100 {
		t.Errorf("completion_tokens = %d", complete.Usage.CompletionTokens)
	}
}

func TestProviderMessageUnmarshalError(t *testing.T) {
	raw := `{"type":"inference_error","request_id":"err-1","error":"model not loaded","status_code":500}`

	var pm ProviderMessage
	if err := json.Unmarshal([]byte(raw), &pm); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	errMsg := pm.Payload.(*InferenceErrorMessage)
	if errMsg.Error != "model not loaded" {
		t.Errorf("error = %q", errMsg.Error)
	}
	if errMsg.StatusCode != http.StatusInternalServerError {
		t.Errorf("status_code = %d", errMsg.StatusCode)
	}
}

func TestProviderMessageUnmarshalUnknownType(t *testing.T) {
	raw := `{"type":"unknown_type"}`
	var pm ProviderMessage
	err := json.Unmarshal([]byte(raw), &pm)
	if err == nil {
		t.Fatal("expected error for unknown type")
	}
}

func TestProviderMessageUnmarshalInvalidJSON(t *testing.T) {
	raw := `{invalid`
	var pm ProviderMessage
	err := json.Unmarshal([]byte(raw), &pm)
	if err == nil {
		t.Fatal("expected error for invalid JSON")
	}
}

func TestRegisterMessageWithAttestation(t *testing.T) {
	attestationJSON := json.RawMessage(`{"attestation":{"chipName":"Apple M3 Max","hardwareModel":"Mac15,8","publicKey":"dGVzdA=="},"signature":"c2ln"}`)
	msg := RegisterMessage{
		Type: TypeRegister,
		Hardware: Hardware{
			ChipName: "Apple M3 Max",
			MemoryGB: 64,
		},
		Models: []ModelInfo{
			{ID: "qwen3.5-9b", ModelType: "qwen3", Quantization: "4bit"},
		},
		Backend:     "vllm_mlx",
		Attestation: attestationJSON,
	}

	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded RegisterMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if len(decoded.Attestation) == 0 {
		t.Fatal("attestation should not be empty")
	}

	// Verify it contains expected fields
	var attMap map[string]any
	if err := json.Unmarshal(decoded.Attestation, &attMap); err != nil {
		t.Fatalf("unmarshal attestation: %v", err)
	}
	if attMap["signature"] != "c2ln" {
		t.Errorf("signature = %v, want c2ln", attMap["signature"])
	}
}

func TestRegisterMessageWithoutAttestation(t *testing.T) {
	msg := RegisterMessage{
		Type:     TypeRegister,
		Hardware: Hardware{ChipName: "M3 Max", MemoryGB: 64},
		Models:   []ModelInfo{{ID: "test"}},
		Backend:  "test",
	}

	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	// attestation should not appear when nil (omitempty)
	var m map[string]any
	json.Unmarshal(data, &m)
	if _, ok := m["attestation"]; ok {
		t.Error("attestation should be omitted when nil")
	}
}

func TestAttestationChallengeMessageMarshal(t *testing.T) {
	msg := AttestationChallengeMessage{
		Type:      TypeAttestationChallenge,
		Nonce:     "dGVzdG5vbmNl",
		Timestamp: "2025-01-15T10:30:00Z",
	}

	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded AttestationChallengeMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if decoded.Type != TypeAttestationChallenge {
		t.Errorf("type = %q, want %q", decoded.Type, TypeAttestationChallenge)
	}
	if decoded.Nonce != "dGVzdG5vbmNl" {
		t.Errorf("nonce = %q, want dGVzdG5vbmNl", decoded.Nonce)
	}
	if decoded.Timestamp != "2025-01-15T10:30:00Z" {
		t.Errorf("timestamp = %q", decoded.Timestamp)
	}
}

func TestAttestationResponseMessageMarshal(t *testing.T) {
	msg := AttestationResponseMessage{
		Type:      TypeAttestationResponse,
		Nonce:     "dGVzdG5vbmNl",
		Signature: "c2lnbmF0dXJl",
		PublicKey: "cHVia2V5",
	}

	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded AttestationResponseMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if decoded.Type != TypeAttestationResponse {
		t.Errorf("type = %q, want %q", decoded.Type, TypeAttestationResponse)
	}
	if decoded.Nonce != "dGVzdG5vbmNl" {
		t.Errorf("nonce = %q", decoded.Nonce)
	}
	if decoded.Signature != "c2lnbmF0dXJl" {
		t.Errorf("signature = %q", decoded.Signature)
	}
	if decoded.PublicKey != "cHVia2V5" {
		t.Errorf("public_key = %q", decoded.PublicKey)
	}
}

func TestHeartbeatWithSystemMetricsMarshal(t *testing.T) {
	msg := HeartbeatMessage{
		Type:   TypeHeartbeat,
		Status: "idle",
		Stats:  HeartbeatStats{RequestsServed: 5, TokensGenerated: 200},
		SystemMetrics: SystemMetrics{
			MemoryPressure: 0.65,
			CPUUsage:       0.3,
			ThermalState:   "nominal",
		},
	}

	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded HeartbeatMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if decoded.SystemMetrics.MemoryPressure != 0.65 {
		t.Errorf("memory_pressure = %f, want 0.65", decoded.SystemMetrics.MemoryPressure)
	}
	if decoded.SystemMetrics.CPUUsage != 0.3 {
		t.Errorf("cpu_usage = %f, want 0.3", decoded.SystemMetrics.CPUUsage)
	}
	if decoded.SystemMetrics.ThermalState != "nominal" {
		t.Errorf("thermal_state = %q, want nominal", decoded.SystemMetrics.ThermalState)
	}
}

func TestProviderMessageUnmarshalHeartbeatWithMetrics(t *testing.T) {
	raw := `{"type":"heartbeat","status":"idle","active_model":null,"stats":{"requests_served":0,"tokens_generated":0},"system_metrics":{"memory_pressure":0.42,"cpu_usage":0.15,"thermal_state":"fair"}}`

	var pm ProviderMessage
	if err := json.Unmarshal([]byte(raw), &pm); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	hb := pm.Payload.(*HeartbeatMessage)
	if hb.SystemMetrics.MemoryPressure != 0.42 {
		t.Errorf("memory_pressure = %f, want 0.42", hb.SystemMetrics.MemoryPressure)
	}
	if hb.SystemMetrics.ThermalState != "fair" {
		t.Errorf("thermal_state = %q, want fair", hb.SystemMetrics.ThermalState)
	}
}

func TestProviderMessageUnmarshalAttestationResponse(t *testing.T) {
	raw := `{"type":"attestation_response","nonce":"bm9uY2U=","signature":"c2ln","public_key":"a2V5"}`

	var pm ProviderMessage
	if err := json.Unmarshal([]byte(raw), &pm); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if pm.Type != TypeAttestationResponse {
		t.Errorf("type = %q, want %q", pm.Type, TypeAttestationResponse)
	}

	resp, ok := pm.Payload.(*AttestationResponseMessage)
	if !ok {
		t.Fatalf("payload type = %T, want *AttestationResponseMessage", pm.Payload)
	}

	if resp.Nonce != "bm9uY2U=" {
		t.Errorf("nonce = %q", resp.Nonce)
	}
	if resp.Signature != "c2ln" {
		t.Errorf("signature = %q", resp.Signature)
	}
	if resp.PublicKey != "a2V5" {
		t.Errorf("public_key = %q", resp.PublicKey)
	}
}

// ---------------------------------------------------------------------------
// BackendCapacity protocol tests
// ---------------------------------------------------------------------------

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

// TestDesiredModelsMessageMarshal verifies the desired_models wire shape the
// coordinator emits round-trips, including the snake_case keys the Swift decoder
// expects and the omitempty behavior of previous_build (so Go's omission ↔ the
// Swift optional). This is the protocol-symmetry guard for desired_models.
func TestDesiredModelsMessageMarshal(t *testing.T) {
	msg := DesiredModelsMessage{
		Type: TypeDesiredModels,
		Models: []DesiredModelEntry{
			{ModelName: "gemma-4-26b", DesiredBuild: "mlx-community/gemma-4-26B-A4B-it-qat-4bit", PreviousBuild: "mlx-community/gemma-4-26b-a4b-it-fp8"},
			{ModelName: "qwen3.5-9b", DesiredBuild: "mlx-community/Qwen3.5-9B-MLX-4bit"}, // no previous
		},
	}

	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	// Exact wire-key expectations.
	s := string(data)
	for _, want := range []string{`"type":"desired_models"`, `"model_name":"gemma-4-26b"`, `"desired_build":"mlx-community/gemma-4-26B-A4B-it-qat-4bit"`, `"previous_build":"mlx-community/gemma-4-26b-a4b-it-fp8"`} {
		if !bytes.Contains(data, []byte(want)) {
			t.Errorf("marshaled JSON missing %q: %s", want, s)
		}
	}
	// previous_build is omitempty: the second entry (no previous) must not emit it.
	if c := bytes.Count(data, []byte(`"previous_build"`)); c != 1 {
		t.Errorf("previous_build should appear exactly once (omitempty), got %d in %s", c, s)
	}

	var decoded DesiredModelsMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if decoded.Type != TypeDesiredModels {
		t.Errorf("type = %q, want %q", decoded.Type, TypeDesiredModels)
	}
	if len(decoded.Models) != 2 {
		t.Fatalf("models len = %d, want 2", len(decoded.Models))
	}
	if decoded.Models[0].ModelName != "gemma-4-26b" || decoded.Models[0].PreviousBuild != "mlx-community/gemma-4-26b-a4b-it-fp8" {
		t.Errorf("entry 0 round-trip mismatch: %+v", decoded.Models[0])
	}
	if decoded.Models[1].PreviousBuild != "" {
		t.Errorf("entry 1 previous_build should be empty, got %q", decoded.Models[1].PreviousBuild)
	}
}
