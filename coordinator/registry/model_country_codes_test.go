package registry

import (
	"slices"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// ModelCountryCodes must only count routing-eligible providers (same gates as
// ListModels), so a country whose providers can't actually serve the model is
// not advertised in the OpenRouter datacenters field.
func TestModelCountryCodesOnlyEligibleProviders(t *testing.T) {
	reg := New(testLogger())
	const model = "mlx-community/Qwen3.5-9B-Instruct-4bit"

	// Eligible provider in the US (trusted + private-ready).
	good := reg.Register("good", nil, testRegisterMessage())
	testMakeTextRoutable(good)
	good.mu.Lock()
	good.Location = &store.ProviderLocation{CountryCode: "us"}
	good.mu.Unlock()

	// Online but NOT routing-eligible (never made text-routable → no verified
	// SIP, so not private-ready) provider in DE, serving the same model.
	bad := reg.Register("bad", nil, testRegisterMessage())
	bad.mu.Lock()
	bad.Location = &store.ProviderLocation{CountryCode: "DE"}
	bad.mu.Unlock()

	got := reg.ModelCountryCodes(model)
	if len(got) != 1 || got[0] != "US" {
		t.Fatalf("country codes = %v, want [US] (the DE provider is not routing-eligible)", got)
	}
}

func TestModelCountryCodesExcludePrivateOnlyProviders(t *testing.T) {
	reg := New(testLogger())
	const model = "mlx-community/Qwen3.5-9B-Instruct-4bit"
	reg.SetModelCatalog([]CatalogEntry{{ID: model}})

	private := reg.Register("private", nil, testRegisterMessage())
	testMakeTextRoutable(private)
	private.mu.Lock()
	private.PrivateOnly = true
	private.Location = &store.ProviderLocation{CountryCode: "CA"}
	private.mu.Unlock()

	if got := reg.ModelCountryCodes(model); got != nil {
		t.Fatalf("private-only provider contributed country codes %v", got)
	}
	if publicModelListed(reg, model) {
		t.Fatal("private-only provider's model appeared in the public model list")
	}
}

func TestModelCountryCodesApplyPublicCatalogPolicy(t *testing.T) {
	const model = "catalog-model"
	tests := []struct {
		name         string
		catalog      []CatalogEntry
		reportedHash string
		wantCodes    []string
		wantListed   bool
	}{
		{
			name:         "valid public provider",
			catalog:      []CatalogEntry{{ID: model, WeightHash: "expected"}},
			reportedHash: "expected",
			wantCodes:    []string{"US"},
			wantListed:   true,
		},
		{
			name:         "off-catalog model",
			catalog:      []CatalogEntry{{ID: "different-model"}},
			reportedHash: "reported",
		},
		{
			name:         "catalog hash mismatch",
			catalog:      []CatalogEntry{{ID: model, WeightHash: "expected"}},
			reportedHash: "tampered",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			reg := New(testLogger())
			reg.SetModelCatalog(tc.catalog)
			msg := testRegisterMessage()
			msg.Models = []protocol.ModelInfo{{
				ID:           model,
				ModelType:    "chat",
				Quantization: "4bit",
				WeightHash:   tc.reportedHash,
			}}
			provider := reg.Register("provider", nil, msg)
			testMakeTextRoutable(provider)
			provider.mu.Lock()
			provider.Location = &store.ProviderLocation{CountryCode: " us "}
			provider.mu.Unlock()

			if got := reg.ModelCountryCodes(model); !slices.Equal(got, tc.wantCodes) {
				t.Fatalf("country codes = %v, want %v", got, tc.wantCodes)
			}
			if got := publicModelListed(reg, model); got != tc.wantListed {
				t.Fatalf("ListModels contains model = %t, want %t", got, tc.wantListed)
			}
		})
	}
}

func publicModelListed(reg *Registry, modelID string) bool {
	for _, model := range reg.ListModels() {
		if model.ID == modelID {
			return true
		}
	}
	return false
}
