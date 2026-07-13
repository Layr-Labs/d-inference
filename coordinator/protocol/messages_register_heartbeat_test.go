package protocol

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

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
	if strings.Contains(string(data), "private_only") {
		t.Errorf("private_only=false should be omitted, got %s", data)
	}
	data, _ = json.Marshal(RegisterMessage{Type: TypeRegister, PrivateOnly: true})
	var back RegisterMessage
	if err := json.Unmarshal(data, &back); err != nil || !back.PrivateOnly {
		t.Errorf("private_only=true round-trip failed: %v / %s", err, data)
	}
}

func TestRegisterMessageReleaseChannelSymmetry(t *testing.T) {
	swiftJSON := `{"type":"register","hardware":{},"models":[],"backend":"mlx-swift","release_channel":"beta"}`
	var decoded RegisterMessage
	if err := json.Unmarshal([]byte(swiftJSON), &decoded); err != nil {
		t.Fatalf("unmarshal swift payload: %v", err)
	}
	if decoded.ReleaseChannel != "beta" {
		t.Fatalf("release_channel = %q, want beta", decoded.ReleaseChannel)
	}

	data, err := json.Marshal(RegisterMessage{Type: TypeRegister})
	if err != nil {
		t.Fatalf("marshal stable payload: %v", err)
	}
	if strings.Contains(string(data), "release_channel") {
		t.Fatalf("empty stable release channel should be omitted, got %s", data)
	}
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
	if strings.Contains(string(data), "apns_device_token") || strings.Contains(string(data), "apns_environment") {
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
	if strings.Contains(string(data), "apns_device_token") || strings.Contains(string(data), "apns_environment") {
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
