package memory

import (
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestMemoryPruneCapsProfilerSlices(t *testing.T) {
	s := NewMemory(store.Config{})
	const maxEntries = 10
	now := time.Now()
	for i := 0; i < maxEntries*3; i++ {
		s.requestProfiles = append(s.requestProfiles, store.RequestProfileRecord{RequestID: fmt.Sprintf("r%d", i), CreatedAt: now})
		s.requestProfileKeys[requestProfileKey(fmt.Sprintf("r%d", i), 0)] = struct{}{}
		s.fleetSnapshots = append(s.fleetSnapshots, store.FleetSnapshotRow{ProviderID: fmt.Sprintf("p%d", i), SampledAt: now})
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
	if err := s.RecordRequestProfiles([]*store.RequestProfileRecord{{RequestID: "r0"}, {RequestID: "r29"}}); err != nil {
		t.Fatal(err)
	}
	if got := len(s.requestProfiles); got != maxEntries+1 {
		t.Fatalf("after re-insert len = %d, want %d", got, maxEntries+1)
	}
}
