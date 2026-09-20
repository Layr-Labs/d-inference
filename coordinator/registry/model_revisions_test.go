package registry

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"testing"
)

func TestRevisionApprovalAndConvergence(t *testing.T) {
	reg := New(testLogger())
	reg.SetModelCatalog([]CatalogEntry{{ID: "model", Revision: "v2", WeightHash: "new", ServingWeightHashes: []string{"old"}}})
	provider := registerWithWeightHash(reg, "p1", "model", "old")
	provider.ReportedRuntimeCapabilities = []string{"model_revisions_v1"}
	if !reg.CatalogAcceptsWeightHash("model", "old") || !reg.CatalogAcceptsWeightHash("model", "new") {
		t.Fatal("approved revisions rejected")
	}
	for _, hash := range []string{"", "unpublished", "other-model-hash"} {
		if reg.CatalogAcceptsWeightHash("model", hash) {
			t.Fatalf("unapproved hash accepted: %q", hash)
		}
	}
	desired := reg.DesiredModelsForProvider("p1")
	if len(desired) != 1 || desired[0].Revision != "v2" || desired[0].AggregateSHA256 != "new" {
		t.Fatalf("same-ID update not sent: %+v", desired)
	}
	merged, _ := reg.MergeProviderModels("p1", []protocol.ModelInfo{{ID: "model", WeightHash: "old"}})
	if len(merged) != 1 {
		t.Fatal("rollback advertisement rejected")
	}
	merged, _ = reg.MergeProviderModels("p1", []protocol.ModelInfo{{ID: "model", WeightHash: "evil"}})
	if len(merged) != 0 {
		t.Fatal("unapproved advertisement accepted")
	}
	reg.SetModelCatalog([]CatalogEntry{{ID: "model", Revision: "v3", WeightHash: "newest", ServingWeightHashes: []string{"old", "new"}}})
	latest := reg.DesiredModelsForProvider("p1")
	if desiredModelEntriesEqual(desired, latest) {
		t.Fatal("new hash/version hidden by desired-state deduplication")
	}
	if !reg.CatalogAcceptsWeightHash("model", "old") {
		t.Fatal("rapid promotion revoked a still-serving older revision")
	}
}
