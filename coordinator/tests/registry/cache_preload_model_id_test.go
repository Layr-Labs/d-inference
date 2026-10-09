package registry_test

import (
	"slices"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/preload"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestCachePreloadLongModelIDDoesNotPoisonCatalog(t *testing.T) {
	short := artifactTestIdentity()
	long := short
	long.ModelID = strings.Repeat("m", 513)
	long.PromptContractID = strings.Repeat("d", 64)
	verified := []preload.VerifiedPreloadArtifact{
		{CatalogGeneration: 1, ModelID: short.ModelID, ModelAggregateSHA256: short.ModelAggregateSHA256, PromptContractID: short.PromptContractID},
		{CatalogGeneration: 1, ModelID: long.ModelID, ModelAggregateSHA256: long.ModelAggregateSHA256, PromptContractID: long.PromptContractID},
	}
	for _, restricted := range []bool{false, true} {
		r := production.New(testLogger())
		cfg := artifactTestConfig(nil)
		if restricted {
			cfg.AllowedArtifacts = []production.CacheRoutingArtifact{short}
		}
		if err := r.ConfigureCacheRouting(cfg); err != nil {
			t.Fatal(err)
		}
		r.SetModelCatalog([]production.CatalogEntry{
			{ID: short.ModelID, WeightHash: short.ModelAggregateSHA256},
			{ID: long.ModelID, WeightHash: long.ModelAggregateSHA256},
		})
		admissible := r.CachePreloadIdentities(verified)
		want := verified
		if restricted {
			want = verified[:1]
		}
		if !slices.Equal(admissible, want) {
			t.Errorf("long-ID projection (restricted=%t): got %d identities, want %d", restricted, len(admissible), len(want))
		}
		input := preload.PreloadSelectionInput{CatalogGeneration: 1, ChildGeneration: 1, Capacity: 1, Verified: verified, Admissible: admissible}
		policy := preload.NewPreloadActiveSet()
		if _, err := policy.Reconcile(0, input); err != nil {
			t.Errorf("unrelated contract poisoned by 513-byte model ID (restricted=%t): %v", restricted, err)
			continue
		}
		if !policy.NoteDemand(0, verified[0]) {
			t.Fatal("short allowlisted model lost demand eligibility")
		}
		key, err := policy.Reconcile(0, input)
		if err != nil || !slices.Equal(key.Desired, []string{short.PromptContractID}) {
			t.Fatalf("short model not selected: %+v, %v", key, err)
		}
		if policy.NoteDemand(0, verified[1]) == restricted {
			t.Fatal("long model eligibility did not match allowlist")
		}
	}
	r := production.New(testLogger())
	if err := r.ConfigureCacheRouting(artifactTestConfig([]production.CacheRoutingArtifact{long})); err == nil {
		t.Fatal("preload fix broadened explicit artifact allowlist validation")
	}
}

func TestCachePreloadModelIDByteLimit(t *testing.T) {
	r := production.New(testLogger())
	if err := r.ConfigureCacheRouting(artifactTestConfig(nil)); err != nil {
		t.Fatal(err)
	}
	artifact := artifactTestIdentity()
	model := strings.Repeat("m", (64<<20)+1)
	r.SetModelCatalog([]production.CatalogEntry{{ID: model, WeightHash: artifact.ModelAggregateSHA256}})
	verified := []preload.VerifiedPreloadArtifact{{CatalogGeneration: 1, ModelID: model,
		ModelAggregateSHA256: artifact.ModelAggregateSHA256, PromptContractID: artifact.PromptContractID}}
	if len(r.CachePreloadIdentities(verified)) != 0 {
		t.Fatal("model ID exceeding registration's body ceiling retained")
	}
}
