package registry

import (
	"fmt"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
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

func TestRevisionUpdatesForLineageWhoseDesiredBuildIsIneligible(t *testing.T) {
	for _, lineage := range []string{"previous", "retired"} {
		for _, eligible := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/desired-eligible=%t", lineage, eligible), func(t *testing.T) {
				reg := New(testLogger())
				reg.SetModelCatalog([]CatalogEntry{
					{ID: "old", Revision: "old-v2", WeightHash: "old-new-hash"},
					{ID: "replacement", Revision: "new-v1", WeightHash: "new-hash", RequiredProviderCapabilities: []string{ProviderCapabilityAppleM5}},
				})
				target := AliasTarget{Desired: "replacement"}
				if lineage == "previous" {
					target.Previous = "old"
				} else {
					target.Retired = []string{"old"}
				}
				reg.SetModelAliases(map[string]AliasTarget{"public-model": target})
				provider := registerWithWeightHash(reg, "p1", "old", "old-new-hash")
				provider.ReportedRuntimeCapabilities = []string{"model_revisions_v1"}
				if eligible {
					provider.RuntimeCapabilities = []string{ProviderCapabilityAppleM5}
				}
				entries := reg.DesiredModelsForProvider("p1")
				if len(entries) != 1 {
					t.Fatalf("unexpected desired entries: %+v", entries)
				}
				wantID, wantHash := "old", "old-new-hash"
				if eligible {
					wantID, wantHash = "replacement", "new-hash"
				}
				if entries[0].DesiredBuild != wantID || entries[0].AggregateSHA256 != wantHash {
					t.Fatalf("wrong revision target: %+v", entries)
				}
			})
		}
	}
}
