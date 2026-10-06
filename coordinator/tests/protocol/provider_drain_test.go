package protocol_test

import (
	"encoding/json"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestProviderDrainWire(t *testing.T) {
	var message production.ProviderMessage
	if err := production.DecodeProviderMessage([]byte(`{"type":"provider_drain","request_id":"barrier-1"}`), &message); err != nil {
		t.Fatal(err)
	}
	if got := message.Payload.(*production.ProviderDrainMessage); got.RequestID != "barrier-1" {
		t.Fatal(got)
	}
	raw, err := json.Marshal(production.ProviderDrainMessage{Type: production.TypeProviderDrainAck, RequestID: "barrier-1"})
	if err != nil || string(raw) != `{"type":"provider_drain_ack","request_id":"barrier-1"}` {
		t.Fatalf("%s: %v", raw, err)
	}
}
