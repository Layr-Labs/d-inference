package protocol

import (
	"encoding/json"
	"testing"
)

func TestServiceReservationReleasedWireRoundTrip(t *testing.T) {
	const id = "6e1f61d1-e22c-4d24-a3a7-d347772a48cb"
	var frame ProviderMessage
	if err := json.Unmarshal([]byte(`{"type":"service_reservation_released","service_reservation_id":"`+id+`"}`), &frame); err != nil {
		t.Fatal(err)
	}
	message, ok := frame.Payload.(*ServiceReservationReleasedMessage)
	if !ok || message.ServiceReservationID != id {
		t.Fatalf("release = %#v", frame.Payload)
	}
	encoded, err := json.Marshal(message)
	if err != nil {
		t.Fatal(err)
	}
	var wire map[string]any
	if err := json.Unmarshal(encoded, &wire); err != nil {
		t.Fatal(err)
	}
	if len(wire) != 2 || wire["type"] != TypeServiceReservationReleased || wire["service_reservation_id"] != id {
		t.Fatalf("wire = %v", wire)
	}
}

func TestServiceRetirementCapabilityOptionalWire(t *testing.T) {
	for _, version := range []int{0, 1} {
		encoded, err := json.Marshal(BackendCapacity{WholeMacServiceRetirementProtocol: version})
		if err != nil {
			t.Fatal(err)
		}
		var wire map[string]any
		if err := json.Unmarshal(encoded, &wire); err != nil {
			t.Fatal(err)
		}
		_, present := wire["whole_mac_service_retirement_protocol"]
		if present != (version == 1) {
			t.Fatalf("capability omission = %v", wire)
		}
		var decoded BackendCapacity
		if err := json.Unmarshal(encoded, &decoded); err != nil || decoded.WholeMacServiceRetirementProtocol != version {
			t.Fatalf("decode = %+v/%v", decoded, err)
		}
	}
}
