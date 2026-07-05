package protocol

import (
	"encoding/json"
	"testing"
)

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
