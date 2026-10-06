package registry_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// New native families use the existing explicit-model protocol. Family names
// alone must never bypass advertisement, template, or runtime gates.
func TestNativeToolAdvertisementRouting(t *testing.T) {
	models := []protocol.ModelInfo{
		{ID: "mlx-community/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-4bit", ModelType: "nemotron_h"},
		{ID: "EigenLabs/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-MLX-4bit-mtp", ModelType: "nemotron_h"},
		{ID: "nvidia-nemotron-3.5-lightning", ModelType: "nemotron_h"},
	}
	for _, model := range models {
		t.Run(model.ID, func(t *testing.T) {
			newProvider := func(t *testing.T) (*production.Registry, *production.Provider) {
				t.Helper()
				reg := production.New(testLogger())
				reg.SetModelCatalog([]production.CatalogEntry{{ID: model.ID}})
				provider := makeSchedulerProvider(t, reg, "native-provider", model.ID, 100)
				setProviderVersion(provider, "0.9.0")
				return reg, provider
			}
			check := func(t *testing.T, reg *production.Registry, mode string, want int) {
				t.Helper()
				traits := production.RequestTraits{HasTools: true, ToolChoiceMode: mode,
					RequiresToolConstraint: mode == "required" || mode == "named"}
				if mode == "named" {
					traits.ToolChoiceName = "add"
				}
				if count, _, _ := reg.QuickCapacityCheck(model.ID, 10, 32, traits); count != want {
					t.Fatalf("%s candidates = %d, want %d", mode, count, want)
				}
			}
			t.Run("models_update_enables_and_revokes", func(t *testing.T) {
				reg, provider := newProvider(t)
				check(t, reg, "auto", 1)
				check(t, reg, "required", 0)
				check(t, reg, "named", 0)
				merged, _ := reg.MergeProviderModelsWithCapabilities(provider.ID,
					[]protocol.ModelInfo{model}, production.ToolConstraintProtocolV1, []string{model.ID})
				if len(merged) != 1 || merged[0] != model.ID {
					t.Fatal("qualified model update was not merged")
				}
				check(t, reg, "required", 1)
				check(t, reg, "named", 1)
				reg.MergeProviderModelsWithCapabilities(provider.ID,
					[]protocol.ModelInfo{model}, production.ToolConstraintProtocolV1, nil)
				check(t, reg, "required", 0)
				check(t, reg, "named", 0)
				check(t, reg, "auto", 1)
			})
			for _, test := range []struct {
				name   string
				mutate func(*production.Provider)
			}{
				{"missing_advertisement", func(p *production.Provider) { p.ToolConstraintModels = nil }},
				{"different_model", func(p *production.Provider) {
					p.ToolConstraintModels = map[string]struct{}{"mlx-community/NVIDIA-Nemotron-Nano": {}}
				}},
				{"old_protocol", func(p *production.Provider) { p.ToolConstraintProtocol = 0 }},
				{"unknown_protocol", func(p *production.Provider) { p.ToolConstraintProtocol = 2 }},
				{"broken_template", func(p *production.Provider) { p.Models[0].TemplateRenderOK = boolPtr(false) }},
				{"unverified_runtime", func(p *production.Provider) { p.RuntimeVerified = false }},
			} {
				t.Run(test.name, func(t *testing.T) {
					reg, provider := newProvider(t)
					reg.MergeProviderModelsWithCapabilities(provider.ID,
						[]protocol.ModelInfo{model}, production.ToolConstraintProtocolV1, []string{model.ID})
					check(t, reg, "required", 1)
					provider.Mu().Lock()
					test.mutate(provider)
					provider.Mu().Unlock()
					check(t, reg, "required", 0)
					check(t, reg, "named", 0)
				})
			}
		})
	}
}
