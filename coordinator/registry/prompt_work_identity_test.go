package registry

import (
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestPromptWorkForecastRequiresCandidateContract(t *testing.T) {
	for _, source := range []string{protocol.PromptWorkExact, protocol.PromptWorkCalibrated} {
		t.Run(source, func(t *testing.T) {
			now := time.Now()
			r, p, profile, pr := calibratedCandidateFixture(t, now)
			delete(reviewedDeadlinePerformanceProfiles, profile.ID)
			pr.EstimatedPromptTokens, pr.FirstContentPromptTokens = 3000, 3500
			pr.PromptWork.Source = source
			if source == protocol.PromptWorkCalibrated {
				pr.PromptWork.CalibrationID = "reviewed-fixture"
				pr.PromptWork.UpperBoundTokens = 5000
			}
			if got := calibratedForecast(r, p, pr, now).firstContent; got.PromptTokens != 4000 {
				t.Fatalf("matching contract lost count: %+v", got)
			}
			work := pr.PromptWork
			pr.PromptWork = nil
			fallback := calibratedForecast(r, p, pr, now).firstContent
			pr.PromptWork = work
			// Same weights do not imply the same renderer/normalization revision.
			p.BackendCapacity.Slots[0].PromptWorkIdentity.PromptContractID = strings.Repeat("e", 64)
			if got := calibratedForecast(r, p, pr, now).firstContent; got.PromptTokens != 3000 || got.ConservativeMs != fallback.ConservativeMs {
				t.Fatalf("different provider contract borrowed count/bound: %+v", got)
			}
			p.BackendCapacity.Slots[0].PromptWorkIdentity = nil
			if got := calibratedForecast(r, p, pr, now).firstContent; got.PromptTokens != 3000 || got.ConservativeMs != fallback.ConservativeMs {
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
	r, p, _, pr := calibratedCandidateFixture(t, now)
	work := pr.PromptWork
	pr.PromptWork = nil
	fallback := calibratedForecast(r, p, pr, now).firstContent
	pr.PromptWork = work
	p.BackendCapacity.Slots[0].PromptWorkIdentity = nil
	if got := calibratedForecast(r, p, pr, now).firstContent; got.PredictionSource != "" || got.ConservativeMs != fallback.ConservativeMs {
		t.Fatalf("equal heuristic count bypassed provider contract: %+v", got)
	}
}

func TestPromptWorkIdentityLegacyCapabilityAndSlotAuthority(t *testing.T) {
	now := time.Now()
	_, p, profile, _ := calibratedCandidateFixture(t, now)
	contract := profile.DeadlineCalibration.PromptContractID
	capability := protocol.PrefixCacheV2Capability{ModelID: "model", ModelAggregateHash: profile.ArtifactSHA256, PromptContractID: contract, Enabled: true, Ready: true}
	p.BackendCapacity.Slots[0].PromptWorkIdentity = nil
	p.PrefixCacheV2Models = map[string]protocol.PrefixCacheV2Capability{"model": capability}
	if hash, got := providerPromptWorkIdentityLocked(p, "model"); hash != profile.ArtifactSHA256 || got != contract {
		t.Fatal("validated legacy capability lost")
	}
	p.PrefixCacheMemoryModels = map[string]protocol.PrefixCacheV2Capability{"model": capability}
	conflicting := capability
	conflicting.PromptContractID = strings.Repeat("e", 64)
	p.PrefixCacheMemoryModels["model"] = conflicting
	if _, got := providerPromptWorkIdentityLocked(p, "model"); got != "" {
		t.Fatal("conflicting legacy contracts accepted")
	}
	identity := &protocol.PromptWorkIdentity{ModelArtifactHash: profile.ArtifactSHA256, PromptContractID: conflicting.PromptContractID}
	p.BackendCapacity.Slots[0].PromptWorkIdentity = identity
	if _, got := providerPromptWorkIdentityLocked(p, "model"); got != identity.PromptContractID {
		t.Fatal("legacy cache contract replaced authoritative loaded engine")
	}
	identity.PromptContractID = "malformed"
	if _, got := providerPromptWorkIdentityLocked(p, "model"); got != "" {
		t.Fatal("malformed explicit identity fell back to stale cache capability")
	}
	identity.PromptContractID = contract
	identity.ModelArtifactHash = strings.Repeat("f", 64)
	if _, got := providerPromptWorkIdentityLocked(p, "model"); got != "" {
		t.Fatal("foreign artifact identity accepted")
	}
}

func TestCachePlanCountAndSavingsRequireCandidateContract(t *testing.T) {
	now := time.Now()
	r, p, profile, pr := calibratedCandidateFixture(t, now)
	delete(reviewedDeadlinePerformanceProfiles, profile.ID)
	pr.EstimatedPromptTokens, pr.FirstContentPromptTokens, pr.PromptWork = 3000, 3500, nil
	fallback := calibratedForecast(r, p, pr, now).firstContent
	generation := &cacheRoutingGeneration{}
	r.cacheRouting = &cacheRoutingTracker{generation: generation}
	pr.CachePlan = CachePlan{generation: generation, ModelAggregateHash: profile.ArtifactSHA256, PromptContractID: profile.DeadlineCalibration.PromptContractID, CacheScope: "scope", PromptTokenCount: 4000, Boundaries: []protocol.PrefixCacheAnchor{{TokenCount: 1024}}}
	forecast := func() FirstContentEstimate {
		c := &routingCandidate{}
		r.fillRoutingSnapshotPLocked(&c.snapshot, p, "model", now)
		c.firstContentCachedTokens, c.firstContentCacheWeight, c.firstContentCacheExpiresAt = 1024, 1, now.Add(time.Minute)
		r.estimateFirstContent(c, pr, now)
		return c.firstContent
	}
	if got := forecast(); got.PromptTokens != 4000 || got.CachedTokens != 1024 {
		t.Fatalf("matching cache proof lost count: %+v", got)
	}
	p.BackendCapacity.Slots[0].PromptWorkIdentity.PromptContractID = strings.Repeat("e", 64)
	if got := forecast(); got.PromptTokens != 3000 || got.CachedTokens != 0 || got.ConservativeMs != fallback.ConservativeMs {
		t.Fatalf("cache plan bypassed contract: %+v", got)
	}
}

func TestPromptWorkIdentityCapacityCloneIsDetached(t *testing.T) {
	identity := &protocol.PromptWorkIdentity{ModelArtifactHash: strings.Repeat("a", 64), PromptContractID: strings.Repeat("b", 64)}
	p := &Provider{BackendCapacity: &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{{Model: "model", PromptWorkIdentity: identity}}}}
	copy := p.BackendCapacitySnapshot()
	copy.Slots[0].PromptWorkIdentity.PromptContractID = strings.Repeat("c", 64)
	if identity.PromptContractID != strings.Repeat("b", 64) {
		t.Fatal("snapshot caller mutated accepted contract")
	}
}
