package accounts_test

import (
	"io"
	"log/slog"
	"testing"

	fleetview "github.com/eigeninference/d-inference/coordinator/internal/api/accounts/fleetview"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestMyProviderKeepsShadowInventoryOutOfServingModels(t *testing.T) {
	r := registry.New(slog.New(slog.NewTextHandler(io.Discard, nil)))
	selected := protocol.ModelInfo{ID: "selected", WeightHash: "selected-hash"}
	cached := protocol.ModelInfo{ID: "cached", WeightHash: "cached-hash"}
	p := r.Register("shadow", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{selected}, AutopilotInventory: []protocol.ModelInfo{selected, cached},
		ModelAutopilot: &protocol.ModelAutopilotState{Protocol: protocol.ModelAutopilotProtocol,
			Enabled: true, CachedOnly: true, Revision: "consent", SelectedModels: []string{selected.ID, cached.ID}},
	})
	got := fleetview.Build(nil, p)
	if len(got.Models) != 1 || got.Models[0].ID != selected.ID {
		t.Fatalf("My Macs exposes observational inventory as serving models: %+v", got.Models)
	}
	legacy := r.Register("legacy", nil, &protocol.RegisterMessage{Models: []protocol.ModelInfo{selected, cached}})
	if len(fleetview.Build(nil, legacy).Models) != 2 {
		t.Fatal("legacy explicit serving set changed")
	}
}
