package memory_test

import (
	"fmt"
	"testing"
	"time"

	memoryhistory "github.com/eigeninference/d-inference/coordinator/internal/store/memoryhistory"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestMemoryPruneCapsProfilerSlices(t *testing.T) {
	s := memoryhistory.New()
	const maxEntries = 10
	now := time.Now()
	for i := 0; i < maxEntries*3; i++ {
		if err := s.RecordRequestProfiles([]*store.RequestProfileRecord{{RequestID: fmt.Sprintf("r%d", i), CreatedAt: now}}); err != nil {
			t.Fatal(err)
		}
		s.FleetSnapshots = append(s.FleetSnapshots, store.FleetSnapshotRow{ProviderID: fmt.Sprintf("p%d", i), SampledAt: now})
	}
	s.Prune(maxEntries)
	if got := len(s.RequestProfiles); got != maxEntries {
		t.Fatalf("RequestProfiles len = %d, want %d", got, maxEntries)
	}
	if got := len(s.FleetSnapshots); got != maxEntries {
		t.Fatalf("FleetSnapshots len = %d, want %d", got, maxEntries)
	}
	if s.RequestProfiles[0].RequestID != "r20" || s.FleetSnapshots[0].ProviderID != "p20" {
		t.Fatalf("Prune kept the wrong end: %s %s", s.RequestProfiles[0].RequestID, s.FleetSnapshots[0].ProviderID)
	}
	if got := len(s.RequestProfileKeys); got != maxEntries {
		t.Fatalf("RequestProfileKeys len = %d after Prune, want %d", got, maxEntries)
	}
	// A pruned key is writable again; a kept key is still rejected.
	if err := s.RecordRequestProfiles([]*store.RequestProfileRecord{{RequestID: "r0"}, {RequestID: "r29"}}); err != nil {
		t.Fatal(err)
	}
	if got := len(s.RequestProfiles); got != maxEntries+1 {
		t.Fatalf("after re-insert len = %d, want %d", got, maxEntries+1)
	}
}
