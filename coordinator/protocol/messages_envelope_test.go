package protocol

import (
	"encoding/json"
	"net/http"
	"testing"
)

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

// TestProviderMessageUnmarshalRegisterLegacyHypervisorCapability is the
// legacy-fleet wire guard for the retired hypervisor_active capability.
// Old providers (< v0.6.31) still send it inside privacy_capabilities;
// the Go field was removed, so it must decode as a harmless unknown
// field — no error, all remaining capabilities intact.
func TestProviderMessageUnmarshalRegisterLegacyHypervisorCapability(t *testing.T) {
	raw := `{"type":"register","hardware":{"chip_name":"Apple M3 Max","memory_gb":64},"models":[{"id":"m1","model_type":"chat","quantization":"4bit"}],"backend":"mlx_swift","privacy_capabilities":{"text_backend_inprocess":true,"text_proxy_disabled":true,"python_runtime_locked":true,"dangerous_modules_blocked":true,"sip_enabled":true,"anti_debug_enabled":true,"core_dumps_disabled":true,"env_scrubbed":true,"hypervisor_active":false}}`

	var pm ProviderMessage
	if err := json.Unmarshal([]byte(raw), &pm); err != nil {
		t.Fatalf("legacy register frame with hypervisor_active must decode: %v", err)
	}

	reg, ok := pm.Payload.(*RegisterMessage)
	if !ok {
		t.Fatalf("payload type = %T, want *RegisterMessage", pm.Payload)
	}
	caps := reg.PrivacyCapabilities
	if caps == nil {
		t.Fatal("privacy_capabilities missing after decode")
	}
	if !caps.TextBackendInprocess || !caps.TextProxyDisabled || !caps.SIPEnabled ||
		!caps.AntiDebugEnabled || !caps.CoreDumpsDisabled || !caps.EnvScrubbed {
		t.Fatalf("privacy capabilities lost around the ignored hypervisor_active field: %+v", caps)
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
	raw := `{"type":"inference_error","request_id":"err-1","error":"model not loaded","status_code":500,"error_reason":"model_load"}`

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
	if errMsg.ErrorReason != "model_load" {
		t.Errorf("error_reason = %q, want model_load", errMsg.ErrorReason)
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
