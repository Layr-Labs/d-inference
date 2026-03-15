package protocol

import (
	"encoding/json"
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
		Backend: "vllm_mlx",
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
	if decoded.StatusCode != 500 {
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
	if errMsg.StatusCode != 500 {
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

func TestRegisterMessageWithWalletAddress(t *testing.T) {
	msg := RegisterMessage{
		Type: TypeRegister,
		Hardware: Hardware{
			ChipName: "Apple M3 Max",
			MemoryGB: 64,
		},
		Models: []ModelInfo{
			{ID: "qwen3.5-9b", ModelType: "qwen3", Quantization: "4bit"},
		},
		Backend:       "vllm_mlx",
		WalletAddress: "0x1234567890abcdef1234567890abcdef12345678",
	}

	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded RegisterMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if decoded.WalletAddress != "0x1234567890abcdef1234567890abcdef12345678" {
		t.Errorf("wallet_address = %q", decoded.WalletAddress)
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

func TestRegisterMessageWithoutWalletAddress(t *testing.T) {
	// wallet_address should be omitted from JSON when empty.
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

	// wallet_address should not appear when empty (omitempty)
	var m map[string]any
	json.Unmarshal(data, &m)
	if _, ok := m["wallet_address"]; ok {
		t.Error("wallet_address should be omitted when empty")
	}
}

func TestProviderMessageUnmarshalRegisterWithWallet(t *testing.T) {
	raw := `{"type":"register","hardware":{"chip_name":"M3 Max","memory_gb":64},"models":[{"id":"test"}],"backend":"test","wallet_address":"0xDeadBeef"}`

	var pm ProviderMessage
	if err := json.Unmarshal([]byte(raw), &pm); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	reg := pm.Payload.(*RegisterMessage)
	if reg.WalletAddress != "0xDeadBeef" {
		t.Errorf("wallet_address = %q, want 0xDeadBeef", reg.WalletAddress)
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
