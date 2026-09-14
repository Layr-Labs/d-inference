package memory

import (
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/eigeninference/d-inference/coordinator/store/internal/routerecord"
)

func TestMemoryPruneCapsProfilerSlices(t *testing.T) {
	s := New(contracts.Config{})
	const maxEntries = 10
	now := time.Now()
	for i := 0; i < maxEntries*3; i++ {
		s.requestProfiles = append(s.requestProfiles, contracts.RequestProfileRecord{RequestID: fmt.Sprintf("r%d", i), CreatedAt: now})
		s.requestProfileKeys[requestProfileKey(fmt.Sprintf("r%d", i), 0)] = struct{}{}
		s.fleetSnapshots = append(s.fleetSnapshots, contracts.FleetSnapshotRow{ProviderID: fmt.Sprintf("p%d", i), SampledAt: now})
	}
	s.Prune(maxEntries)
	if got := len(s.requestProfiles); got != maxEntries {
		t.Fatalf("requestProfiles len = %d, want %d", got, maxEntries)
	}
	if got := len(s.fleetSnapshots); got != maxEntries {
		t.Fatalf("fleetSnapshots len = %d, want %d", got, maxEntries)
	}
	if s.requestProfiles[0].RequestID != "r20" || s.fleetSnapshots[0].ProviderID != "p20" {
		t.Fatalf("Prune kept the wrong end: %s %s", s.requestProfiles[0].RequestID, s.fleetSnapshots[0].ProviderID)
	}
	if got := len(s.requestProfileKeys); got != maxEntries {
		t.Fatalf("requestProfileKeys len = %d after Prune, want %d", got, maxEntries)
	}
	// A pruned key is writable again; a kept key is still rejected.
	if err := s.RecordRequestProfiles([]*contracts.RequestProfileRecord{{RequestID: "r0"}, {RequestID: "r29"}}); err != nil {
		t.Fatal(err)
	}
	if got := len(s.requestProfiles); got != maxEntries+1 {
		t.Fatalf("after re-insert len = %d, want %d", got, maxEntries+1)
	}
}

// TestRequestProfilesSinceFilteredAppliesPredicatesBeforeTheCap pins the admin
// browse/export contract: a matching row older than the newest
// maxTelemetryReadRows rows is still returned when a filter is given.
func TestRequestProfilesSinceFilteredAppliesPredicatesBeforeTheCap(t *testing.T) {
	s := New(contracts.Config{})
	base := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	old := &contracts.RequestProfileRecord{CoordRequestID: "coord-old", RequestID: "req-old", ProviderID: "prov-old", Model: "m", PublicModel: "alias", FinalStatus: "error", CreatedAt: base}
	if err := s.RecordRequestProfiles([]*contracts.RequestProfileRecord{old}); err != nil {
		t.Fatal(err)
	}
	batch := make([]*contracts.RequestProfileRecord, 0, 512)
	for i := 0; i < routerecord.MaxTelemetryReadRows; i++ {
		batch = append(batch, &contracts.RequestProfileRecord{CoordRequestID: "coord-new", RequestID: "req-new", Attempt: i, ProviderID: "prov-new", Model: "m", FinalStatus: "success", CreatedAt: base.Add(time.Duration(i+1) * time.Millisecond)})
		if len(batch) == 512 {
			if err := s.RecordRequestProfiles(batch); err != nil {
				t.Fatal(err)
			}
			batch = batch[:0]
		}
	}
	if len(batch) > 0 {
		if err := s.RecordRequestProfiles(batch); err != nil {
			t.Fatal(err)
		}
	}
	if got := s.RequestProfilesSince(time.Time{}); len(got) != routerecord.MaxTelemetryReadRows || got[len(got)-1].ProviderID == "prov-old" {
		t.Fatalf("unfiltered read must be capped to the newest rows (got %d, last=%s)", len(got), got[len(got)-1].ProviderID)
	}
	for name, f := range map[string]contracts.RequestProfileFilter{
		"provider":      {ProviderID: "prov-old"},
		"model alias":   {Model: "alias"},
		"final_status":  {FinalStatus: "error"},
		"coord request": {CoordRequestID: "coord-old"},
	} {
		got := s.RequestProfilesSinceFiltered(time.Time{}, f)
		if len(got) != 1 || got[0].RequestID != "req-old" {
			t.Fatalf("filter %s returned %d rows (want the one old row): %+v", name, len(got), got)
		}
	}
	if got := s.RequestProfilesSinceFiltered(time.Time{}, contracts.RequestProfileFilter{Model: "m", FinalStatus: "success"}); len(got) != routerecord.MaxTelemetryReadRows {
		t.Fatalf("combined filter = %d rows, want the capped %d", len(got), routerecord.MaxTelemetryReadRows)
	}
}
