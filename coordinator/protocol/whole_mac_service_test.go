package protocol

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestServiceReservationRequestWireAndLegacyOmission(t *testing.T) {
	const id = "6e1f61d1-e22c-4d24-a3a7-d347772a48cb"
	message := InferenceRequestMessage{Type: TypeInferenceRequest, RequestID: "request", ServiceReservationID: id}
	encoded, err := json.Marshal(message)
	if err != nil {
		t.Fatal(err)
	}
	var decoded InferenceRequestMessage
	if err := json.Unmarshal(encoded, &decoded); err != nil || decoded.ServiceReservationID != id {
		t.Fatalf("reservation identity round trip failed: %v %+v", err, decoded)
	}
	message.ServiceReservationID = ""
	encoded, err = json.Marshal(message)
	if err != nil || strings.Contains(string(encoded), "service_reservation_id") {
		t.Fatalf("legacy reservation omission changed: %v %s", err, encoded)
	}
}
