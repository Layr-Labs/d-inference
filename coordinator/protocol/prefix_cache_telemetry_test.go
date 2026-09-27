package protocol

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestPrefixCacheTelemetryOptionalWireCompatibility(t *testing.T) {
	legacy, err := json.Marshal(RegisterMessage{Type: TypeRegister})
	if err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{
		"prefix_cache_statuses",
		"prefix_cache_donation_outcomes",
	} {
		if strings.Contains(string(legacy), field) {
			t.Fatalf("legacy registration emitted %q: %s", field, legacy)
		}
	}

	statuses := []PrefixCacheModelStatus{{
		ModelID: "model", Backend: "contiguous", ReplayStrategy: "frozen_full",
		State: "disabled", Reason: "weight_hash_unavailable",
	}}
	outcomes := []PrefixCacheDonationOutcomeCount{{
		Outcome: "write_queue_full", Count: 3,
	}}
	encoded, err := json.Marshal(HeartbeatMessage{
		Type: TypeHeartbeat, PrefixCacheStatuses: &statuses,
		PrefixCacheDonationOutcomes: &outcomes,
	})
	if err != nil {
		t.Fatal(err)
	}
	var decoded HeartbeatMessage
	if err := json.Unmarshal(encoded, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.PrefixCacheStatuses == nil ||
		len(*decoded.PrefixCacheStatuses) != 1 ||
		(*decoded.PrefixCacheStatuses)[0] != statuses[0] {
		t.Fatalf("status snapshot did not round-trip: %s", encoded)
	}
	if decoded.PrefixCacheDonationOutcomes == nil ||
		len(*decoded.PrefixCacheDonationOutcomes) != 1 ||
		(*decoded.PrefixCacheDonationOutcomes)[0] != outcomes[0] {
		t.Fatalf("donation outcomes did not round-trip: %s", encoded)
	}

	emptyStatuses := []PrefixCacheModelStatus{}
	emptyOutcomes := []PrefixCacheDonationOutcomeCount{}
	empty, err := json.Marshal(HeartbeatMessage{
		Type: TypeHeartbeat, PrefixCacheStatuses: &emptyStatuses,
		PrefixCacheDonationOutcomes: &emptyOutcomes,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(empty), `"prefix_cache_statuses":[]`) ||
		!strings.Contains(string(empty), `"prefix_cache_donation_outcomes":[]`) {
		t.Fatalf("authoritative empty snapshots were omitted: %s", empty)
	}
}

func TestPrefixCacheTelemetryOptionalWire(t *testing.T) {
	legacy := BackendSlotCapacity{Model: "model", State: "idle"}
	data, err := json.Marshal(legacy)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "prefix_cache") {
		t.Fatal("legacy wire shape changed")
	}
	const wire = `{"kind":"complete_checkpoint","generation":7,"sample_seq":2,"sample_age_ms":3,"entries":2,"disk_bytes":4096,"staging_bytes":0,"stages_total":1,"files_written_total":2,"written_bytes_total":8192,"donation_drops_total":0,"corrupt_drops_total":0,"evictions_total":0,"io":{"staging_peak_bytes":1024,"files_read_total":1,"read_bytes_total":4096,"stage_read_bytes_total":4096,"donation_read_bytes_total":0,"stage_us_total":125125,"write_us_total":250500}}`
	var sample PrefixCacheTelemetry
	if err := json.Unmarshal([]byte(wire), &sample); err != nil {
		t.Fatal(err)
	}
	if sample.IO.StageUSTotal != 125125 || sample.SampleAgeMS != 3 {
		t.Fatalf("wire units: %+v", sample)
	}
	data, err = json.Marshal(sample)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != wire {
		t.Fatalf("Swift-mirrored field shape changed: %s", data)
	}
	if sample.TTLExpiredTotal != nil {
		t.Fatal("missing optional measurement invented")
	}
}
