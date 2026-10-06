package registry_test

import (
	"context"
	"encoding/json"
	"errors"
	"slices"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestDesiredModelRevisionRetriesAfterFullWriterQueue(t *testing.T) {
	var entries []protocol.DesiredModelEntry
	calls := 0
	reg := production.NewWithDependencies(testLogger(), production.Dependencies{
		ModelCommands: func(_ string, _ production.ModelCommandTransport) production.ModelCommandTransport {
			return modelCommandWriteFunc(func(_ context.Context, data []byte) error {
				var msg protocol.DesiredModelsMessage
				if err := json.Unmarshal(data, &msg); err != nil {
					t.Fatal(err)
				}
				calls++
				if !slices.Equal(msg.Models, entries) {
					t.Fatalf("retry changed desired revision: %+v", msg.Models)
				}
				if calls == 1 {
					return production.ErrProviderWriterQueueFull
				}
				return nil
			})
		},
	})
	reg.SetModelCatalog([]production.CatalogEntry{{ID: "model", Revision: "v2", WeightHash: "new", ServingWeightHashes: []string{"old"}}})
	provider := registerWithWeightHash(reg, "p1", "model", "old")
	provider.ReportedRuntimeCapabilities = []string{"model_revisions_v1"}
	entries = reg.DesiredModelsForProvider(provider.ID)
	if len(entries) != 1 || entries[0].Revision != "v2" {
		t.Fatalf("missing desired revision: %+v", entries)
	}
	if err := reg.SendDesiredModels(provider.ID, entries); !errors.Is(err, production.ErrProviderWriterQueueFull) {
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
