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
