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

// TestPrefixCacheInitFailureDetailWireSymmetry pins the "init_failure" JSON
// key to the Swift PrefixCacheInitFailureDetail CodingKey. The detail is a
// pure additive field: Swift omits it when nil (encodeIfPresent), Go mirrors
// with omitempty, and a status without the key decodes to "" — so pre-0.7.14
// providers and coordinators stay wire-compatible in both directions.
func TestPrefixCacheInitFailureDetailWireSymmetry(t *testing.T) {
	plain := []PrefixCacheModelStatus{{
		ModelID: "model", Backend: "contiguous", ReplayStrategy: "direct",
		State: "disabled", Reason: "weight_hash_unavailable",
	}}
	encodedPlain, err := json.Marshal(HeartbeatMessage{
		Type: TypeHeartbeat, PrefixCacheStatuses: &plain,
	})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encodedPlain), "init_failure") {
		t.Fatalf("empty detail leaked onto the wire: %s", encodedPlain)
	}
	var decodedPlain HeartbeatMessage
	if err := json.Unmarshal(encodedPlain, &decodedPlain); err != nil {
		t.Fatal(err)
	}
	if (*decodedPlain.PrefixCacheStatuses)[0].InitFailure != "" {
		t.Fatalf("omitted detail decoded non-empty: %s", encodedPlain)
	}

	detailed := []PrefixCacheModelStatus{{
		ModelID: "model", Backend: "contiguous", ReplayStrategy: "direct",
		State: "error", Reason: "cache_init_failed",
		InitFailure: "key_unavailable",
	}}
	encoded, err := json.Marshal(HeartbeatMessage{
		Type: TypeHeartbeat, PrefixCacheStatuses: &detailed,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(encoded), `"init_failure":"key_unavailable"`) {
		t.Fatalf("detail key drifted from the Swift mirror: %s", encoded)
	}
	var decoded HeartbeatMessage
	if err := json.Unmarshal(encoded, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.PrefixCacheStatuses == nil ||
		len(*decoded.PrefixCacheStatuses) != 1 ||
		(*decoded.PrefixCacheStatuses)[0] != detailed[0] {
		t.Fatalf("detailed status did not round-trip: %s", encoded)
	}
}
