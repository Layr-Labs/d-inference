package registry_test

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	cacheactivation "github.com/eigeninference/d-inference/coordinator/internal/registry/cacheactivation"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepolicy"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func artifactTestIdentity() production.CacheRoutingArtifact {
	return production.CacheRoutingArtifact{
		ModelID: "model", ModelAggregateSHA256: strings.Repeat("a", 64),
		PromptContractID: strings.Repeat("b", 64),
	}
}

func artifactTestConfig(artifacts []production.CacheRoutingArtifact) production.CacheRoutingConfig {
	return production.CacheRoutingConfig{
		Mode: production.CacheRoutingOn, AllowedArtifacts: artifacts, ActivationPct: 100, MaxPlanQPS: 1,
		TTL: time.Minute, MaxHolders: 4, MaxDiscountMs: f64(1000), MaxCostFraction: f64(.35),
		MasterKey: base64.RawURLEncoding.EncodeToString([]byte("0123456789abcdef0123456789abcdef")),
	}
}

func TestCacheArtifactAllowlistConfiguration(t *testing.T) {
	valid, err := json.Marshal([]production.CacheRoutingArtifact{artifactTestIdentity()})
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name string
		raw  string
		ok   bool
	}{
		{"empty list", "[]", true},
		{"exact tuple", string(valid), true},
		{"whitespace around array", " \n" + string(valid) + "\n", true},
		{"empty setting", "", false},
		{"null", "null", false},
		{"object", "{}", false},
		{"truncated", "[", false},
		{"missing fields", `[{"model_id":"model"}]`, false},
		{"unknown field", strings.Replace(string(valid), "model_id", "model_alias", 1), false},
		{"duplicate field", strings.Replace(string(valid), `"model_id":`, `"model_id":"other","model_id":`, 1), false},
		{"nonstring field", strings.Replace(string(valid), `"model_id":"model"`, `"model_id":12`, 1), false},
		{"null field", strings.Replace(string(valid), `"model_id":"model"`, `"model_id":null`, 1), false},
		{"null artifact", "[null]", false},
		{"duplicate tuple", string(valid[:len(valid)-1]) + "," + string(valid[1:]), false},
		{"bad hash", strings.Replace(string(valid), strings.Repeat("a", 64), "not-a-hash", 1), false},
		{"uppercase hash", strings.Replace(string(valid), strings.Repeat("a", 64), strings.Repeat("A", 64), 1), false},
		{"wildcard model", strings.Replace(string(valid), `"model"`, `"*"`, 1), false},
		{"padded model", strings.Replace(string(valid), `"model"`, `" model"`, 1), false},
		{"trailing array", string(valid) + " []", false},
		{"trailing junk", string(valid) + " !", false},
		{"byte limit", strings.Repeat(" ", cachepolicy.MaxArtifactJSONBytes+1), false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv(cachepolicy.ArtifactAllowlistEnv, tc.raw)
			cfg := production.ReadConfig().CacheRouting
			if err := cfg.Check(); (err == nil) != tc.ok {
				t.Fatalf("Check error=%v, want valid=%t", err, tc.ok)
			}
			if tc.ok && cfg.AllowedArtifacts == nil {
				t.Fatal("configured list lost presence")
			}
		})
	}

	t.Setenv(cachepolicy.ArtifactAllowlistEnv, "") // Restore the original environment at cleanup.
	if err := os.Unsetenv(cachepolicy.ArtifactAllowlistEnv); err != nil {
		t.Fatal(err)
	}
	if cfg := production.ReadConfig().CacheRouting; cfg.AllowedArtifacts != nil || cfg.Check() != nil {
		t.Fatal("absent list must retain unrestricted defaults")
	}
	tooMany := make([]production.CacheRoutingArtifact, cachepolicy.MaxArtifacts+1)
	if err := artifactTestConfig(tooMany).Check(); err == nil {
		t.Fatal("oversized programmatic list accepted")
	}
}

