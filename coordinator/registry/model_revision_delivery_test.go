package registry

import (
	"errors"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestDesiredModelRevisionRetriesAfterFullWriterQueue(t *testing.T) {
	reg := New(testLogger())
	reg.SetModelCatalog([]CatalogEntry{{ID: "model", Revision: "v2", WeightHash: "new", ServingWeightHashes: []string{"old"}}})
	provider := registerWithWeightHash(reg, "p1", "model", "old")
	provider.ReportedRuntimeCapabilities = []string{"model_revisions_v1"}
	entries := reg.DesiredModelsForProvider(provider.ID)
	if len(entries) != 1 || entries[0].Revision != "v2" {
		t.Fatalf("missing desired revision: %+v", entries)
	}
	calls := 0
	reg.desiredModelsSender = func(_ string, sent []protocol.DesiredModelEntry) error {
		calls++
		if !desiredModelEntriesEqual(sent, entries) {
			t.Fatalf("retry changed desired revision: %+v", sent)
		}
		if calls == 1 {
			return ErrProviderWriterQueueFull
		}
		return nil
	}
	if err := reg.SendDesiredModels(provider.ID, entries); !errors.Is(err, ErrProviderWriterQueueFull) {
		t.Fatalf("queue failure lost: %v", err)
	}
	if err := reg.SendDesiredModels(provider.ID, entries); err != nil {
		t.Fatal(err)
	}
	if calls != 2 {
		t.Fatalf("failed snapshot incorrectly deduplicated: calls=%d", calls)
	}
	if err := reg.SendDesiredModels(provider.ID, entries); err != nil {
		t.Fatal(err)
	}
	if calls != 2 {
		t.Fatalf("delivered snapshot not deduplicated: calls=%d", calls)
	}
}
