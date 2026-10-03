package provider_test

import (
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestChallengeAcceptsRetainedModelRevision(t *testing.T) {
	catalog := []registry.CatalogEntry{
		{ID: "model-gemma", Revision: "new", WeightHash: strings.Repeat("d", 64), ServingWeightHashes: []string{gemmaHash}},
		{ID: "model-gptoss", WeightHash: gptOSSHash},
	}
	status := challengeExchangeWithCatalog(t, catalog, map[string]string{"model-gemma": gemmaHash, "model-gptoss": gptOSSHash}, gemmaHash)
	if status == registry.StatusUntrusted {
		t.Fatal("an approved old revision was untrusted during convergence")
	}
	status = challengeExchangeWithCatalog(t, catalog, map[string]string{"model-gptoss": gemmaHash}, gemmaHash)
	if status != registry.StatusUntrusted {
		t.Fatal("a hash approved for a different model was accepted")
	}
}