func TestCacheArtifactAllowlistRejectsBeforeActivationAndSidecar(t *testing.T) {
	identity := artifactTestIdentity()
	for _, tc := range []struct {
		name      string
		artifacts []production.CacheRoutingArtifact
		change    func(*production.CachePlanInput)
		mode      string
		outcome   cacheactivation.CachePlanOutcome
	}{
		{name: "absent remains unrestricted", outcome: cacheactivation.CachePlanSidecarError},
		{name: "empty denies", artifacts: []production.CacheRoutingArtifact{}, outcome: cacheactivation.CachePlanIneligible},
		{name: "exact allowed", artifacts: []production.CacheRoutingArtifact{identity}, outcome: cacheactivation.CachePlanSidecarError},
		{name: "different model", artifacts: []production.CacheRoutingArtifact{identity}, change: func(p *production.CachePlanInput) { p.Model = "Model" }, outcome: cacheactivation.CachePlanIneligible},
		{name: "revised weights", artifacts: []production.CacheRoutingArtifact{identity}, change: func(p *production.CachePlanInput) { p.ModelAggregateSHA256 = strings.Repeat("c", 64) }, outcome: cacheactivation.CachePlanIneligible},
		{name: "revised template", artifacts: []production.CacheRoutingArtifact{identity}, change: func(p *production.CachePlanInput) { p.PromptContractID = strings.Repeat("c", 64) }, outcome: cacheactivation.CachePlanIneligible},
		{name: "off takes precedence", artifacts: []production.CacheRoutingArtifact{}, mode: production.CacheRoutingOff, outcome: cacheactivation.CachePlanOff},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := production.New(testLogger())
			cfg := artifactTestConfig(tc.artifacts)
			if tc.mode != "" {
				cfg.Mode = tc.mode
			}
			if err := r.ConfigureCacheRouting(cfg); err != nil {
				t.Fatal(err)
			}
			input := production.CachePlanInput{
				Account: "account", Model: identity.ModelID, ModelAggregateSHA256: identity.ModelAggregateSHA256,
				PromptContractID: identity.PromptContractID, Body: []byte(`{"messages":[{"role":"user","content":"hello"}]}`),
			}
			if tc.change != nil {
				tc.change(&input)
			}
			// Updated identities exist in the catalog; only rollout membership rejects them.
			r.SetModelCatalog([]production.CatalogEntry{{ID: input.Model, WeightHash: input.ModelAggregateSHA256}})
			client := promptcontract.NewClient(promptcontract.ClientConfig{
				SocketPath: filepath.Join(t.TempDir(), "absent.sock"), RequestTimeout: 20 * time.Millisecond,
			})
			t.Cleanup(client.Close)
			result := r.PlanCacheRouteWithResult(context.Background(), client, input)
			if result.Outcome != tc.outcome || result.Plan.Present() {
				t.Fatalf("plan=%+v, want %s", result, tc.outcome)
			}
			status := r.CacheRoutingActivationStatus()
			if tc.outcome == cacheactivation.CachePlanSidecarError {
				if !result.SidecarCalled || status.Evaluated != 1 || status.Admitted != 1 {
					t.Fatalf("allowed request skipped planner: %+v %+v", result, status)
				}
			} else if result.SidecarCalled || status.Evaluated != 0 || status.Admitted != 0 {
				t.Fatalf("excluded request consumed cohort/QPS or called sidecar: %+v %+v", result, status)
			}
		})
	}
}

