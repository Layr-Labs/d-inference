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
