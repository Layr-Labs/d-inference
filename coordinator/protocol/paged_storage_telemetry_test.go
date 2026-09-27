package protocol

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestPagedStorageTelemetryOptionalWire(t *testing.T) {
	legacy, err := json.Marshal(BackendSlotCapacity{Model: "model", State: "idle"})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(legacy), "paged_storage") {
		t.Fatal("legacy slot gained telemetry")
	}
	const wire = `{"model":"model","state":"idle","paged_storage":{"kind":"segmented","generation":7,"sample_seq":2,"sample_age_ms":3,"grant_bytes":1000,"committed_bytes":1100,"reserved_page_bytes":800,"live_page_bytes":400,"poison_bytes":100,"slack_bytes":200,"over_grant_bytes":100,"segment_count":2,"address_pages":16,"nominal_kv_bytes":900,"physical_floor_overhead_bytes":200,"allocation_failures_total":0,"admission_refusals_total":1,"grant_refusals_total":2,"grant_epoch_retries_total":3}}`
	var slot BackendSlotCapacity
	if err := json.Unmarshal([]byte(wire), &slot); err != nil {
		t.Fatal(err)
	}
	s := slot.PagedStorage
	if s == nil || s.CommittedBytes != 1100 || s.NominalKVBytes == nil || *s.NominalKVBytes != 900 || s.GrantEpochRetriesTotal == nil || *s.GrantEpochRetriesTotal != 3 {
		t.Fatalf("bad snapshot: %+v", s)
	}
	clone := s.Clone()
	*clone.NominalKVBytes = 1
	*clone.AllocationFailuresTotal = 9
	if *s.NominalKVBytes != 900 || *s.AllocationFailuresTotal != 0 {
		t.Fatal("clone retained caller pointers")
	}
	s.NominalKVBytes, s.AllocationFailuresTotal = nil, nil
	data, err := json.Marshal(s)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "nominal_kv_bytes") || strings.Contains(string(data), "allocation_failures_total") {
		t.Fatal("uninstrumented fields became zeros")
	}
}
