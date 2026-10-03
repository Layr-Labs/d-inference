package catalog

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// TestOpenRouterModelsEndpoint verifies the dedicated /v1/models/openrouter feed
// emits the pure OpenRouter schema: text modalities, slug, staging-based
// is_ready, populated features, and no Darkbloom metadata block.
func TestConcreteModelEligibleForOpenRouterFeed(t *testing.T) {
	const modelID = "model"
	catalog := map[string]store.SupportedModel{
		modelID: {ID: modelID, ModelType: "text", Active: true},
	}
	if !concreteModelEligibleForOpenRouterFeed(modelID, catalog, nil) {
		t.Fatal("text catalog model without providers should be feed-eligible")
	}
	if concreteModelEligibleForOpenRouterFeed(modelID, catalog, map[string]string{modelID: "embedding"}) {
		t.Fatal("provider-reported non-text model should not be feed-eligible")
	}
	if concreteModelEligibleForOpenRouterFeed("missing", catalog, nil) {
		t.Fatal("missing catalog model should not be feed-eligible")
	}
}
