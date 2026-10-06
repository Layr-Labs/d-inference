package registry_test

import (
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachedemand"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheplan"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestCacheDemandScopeBuildAndGenerationIsolation(t *testing.T) {
	plan := demandPlanValue(protocol.PrefixCacheAnchor{TokenCount: int(promptcontract.BlockSize), ChainHash: strings.Repeat("c", 64)})
	key := []byte("private-route-key")
	for _, change := range []string{"scope", "build", "contract", "generation"} {
		t.Run(change, func(t *testing.T) {
			demand := newDemandFixture(cachedemand.MaxEntries, time.Minute)
			generation := &cacheplan.Generation{}
			first := bindDemandPlan(generation, plan)
			first.ObserveRouteDemand(generation, demand.tracker, key, time.Now(), 0)
			other := first
			other.RepeatedPrefixTokens = 0
			switch change {
			case "scope":
				other.CacheScope += "other"
			case "build":
				other.ModelAggregateHash = "d" + other.ModelAggregateHash[1:]
			case "contract":
				other.PromptContractID = "d" + other.PromptContractID[1:]
			case "generation":
				other = bindDemandPlan(&cacheplan.Generation{}, other)
			}
			other.ObserveRouteDemand(generation, demand.tracker, key, time.Now(), 0)
			if other.RepeatedPrefixTokens != 0 || other.AffinityKey() != "" {
				t.Fatal("demand crossed identity boundary")
			}
			again := first
			again.ObserveRouteDemand(generation, demand.tracker, key, time.Now(), 0)
			if again.RepeatedPrefixTokens != 256 || again.AffinityKey() == "" {
				t.Fatal("same identity did not match")
			}
		})
	}
}
