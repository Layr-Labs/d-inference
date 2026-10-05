package registry_test

import (
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheplan"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/forecast"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestPromptWorkForecastRequiresCandidateContract(t *testing.T) {
	for _, source := range []string{protocol.PromptWorkExact, protocol.PromptWorkCalibrated} {
		t.Run(source, func(t *testing.T) {
			now := time.Now()
			f := newCalibrationPolicyFixture(t, now)
			p, pr := f.provider, f.request
			p.BackendCapacity.Slots[0].DeadlineProfile = nil
			pr.EstimatedPromptTokens, pr.FirstContentPromptTokens = 3000, 3500
			pr.PromptWork.Source = source
			if source == protocol.PromptWorkCalibrated {
				pr.PromptWork.CalibrationID = "reviewed-fixture"
				pr.PromptWork.UpperBoundTokens = 5000
			}
			if got := f.evaluate(pr, now).Estimate; got.PromptTokens != 4000 {
				t.Fatalf("matching contract lost count: %+v", got)
			}
			work := pr.PromptWork
			pr.PromptWork = nil
			fallback := f.evaluate(pr, now).Estimate
			pr.PromptWork = work
			// Same weights do not imply the same renderer/normalization revision.
			p.BackendCapacity.Slots[0].PromptWorkIdentity.PromptContractID = strings.Repeat("e", 64)
			if got := f.evaluate(pr, now).Estimate; got.PromptTokens != 3000 || got.ConservativeMs != fallback.ConservativeMs {
				t.Fatalf("different provider contract borrowed count/bound: %+v", got)
			}
			p.BackendCapacity.Slots[0].PromptWorkIdentity = nil
			if got := f.evaluate(pr, now).Estimate; got.PromptTokens != 3000 || got.ConservativeMs != fallback.ConservativeMs {
				t.Fatalf("missing provider contract borrowed count/bound: %+v", got)
			}
			if pr.EstimatedPromptTokens != 3000 || pr.FirstContentPromptTokens != 3500 || pr.PromptWork.PromptTokens != 4000 {
				t.Fatal("candidate fallback mutated request accounting")
			}
		})
	}
}

func TestCalibratedForecastCannotQualifyCoincidentHeuristicWithoutContract(t *testing.T) {
	now := time.Now()
	f := newCalibrationPolicyFixture(t, now)
	p, pr := f.provider, f.request
	work := pr.PromptWork
	pr.PromptWork = nil
	fallback := f.evaluate(pr, now).Estimate
	pr.PromptWork = work
	p.BackendCapacity.Slots[0].PromptWorkIdentity = nil
	if got := f.evaluate(pr, now).Estimate; got.PredictionSource != "" || got.ConservativeMs != fallback.ConservativeMs {
		t.Fatalf("equal heuristic count bypassed provider contract: %+v", got)
	}
}

func TestPromptWorkIdentityLegacyCapabilityAndSlotAuthority(t *testing.T) {
	now := time.Now()
	f := newCalibrationPolicyFixture(t, now)
	p, profile := f.provider, f.profile
	contract := profile.DeadlineCalibration.PromptContractID
	capability := protocol.PrefixCacheV2Capability{ModelID: "model", ModelAggregateHash: profile.ArtifactSHA256, PromptContractID: contract, Enabled: true, Ready: true}
	p.BackendCapacity.Slots[0].PromptWorkIdentity = nil
	p.PrefixCacheV2Models = map[string]protocol.PrefixCacheV2Capability{"model": capability}
	if hash, got := f.promptIdentity("model"); hash != profile.ArtifactSHA256 || got != contract {
		t.Fatal("validated legacy capability lost")
	}
	p.PrefixCacheMemoryModels = map[string]protocol.PrefixCacheV2Capability{"model": capability}
	conflicting := capability
	conflicting.PromptContractID = strings.Repeat("e", 64)
	p.PrefixCacheMemoryModels["model"] = conflicting
	if _, got := f.promptIdentity("model"); got != "" {
		t.Fatal("conflicting legacy contracts accepted")
	}
	identity := &protocol.PromptWorkIdentity{ModelArtifactHash: profile.ArtifactSHA256, PromptContractID: conflicting.PromptContractID}
	p.BackendCapacity.Slots[0].PromptWorkIdentity = identity
	if _, got := f.promptIdentity("model"); got != identity.PromptContractID {
		t.Fatal("legacy cache contract replaced authoritative loaded engine")
	}
	identity.PromptContractID = "malformed"
	if _, got := f.promptIdentity("model"); got != "" {
		t.Fatal("malformed explicit identity fell back to stale cache capability")
	}
	identity.PromptContractID = contract
	identity.ModelArtifactHash = strings.Repeat("f", 64)
	if _, got := f.promptIdentity("model"); got != "" {
		t.Fatal("foreign artifact identity accepted")
	}
}

func TestCachePlanCountAndSavingsRequireCandidateContract(t *testing.T) {
	now := time.Now()
	f := newCalibrationPolicyFixture(t, now)
	p, profile, pr := f.provider, f.profile, f.request
	p.BackendCapacity.Slots[0].DeadlineProfile = nil
	pr.EstimatedPromptTokens, pr.FirstContentPromptTokens, pr.PromptWork = 3000, 3500, nil
	fallback := f.evaluate(pr, now).Estimate
	pr.CachePlan, _ = cacheplan.PlanFromSidecar(f.generation, cacheplan.Identity{
		ModelAggregateHash: profile.ArtifactSHA256, PromptContractID: profile.DeadlineCalibration.PromptContractID, CacheScope: "scope",
	}, promptcontract.Plan{Participating: true, PromptTokenCount: 4000,
		BlockBoundaries: []promptcontract.Boundary{{TokenCount: 1024, ChainHash: strings.Repeat("a", 64)}}})
	forecastWithCache := func() forecast.Estimate {
		return f.evaluate(pr, now, forecast.CacheBenefit{Tokens: 1024, Weight: 1, ExpiresAt: now.Add(time.Minute)}).Estimate
	}
	if got := forecastWithCache(); got.PromptTokens != 4000 || got.CachedTokens != 1024 {
		t.Fatalf("matching cache proof lost count: %+v", got)
	}
	p.BackendCapacity.Slots[0].PromptWorkIdentity.PromptContractID = strings.Repeat("e", 64)
	if got := forecastWithCache(); got.PromptTokens != 3000 || got.CachedTokens != 0 || got.ConservativeMs != fallback.ConservativeMs {
		t.Fatalf("cache plan bypassed contract: %+v", got)
	}
}

func TestPromptWorkIdentityCapacityCloneIsDetached(t *testing.T) {
	identity := &protocol.PromptWorkIdentity{ModelArtifactHash: strings.Repeat("a", 64), PromptContractID: strings.Repeat("b", 64)}
	p := &production.Provider{BackendCapacity: &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{{Model: "model", PromptWorkIdentity: identity}}}}
	copy := p.BackendCapacitySnapshot()
	copy.Slots[0].PromptWorkIdentity.PromptContractID = strings.Repeat("c", 64)
	if identity.PromptContractID != strings.Repeat("b", 64) {
		t.Fatal("snapshot caller mutated accepted contract")
	}
}
