package registry_test

// The coordinator and the provider each encode an approval entry into the
// canonical policy bytes a member compares and hashes. The provider's suite
// (ClusterPairApprovalTests.canonicalBytesHashToTheCoordinatorsOwnDigests)
// pins these same three entries to these same digests, so neither encoder can
// change alone. The provider also reads the entry more strictly than Go's JSON
// and time packages would; the catalog parser refuses whatever it refuses.

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"math"
	"strings"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// goldenApproval is the entry the provider's suite builds for the same id.
func goldenApproval(id string, generation uint64, schedule int, notAfter string, chips ...string) map[string]any {
	digest := func(label string) string {
		sum := sha256.Sum256([]byte("cluster-pair-golden-" + label))
		return hex.EncodeToString(sum[:])
	}
	return map[string]any{
		"id": id, "model": "fixture/pair-model", "generation": generation,
		"plan_sha256": digest("plan"), "artifact_sha256": digest("artifact"),
		"native_runtime_sha256": digest("native"), "metallib_sha256": digest("metallib"),
		"resource_library_sha256": digest("resources"), "capability_sha256": digest("capability"),
		"resource_policy_sha256": digest("resource-policy"), "profile_sha256": digest("profile"),
		"schedule": schedule, "maximum_transport_frame": 131_112, "maximum_plaintext": 131_072,
		"maximum_records": 1024, "maximum_cumulative_plaintext": 16_777_216,
		"allowed_chips": chips, "not_after": notAfter,
	}
}

func goldenCatalog(t *testing.T, approvals ...map[string]any) []byte {
	t.Helper()
	data, err := json.Marshal(map[string]any{"schema": production.NativeRuntimeCatalogSchema, "approvals": approvals})
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func TestCanonicalApprovalDigestsMatchTheProviderEncoder(t *testing.T) {
	golden := []struct {
		approval map[string]any
		digest   string
	}{
		{goldenApproval("golden-utc", 3, 1, "2027-01-02T03:04:05Z", "Apple M4 Max"),
			"eab6c4aafcc2e4312eb2ec25e1fa0442e84f83e435b7d0b8ce80e3604c15ed34"},
		{goldenApproval("golden-fraction-offset", math.MaxUint64, 2, "2027-01-02T03:04:05.123456789+02:00", "Apple M4 Max", "Apple M4 Pro"),
			"16ae9511c76ccfd769d6058b27dcbc6d0266c067f872812169bb4384f043f48e"},
		{goldenApproval("golden-leap-day", 1, 1, "2028-02-29T23:59:59.5-07:30", "Apple M5"),
			"b26dfdd464cf7d5b02f3bec4714bb02e62cb76a1e0dfbb85f07c0ececfed5ed5"},
	}
	approvals := make([]map[string]any, len(golden))
	for i := range golden {
		approvals[i] = golden[i].approval
	}
	catalog, err := production.ParseNativeRuntimeCatalog(goldenCatalog(t, approvals...))
	if err != nil {
		t.Fatalf("golden catalog refused: %v", err)
	}
	for _, g := range golden {
		id := g.approval["id"].(string)
		if got, _ := catalog.PolicySHA256(id); got != g.digest {
			t.Errorf("%s: policy_sha256 = %s, the provider's encoder pins %s", id, got, g.digest)
		}
	}
}

func TestCatalogFileRefusesWhatTheProviderRefuses(t *testing.T) {
	with := func(field string, value any) []byte {
		approval := goldenApproval("strict", 3, 1, "2027-01-02T03:04:05Z", "Apple M4 Max")
		approval[field] = value
		return goldenCatalog(t, approval)
	}
	accepted := func(data []byte) bool {
		catalog, err := production.ParseNativeRuntimeCatalog(data)
		return err == nil && catalog != nil
	}

	// not_after: exactly the instants the provider's parser accepts and refuses.
	for _, instant := range []string{"1970-01-01T00:00:01Z", "2027-01-02T03:04:05Z", "2027-01-02T03:04:05.5Z",
		"2027-01-02T03:04:05.123456789+02:00", "2028-02-29T23:59:59-07:30", "2027-01-02T03:04:05+23:59"} {
		if !accepted(with("not_after", instant)) {
			t.Errorf("not_after %q refused; the provider accepts it", instant)
		}
	}
	for _, instant := range []string{"", "2027-01-02", "2027-01-02 03:04:05Z", "2027-01-02t03:04:05Z", "2027-01-02T03:04:05",
		"2027-01-02T03:04:05z", "2027-02-29T00:00:00Z", "2027-13-01T00:00:00Z", "2027-00-10T00:00:00Z",
		"2027-01-02T24:00:00Z", "2027-01-02T03:60:00Z", "2027-01-02T03:04:60Z", "2027-01-02T03:04:05.Z",
		"2027-01-02T03:04:05.1234567890Z", "2027-01-02T03:04:05+0200", "2027-01-02T03:04:05+24:00",
		"2027-01-02T03:04:05+02:60", "2027-01-02T03:04:05Z ", "1970-01-01T00:00:00Z", "1970-01-01T00:00:00.5Z",
		"1969-12-31T23:59:59Z", "9999-01-01T00:00:00Z", "２０２７-01-02T03:04:05Z",
		// Forms Go's own RFC 3339 parser takes and the provider does not.
		"2027-01-02T3:04:05Z", "2027-01-02T03:04:05,5Z"} {
		if accepted(with("not_after", instant)) {
			t.Errorf("not_after %q accepted; the provider refuses it", instant)
		}
	}

	// allowed_chips are compared with hardware.chip_name byte for byte, and
	// the two sides must agree on their order and uniqueness.
	for name, chips := range map[string][]string{
		"non-ASCII chip": {"Apple M4 Max", "Äpple M5"},
		"control byte":   {"Apple M4\tMax"},
		"empty chip":     {""},
		"repeated chip":  {"Apple M4 Max", "Apple M4 Max"},
		"unsorted chips": {"Apple M4 Pro", "Apple M4 Max"},
	} {
		if accepted(with("allowed_chips", chips)) {
			t.Errorf("allowed_chips with a %s accepted", name)
		}
	}

	// Member names are matched exactly and once.
	valid := string(goldenCatalog(t, goldenApproval("strict", 3, 1, "2027-01-02T03:04:05Z", "Apple M4 Max")))
	if !accepted([]byte(valid)) {
		t.Fatal("fixture catalog refused")
	}
	for name, document := range map[string]string{
		"capitalized entry field": strings.Replace(valid, `"model"`, `"Model"`, 1),
		"capitalized top field":   strings.Replace(valid, `"schema"`, `"Schema"`, 1),
		"repeated entry field":    strings.Replace(valid, `"generation":3`, `"generation":4,"generation":3`, 1),
		"repeated top field":      strings.Replace(valid, `{"approvals"`, `{"schema":"other","approvals"`, 1),
	} {
		if document == valid {
			t.Fatalf("%s: fixture replacement did not apply", name)
		}
		if accepted([]byte(document)) {
			t.Errorf("%s accepted", name)
		}
	}
}
