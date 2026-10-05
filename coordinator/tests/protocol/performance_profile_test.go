package protocol_test

import (
	"encoding/json"
	"os"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestPerformanceCapacityWireSymmetryAndLegacyOmission(t *testing.T) {
	data, err := os.ReadFile("testdata/performance_capacity_wire_fixture.json")
	if err != nil {
		t.Fatal(err)
	}
	var capacity production.BackendCapacity
	if err := json.Unmarshal(data, &capacity); err != nil {
		t.Fatal(err)
	}
	if capacity.WholeMacServiceUsed == nil || *capacity.WholeMacServiceUsed != .5 || len(capacity.Slots) != 1 {
		t.Fatal("shared service allowance missing")
	}
	if len(capacity.WholeMacServiceReservations) != 2 ||
		capacity.WholeMacServiceReservations[0].ID != "6e1f61d1-e22c-4d24-a3a7-d347772a48cb" ||
		capacity.WholeMacServiceReservations[0].UsedFraction != .0625 {
		t.Fatal("service reservation correlation missing")
	}
	profile := capacity.Slots[0].PerformanceProfile
	if profile == nil || profile.ID != "test-reviewed-profile" || profile.ContextTokens != 32768 || profile.RuntimeRevision != "cbv2-first-content-v1" {
		t.Fatalf("profile identity lost: %+v", profile)
	}
	encoded, err := json.Marshal(capacity)
	if err != nil {
		t.Fatal(err)
	}
	var roundTrip production.BackendCapacity
	if err := json.Unmarshal(encoded, &roundTrip); err != nil {
		t.Fatal(err)
	}
	if *roundTrip.Slots[0].PerformanceProfile != *profile {
		t.Fatal("profile changed during encoding")
	}
	if len(roundTrip.WholeMacServiceReservations) != 2 || roundTrip.WholeMacServiceReservations[1] != capacity.WholeMacServiceReservations[1] {
		t.Fatal("service reservation changed during encoding")
	}
	legacy, err := json.Marshal(production.BackendCapacity{Slots: []production.BackendSlotCapacity{{Model: "old"}}})
	if err != nil {
		t.Fatal(err)
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(legacy, &raw); err != nil {
		t.Fatal(err)
	}
	if _, ok := raw["whole_mac_service_used"]; ok {
		t.Fatal("legacy allowance omission changed")
	}
	if _, ok := raw["whole_mac_service_reservations"]; ok {
		t.Fatal("legacy reservation correlation omission changed")
	}
	var slots []map[string]json.RawMessage
	if err := json.Unmarshal(raw["slots"], &slots); err != nil {
		t.Fatal(err)
	}
	if _, ok := slots[0]["performance_profile"]; ok {
		t.Fatal("legacy profile omission changed")
	}
}
