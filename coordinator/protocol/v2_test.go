package protocol

import (
	"encoding/json"
	"testing"
)

func TestProtocolCapabilities_SupportsV2(t *testing.T) {
	if (&ProtocolCapabilities{ProtocolMajor: 2}).SupportsV2() {
		t.Fatal("partial caps must not claim v2")
	}
	caps := &ProtocolCapabilities{
		ProtocolMajor:      2,
		ProtocolMinor:      0,
		PreparedLeases:     true,
		StartAuthorization: true,
		DurableTerminals:   true,
	}
	if !caps.SupportsV2() {
		t.Fatal("expected SupportsV2")
	}
	if (*ProtocolCapabilities)(nil).SupportsV2() {
		t.Fatal("nil must not support v2")
	}
}

func TestProviderMessage_UnmarshalPrepared(t *testing.T) {
	raw := []byte(`{
		"type":"prepared",
		"job_id":"j1",
		"attempt_id":"a1",
		"lease_id":"l1",
		"session_epoch":3,
		"coordinator_epoch":7,
		"dispatch_nonce":"n1",
		"request_digest":"d1",
		"lease_ttl_ms":15000,
		"prompt_tokens":42,
		"max_output_tokens":128,
		"engine_queue_depth":0,
		"prefill_can_begin":true
	}`)
	var pm ProviderMessage
	if err := json.Unmarshal(raw, &pm); err != nil {
		t.Fatal(err)
	}
	if pm.Type != TypePrepared {
		t.Fatalf("type = %q", pm.Type)
	}
	msg, ok := pm.Payload.(*PreparedMessage)
	if !ok {
		t.Fatalf("payload type %T", pm.Payload)
	}
	if msg.JobID != "j1" || msg.LeaseID != "l1" || msg.PromptTokens != 42 {
		t.Fatalf("unexpected prepared: %+v", msg)
	}
}

func TestProviderMessage_UnmarshalTerminal(t *testing.T) {
	raw := []byte(`{
		"type":"provider_terminal",
		"job_id":"j1",
		"attempt_id":"a1",
		"lease_id":"l1",
		"session_epoch":1,
		"coordinator_epoch":1,
		"dispatch_nonce":"n",
		"request_digest":"rd",
		"outcome":"completed",
		"prompt_tokens":10,
		"completion_tokens":5,
		"response_hash":"rh",
		"final_generated_tokens":5,
		"se_signature":"sig",
		"terminal_digest":"td",
		"model":"m"
	}`)
	var pm ProviderMessage
	if err := json.Unmarshal(raw, &pm); err != nil {
		t.Fatal(err)
	}
	term, ok := pm.Payload.(*ProviderTerminalMessage)
	if !ok || term.TerminalDigest != "td" {
		t.Fatalf("payload=%T digest=%v", pm.Payload, term)
	}
}

func TestRegisterMessage_OmitsV2Caps(t *testing.T) {
	msg := RegisterMessage{Type: TypeRegister, Backend: "mlx"}
	b, err := json.Marshal(msg)
	if err != nil {
		t.Fatal(err)
	}
	var raw map[string]any
	if err := json.Unmarshal(b, &raw); err != nil {
		t.Fatal(err)
	}
	if _, ok := raw["protocol_capabilities"]; ok {
		t.Fatal("v1 register must omit protocol_capabilities")
	}
}
