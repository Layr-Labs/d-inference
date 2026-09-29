package registry

import (
	"encoding/json"
	"testing"
	"time"
)

func TestDeadlineCatalogFailsClosedForMalformedInvalidAndDuplicateRecords(t *testing.T) {
	_, _, profile, _ := calibratedCandidateFixture(t, time.Now())
	valid, err := json.Marshal(profile)
	if err != nil {
		t.Fatal(err)
	}
	if loaded := decodeDeadlineProfileCatalog("[" + string(valid) + "]"); len(loaded) != 1 || loaded[profile.ID].ID != profile.ID {
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
		if len(decodeDeadlineProfileCatalog(raw)) != 0 {
			t.Fatalf("invalid catalog partially activated: %s", raw)
		}
	}
}

func TestCompiledDeadlineCatalogContainsOnlyValidUniqueProfiles(t *testing.T) {
	var profiles []*deadlinePerformanceProfile
	if err := json.Unmarshal([]byte(reviewedDeadlineProfilesJSON), &profiles); err != nil || profiles == nil {
		t.Fatalf("compiled catalog must be a JSON array: %v", err)
	}
	loaded := decodeDeadlineProfileCatalog(reviewedDeadlineProfilesJSON)
	if len(loaded) != len(profiles) {
		t.Fatal("compiled catalog contains an invalid or duplicate record")
	}
}