func TestCacheArtifactConfigurationOwnsMembershipAndClearsEvidence(t *testing.T) {
	r, provider, f := newPreparationFixture(t)
	capability := exactTestCapability("11111111-1111-1111-1111-111111111111")
	artifacts := []production.CacheRoutingArtifact{artifactTestIdentity()}
	if err := r.ConfigureCacheRouting(artifactTestConfig(artifacts)); err != nil {
		t.Fatal(err)
	}
	artifacts[0].ModelID = "mutated caller"
	snapshot := r.CacheRoutingConfigSnapshot()
	if snapshot.AllowedArtifacts[0] != artifactTestIdentity() {
		t.Fatal("registry retained mutable configuration backing")
	}
	snapshot.AllowedArtifacts[0].ModelID = "mutated snapshot"
	if r.CacheRoutingConfigSnapshot().AllowedArtifacts[0] != artifactTestIdentity() {
		t.Fatal("snapshot exposes mutable membership")
	}
	anchor := cacheFlowAnchor(1, "1")
	pr := &production.PendingRequest{RequestID: "old-attempt", Model: "model"}
	if err := r.PreparePrefixCacheV2Attempt(pr, provider, f.bind(cacheFlowPlan(anchor))); err != nil {
		t.Fatal(err)
	}
	if !r.ApplyPrefixCacheLookupV2(provider.ID, &protocol.PrefixCacheLookupV2Message{
		RequestID: pr.RequestID, CacheReceiptNonce: pr.CacheAttemptSnapshot().MetadataMessage().CacheReceiptNonce, ModelID: "model",
		ModelAggregateHash: capability.ModelAggregateHash, PromptContractID: capability.PromptContractID,
		CacheEpoch: capability.CacheEpoch, CacheSeq: 1, PromptAnchor: anchor,
		Outcome: "miss_absent", Tier: "ssd", StageMs: 1,
	}) {
		t.Fatal("could not confirm donor input before durable ready")
	}
	ready := &protocol.PrefixCacheReadyV2Message{
		RequestID: pr.RequestID, CacheReceiptNonce: pr.CacheAttemptSnapshot().MetadataMessage().CacheReceiptNonce, ModelID: "model",
		ModelAggregateHash: capability.ModelAggregateHash, PromptContractID: capability.PromptContractID,
		CacheEpoch: capability.CacheEpoch, CacheSeq: 2, Outcome: "ready", Tier: "ssd",
		ReadyAnchors: []protocol.PrefixCacheAnchor{anchor}, ExpectedPrefillTokensSaved: anchor.TokenCount, StageMs: 1,
	}
	if !r.ApplyPrefixCacheReadyV2(provider.ID, ready) {
		t.Fatal("could not seed holder for replacement regression")
	}
	if holders, attempts := r.CacheRoutingStateCounts(); holders == 0 || attempts == 0 {
		t.Fatalf("missing seeded evidence: holders=%d attempts=%d", holders, attempts)
	}
	if err := r.ConfigureCacheRouting(artifactTestConfig([]production.CacheRoutingArtifact{})); err != nil {
		t.Fatal(err)
	}
	if holders, attempts := r.CacheRoutingStateCounts(); holders != 0 || attempts != 0 {
		t.Fatalf("evidence survived list replacement: holders=%d attempts=%d", holders, attempts)
	}
	if r.ApplyPrefixCacheReadyV2(provider.ID, ready) {
		t.Fatal("old receipt replayed into replacement configuration")
	}
	if snapshot := r.CacheRoutingConfigSnapshot(); snapshot.AllowedArtifacts == nil || len(snapshot.AllowedArtifacts) != 0 {
		t.Fatal("empty list became unrestricted in snapshot")
	}
	if err := r.ConfigureCacheRouting(artifactTestConfig(nil)); err != nil {
		t.Fatal(err)
	}
	if r.CacheRoutingConfigSnapshot().AllowedArtifacts != nil {
		t.Fatal("unrestricted configuration became empty")
	}
}

// A revision changes a model's tuple. The list keeps naming the model, so the
// live artifact is declined until an operator appends it; only that entry is missing.
func TestCacheArtifactAllowlistMissingEntriesAreLiveArtifactsOfListedModels(t *testing.T) {
	listed := artifactTestIdentity()
	revisedWeights, revisedTemplate, neverListed := listed, listed, listed
	revisedWeights.ModelAggregateSHA256 = strings.Repeat("c", 64)
	revisedTemplate.PromptContractID = strings.Repeat("c", 64)
	neverListed.ModelID = "unlisted-model"
	live := []production.CacheRoutingArtifact{listed, revisedWeights, revisedTemplate, neverListed}

	for _, tc := range []struct {
		name      string
		allowlist []production.CacheRoutingArtifact
		missing   []production.CacheRoutingArtifact
	}{
		{name: "unrestricted list has no stale entries"},
		{name: "empty list names no model", allowlist: []production.CacheRoutingArtifact{}},
		{name: "revisions of a listed model", allowlist: []production.CacheRoutingArtifact{listed},
			missing: []production.CacheRoutingArtifact{revisedWeights, revisedTemplate}},
		{name: "appended revision is covered", allowlist: []production.CacheRoutingArtifact{listed, revisedWeights},
			missing: []production.CacheRoutingArtifact{revisedTemplate}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := production.New(testLogger())
			if err := r.ConfigureCacheRouting(artifactTestConfig(tc.allowlist)); err != nil {
				t.Fatal(err)
			}
			if missing := r.MissingCacheRoutingAllowlistEntries(live); !slices.Equal(missing, tc.missing) {
				t.Fatalf("missing=%+v, want %+v", missing, tc.missing)
			}
		})
	}
}
