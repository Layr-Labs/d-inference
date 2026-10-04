package registry_test

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/deadline"
)

func TestDeadlineCatalogFailsClosedForMalformedInvalidAndDuplicateRecords(t *testing.T) {
	_, _, profile, _ := calibratedCandidateFixture(t, time.Now())
	valid, err := json.Marshal(profile)
	if err != nil {
		t.Fatal(err)
	}
	if loaded := deadline.DecodeProfiles("[" + string(valid) + "]"); len(loaded) != 1 || loaded[0].ID != profile.ID {
		t.Fatal("valid reviewed record did not load")
	}
	invalid := *profile
	invalid.QualificationReportSHA256 = "not-evidence"
	bad, err := json.Marshal(invalid)
	if err != nil {
		t.Fatal(err)
	}
	for _, raw := range []string{"{", "{}", "null", "[null]", "[" + string(valid) + ",null]",
		"[" + string(valid) + "," + string(bad) + "]", "[" + string(valid) + "," + string(valid) + "]"} {
		if len(deadline.DecodeProfiles(raw)) != 0 {
			t.Fatalf("invalid catalog partially activated: %s", raw)
		}
	}
}

func TestCompiledDeadlineCatalogContainsOnlyValidUniqueProfiles(t *testing.T) {
	var profiles []*deadline.Profile
	if err := json.Unmarshal([]byte(deadline.CompiledProfilesJSON), &profiles); err != nil || profiles == nil {
		t.Fatalf("compiled catalog must be a JSON array: %v", err)
	}
	loaded := deadline.DecodeProfiles(deadline.CompiledProfilesJSON)
	if len(loaded) != len(profiles) {
		t.Fatal("compiled catalog contains an invalid or duplicate record")
	}
}
