package protocol

import (
	"encoding/json"
	"testing"
)

func TestProviderDrainWire(t *testing.T) {
	var message ProviderMessage
	if err := DecodeProviderMessage([]byte(`{"type":"provider_drain","request_id":"barrier-1"}`), &message); err != nil {
		t.Fatal(err)
	}
	if got := message.Payload.(*ProviderDrainMessage); got.RequestID != "barrier-1" {
		t.Fatal(got)
	}
	raw, err := json.Marshal(ProviderDrainMessage{Type: TypeProviderDrainAck, RequestID: "barrier-1"})
	if err != nil || string(raw) != `{"type":"provider_drain_ack","request_id":"barrier-1"}` {
		t.Fatalf("%s: %v", raw, err)
	}
}
