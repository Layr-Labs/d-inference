package protocol

import (
	"encoding/json"
	"os"
	"reflect"
	"strings"
	"testing"
)

func TestPagedFootprintTelemetryCanonicalWire(t *testing.T) {
	data, err := os.ReadFile("testdata/paged_footprint_wire.json")
	if err != nil {
		t.Fatal(err)
	}
	var sample PagedStorageTelemetry
	if err := json.Unmarshal(data, &sample); err != nil {
		t.Fatal(err)
	}
	if sample.AllocatorPaddingBytes == nil || sample.LastAllocationAllowanceBytes == nil {
		t.Fatal("missing observed gauges")
	}
	if sample.CommittedBytes != sample.ReservedPageBytes+sample.PoisonBytes+sample.SlackBytes+*sample.AllocatorPaddingBytes {
		t.Fatal("padding was counted as reusable slack")
	}
	encoded, err := json.Marshal(sample)
	if err != nil {
		t.Fatal(err)
	}
	var a, b any
	if err := json.Unmarshal(data, &a); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(encoded, &b); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(a, b) {
		t.Fatalf("wire changed: %s", encoded)
	}
	clone := sample.Clone()
	*clone.AllocatorPaddingBytes = 0
	*clone.LastAllocationAllowanceBytes = 0
	if *sample.AllocatorPaddingBytes != 50 || *sample.LastAllocationAllowanceBytes != 77 {
		t.Fatal("clone shares new gauge pointers")
	}
	sample.AllocatorPaddingBytes, sample.LastAllocationAllowanceBytes = nil, nil
	encoded, err = json.Marshal(sample)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), "allocator_padding_bytes") || strings.Contains(string(encoded), "last_allocation_allowance_bytes") {
		t.Fatal("absent gauges became zero")
	}
}
