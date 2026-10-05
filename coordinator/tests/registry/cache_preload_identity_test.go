package registry_test

import (
	"reflect"
	"strings"
	"testing"
	"unsafe"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepolicy"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestCachePreloadIdentityExactPolicyWithoutActivation(t *testing.T) {
	artifact := artifactTestIdentity()
	identity := promptcontract.VerifiedPreloadArtifact{CatalogGeneration: 7, ModelID: artifact.ModelID,
		ModelAggregateSHA256: artifact.ModelAggregateSHA256, PromptContractID: artifact.PromptContractID}
	for _, scenario := range []string{"unrestricted", "exact", "empty", "off", "alias", "aggregate", "contract", "generation", "catalog_removed"} {
		t.Run(scenario, func(t *testing.T) {
			r := production.New(testLogger())
			cfg := artifactTestConfig(nil)
			input := identity
			switch scenario {
			case "exact", "contract":
				cfg.AllowedArtifacts = []production.CacheRoutingArtifact{artifact}
			case "empty":
				cfg.AllowedArtifacts = []production.CacheRoutingArtifact{}
			case "off":
				cfg.Mode = production.CacheRoutingOff
			case "alias":
				input.ModelID = "public-alias"
			case "aggregate":
				input.ModelAggregateSHA256 = strings.Repeat("c", 64)
			case "generation":
				input.CatalogGeneration = 0
			}
			if scenario == "contract" {
				input.PromptContractID = strings.Repeat("c", 64)
			}
			if err := r.ConfigureCacheRouting(cfg); err != nil {
				t.Fatal(err)
			}
			r.SetModelCatalog([]production.CatalogEntry{{ID: artifact.ModelID, WeightHash: artifact.ModelAggregateSHA256}})
			if scenario == "catalog_removed" {
				r.SetModelCatalog(nil)
			}
			before := r.CacheRoutingActivationStatus()
			for range 3 {
				got := r.CachePreloadIdentities([]promptcontract.VerifiedPreloadArtifact{input})
				want := scenario == "unrestricted" || scenario == "exact"
				if (len(got) == 1) != want || (want && got[0] != identity) {
					t.Fatalf("exact identity projection = %+v, admitted=%t", got, want)
				}
			}
			if !reflect.DeepEqual(before, r.CacheRoutingActivationStatus()) {
				t.Fatal("read-only selection consumed sampling/QPS or plan accounting")
			}
		})
	}
}

func TestCachePreloadIdentityDetachesAndBoundsInput(t *testing.T) {
	r := production.New(testLogger())
	if err := r.ConfigureCacheRouting(artifactTestConfig(nil)); err != nil {
		t.Fatal(err)
	}
	backing := strings.Repeat("a", 1<<20)
	model, hash := backing[100:110], backing[200:264]
	r.SetModelCatalog([]production.CatalogEntry{{ID: model, WeightHash: hash}})
	input := promptcontract.VerifiedPreloadArtifact{CatalogGeneration: 1, ModelID: model,
		ModelAggregateSHA256: hash, PromptContractID: hash}
	got := r.CachePreloadIdentities([]promptcontract.VerifiedPreloadArtifact{input})
	if len(got) != 1 || got[0] != input {
		t.Fatal("valid detachment fixture refused")
	}
	if unsafe.StringData(got[0].ModelID) == unsafe.StringData(model) ||
		unsafe.StringData(got[0].ModelAggregateSHA256) == unsafe.StringData(hash) ||
		unsafe.StringData(got[0].PromptContractID) == unsafe.StringData(hash) {
		t.Fatal("projection retained a caller's large backing allocation")
	}
	if r.CachePreloadIdentities(make([]promptcontract.VerifiedPreloadArtifact, cachepolicy.MaxArtifacts+1)) != nil {
		t.Fatal("over-bound projection was accepted")
	}
}
