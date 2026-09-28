package protocol

import (
	"encoding/json"
	"os"
	"testing"
)

func TestPerformanceCapacityWireSymmetryAndLegacyOmission(t *testing.T) {
	data, err := os.ReadFile("testdata/performance_capacity_wire_fixture.json")
	if err != nil {
		t.Fatal(err)
	}
	var capacity BackendCapacity
	if err := json.Unmarshal(data, &capacity); err != nil {
		t.Fatal(err)
	}
	if capacity.WholeMacServiceUsed == nil || *capacity.WholeMacServiceUsed != .5 || len(capacity.Slots) != 1 {
		t.Fatal("shared service allowance missing")
	}
	profile := capacity.Slots[0].PerformanceProfile
	if profile == nil || profile.ID != "test-reviewed-profile" || profile.ContextTokens != 32768 || profile.RuntimeRevision != "cbv2-first-content-v1" {
		t.Fatalf("profile identity lost: %+v", profile)
	}
	encoded, err := json.Marshal(capacity)
	if err != nil {
		t.Fatal(err)
	}
	var roundTrip BackendCapacity
	if err := json.Unmarshal(encoded, &roundTrip); err != nil {
		t.Fatal(err)
	}
	if *roundTrip.Slots[0].PerformanceProfile != *profile {
		t.Fatal("profile changed during encoding")
	}
	legacy, err := json.Marshal(BackendCapacity{Slots: []BackendSlotCapacity{{Model: "old"}}})
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
	var slots []map[string]json.RawMessage
	if err := json.Unmarshal(raw["slots"], &slots); err != nil {
		t.Fatal(err)
	}
	if _, ok := slots[0]["performance_profile"]; ok {
		t.Fatal("legacy profile omission changed")
	}
}
