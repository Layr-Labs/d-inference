package protocol

import (
	"encoding/json"
	"os"
	"reflect"
	"testing"
)

func TestProcessMemoryTelemetryWireAndDetachedCopy(t *testing.T) {
	wire, err := os.ReadFile("testdata/process_memory_wire.json")
	if err != nil {
		t.Fatal(err)
	}
	var sample CapacityTelemetry
	if err := json.Unmarshal(wire, &sample); err != nil {
		t.Fatal(err)
	}
	m := sample.ProcessMemory
	if m == nil || m.ChargedBytes-m.MaterializedBytes != m.UnmaterializedBytes || m.ClosingOwnerCount != 1 || *m.SystemAvailableBytes != 700 {
		t.Fatalf("sample: %+v", m)
	}
	encoded, err := json.Marshal(sample)
	if err != nil {
		t.Fatal(err)
	}
	var before, after map[string]any
	_ = json.Unmarshal(wire, &before)
	_ = json.Unmarshal(encoded, &after)
	if !reflect.DeepEqual(before, after) {
		t.Fatalf("round trip: %s", encoded)
	}
	copied := sample.Clone()
	copied.ProcessMemory.ChargedBytes = 0
	*copied.ProcessMemory.SystemAvailableBytes = 0
	if m.ChargedBytes != 250 || *m.SystemAvailableBytes != 700 {
		t.Fatal("snapshot aliases source")
	}
	var legacy CapacityTelemetry
	if err := json.Unmarshal([]byte(`{"low_power_mode":false}`), &legacy); err != nil {
		t.Fatal(err)
	}
	encoded, _ = json.Marshal(legacy)
	if string(encoded) != `{"low_power_mode":false}` || legacy.ProcessMemory != nil {
		t.Fatalf("legacy: %s", encoded)
	}
	sample.ProcessMemory.SystemAvailableBytes = nil
	encoded, _ = json.Marshal(sample)
	_ = json.Unmarshal(encoded, &after)
	if _, ok := after["process_memory"].(map[string]any)["system_available_bytes"]; ok {
		t.Fatal("unknown OS availability became zero")
	}
}
