package registry_test

import (
	"encoding/binary"
	"encoding/hex"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachedemand"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheplan"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func demandPlanValue(boundaries ...protocol.PrefixCacheAnchor) cacheplan.Plan {
	return cacheplan.Plan{ModelAggregateHash: strings.Repeat("a", 64), PromptContractID: strings.Repeat("b", 64),
		CacheScope: "opaque-scope", PromptTokenCount: boundaries[len(boundaries)-1].TokenCount, Boundaries: boundaries}
}

func bindDemandPlan(generation *cacheplan.Generation, plan cacheplan.Plan) cacheplan.Plan {
	sidecar := promptcontract.Plan{Participating: true, PromptTokenCount: uint32(plan.PromptTokenCount)}
	for _, boundary := range plan.Boundaries {
		sidecar.BlockBoundaries = append(sidecar.BlockBoundaries, promptcontract.Boundary{TokenCount: uint32(boundary.TokenCount), ChainHash: boundary.ChainHash})
	}
	bound, accepted := cacheplan.PlanFromSidecar(generation, cacheplan.Identity{
		ModelAggregateHash: plan.ModelAggregateHash, PromptContractID: plan.PromptContractID, CacheScope: plan.CacheScope,
	}, sidecar)
	if accepted {
		bound.RepeatedPrefixTokens = plan.RepeatedPrefixTokens
		plan = bound
	}
	return plan
}

// demandTestPlan is a plan as the sidecar emits it: one boundary per complete
// 256-token block below the prompt length. Blocks that lie wholly inside the
// first sharedTokens tokens carry the shared chain; deeper ones are unique to
// the variant.
func demandTestPlan(generation *cacheplan.Generation, promptTokens, sharedTokens int, variant uint32) cacheplan.Plan {
	block := int(promptcontract.BlockSize)
	count := 0
	if promptTokens > 0 {
		count = (promptTokens - 1) / block
	}
	boundaries := make([]protocol.PrefixCacheAnchor, count)
	var digest [32]byte
	for i := range boundaries {
		tokens := (i + 1) * block
		chain := uint32(0)
		if tokens > sharedTokens {
			chain = variant
		}
		binary.BigEndian.PutUint32(digest[24:], chain)
		binary.BigEndian.PutUint32(digest[28:], uint32(i+1))
		boundaries[i] = protocol.PrefixCacheAnchor{TokenCount: tokens, ChainHash: hex.EncodeToString(digest[:])}
	}
	plan := demandPlanValue(boundaries...)
	plan.PromptTokenCount = promptTokens
	return bindDemandPlan(generation, plan)
}

type demandStrideFixture struct {
	t          *testing.T
	demand     *demandFixture
	generation *cacheplan.Generation
	key        []byte
	now        time.Time
}

func newDemandStrideFixture(t *testing.T) *demandStrideFixture {
	return &demandStrideFixture{
		t: t, demand: newDemandFixture(cachedemand.MaxEntries, cachedemand.SizingTTL),
		generation: &cacheplan.Generation{},
		key:        []byte("0123456789abcdef0123456789abcdef"), now: time.Unix(1_700_000_000, 0),
	}
}

// observe plans a prompt a second after the previous one and returns the
// repeat it reports and whether it produced an affinity key.
func (f *demandStrideFixture) observe(promptTokens, sharedTokens int, variant uint32) (int, bool) {
	f.t.Helper()
	plan := f.plan(promptTokens, sharedTokens, variant)
	return plan.RepeatedPrefixTokens, plan.AffinityKey() != ""
}

func (f *demandStrideFixture) plan(promptTokens, sharedTokens int, variant uint32) cacheplan.Plan {
	f.t.Helper()
	plan := demandTestPlan(f.generation, promptTokens, sharedTokens, variant)
	f.now = f.now.Add(time.Second)
	plan.ObserveRouteDemand(f.generation, f.demand.tracker, f.key, f.now, 0)
	if (plan.RepeatedPrefixTokens > 0) != (plan.AffinityKey() != "") {
		f.t.Fatalf("repeat=%d but affinity key present=%v", plan.RepeatedPrefixTokens, plan.AffinityKey() != "")
	}
	return plan
}

// affinityTokens names the boundary of this plan that its affinity key is
// the digest of, or 0 when it has none.
func (f *demandStrideFixture) affinityTokens(plan cacheplan.Plan) int {
	f.t.Helper()
	if plan.AffinityKey() == "" {
		return 0
	}
	for _, anchor := range plan.Boundaries {
		if plan.BoundaryKey(f.key, anchor) == plan.AffinityKey() {
			return anchor.TokenCount
		}
	}
	f.t.Fatalf("affinity key is not the digest of any boundary of the plan")
	return 0
}

func (f *demandStrideFixture) entries() int {
	return f.demand.index.Len()
}
