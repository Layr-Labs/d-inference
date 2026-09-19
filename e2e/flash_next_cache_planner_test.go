package e2e

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"io"
	"log/slog"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/e2e/testbed"
	"github.com/stretchr/testify/require"
)

func flashNextCacheRoutingConfig(t *testing.T, fixture exactCacheArtifactFixture, contract string) registry.CacheRoutingConfig {
	t.Helper()
	key := make([]byte, 32)
	_, err := rand.Read(key)
	require.NoError(t, err)
	return registry.CacheRoutingConfig{Mode: registry.CacheRoutingOn, ActivationPct: 100,
		TTL: 10 * time.Minute, MaxHolders: 4, MasterKey: base64.RawURLEncoding.EncodeToString(key),
		AllowedArtifacts: []registry.CacheRoutingArtifact{{ModelID: fixture.manifest.ModelID,
			ModelAggregateSHA256: fixture.manifest.AggregateSHA256, PromptContractID: contract}}}
}

// Starts the real CPU-only Rust planner, never a provider or model. The
// minimal Suite is only an adapter for the existing sidecar lifecycle helper.
// No provider registration, capability, cache receipt or GPU result is mocked.
func TestFlashNextCachePlannerBindings(t *testing.T) {
	if os.Getenv("DARKBLOOM_FLASH_NEXT_CACHE_MANIFEST_CHECK") != "1" {
		t.Skip("explicit selected metadata and verified Rust sidecar required; no GPU is used")
	}
	fixture := flashNextCacheArtifacts(t)
	prompts, err := promptcontract.PromptArtifacts(fixture.manifest.Files)
	require.NoError(t, err)
	contract, err := promptcontract.ContractID(prompts, promptcontract.CurrentVersions())
	require.NoError(t, err)
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	reg := registry.New(logger)
	server := api.NewServer(reg, testbed.NewMemoryStore(), api.ServerConfig{}, logger)
	t.Cleanup(server.Close)
	suite := &testbed.Suite{Ctx: ctx, Coordinator: &testbed.Coordinator{Server: server, Registry: reg}}
	_, _, supervisor, _ := startExactCacheSidecar(t, suite, fixture, fixture.manifest.ModelID, contract)
	require.NoError(t, reg.ConfigureCacheRouting(flashNextCacheRoutingConfig(t, fixture, contract)))
	var body map[string]any
	require.NoError(t, json.Unmarshal(flashNextCacheScopeBody(), &body))
	promptcontract.SetRequestDate(body, time.Now())
	plannedBody, err := json.Marshal(body)
	require.NoError(t, err)
	input := registry.CachePlanInput{Account: "testbed-user-0", Model: fixture.manifest.ModelID,
		ModelAggregateSHA256: fixture.manifest.AggregateSHA256, PromptContractID: contract, Body: plannedBody}
	reg.SetModelCatalog([]registry.CatalogEntry{{ID: input.Model}})
	missing := reg.PlanCacheRouteWithResult(ctx, supervisor.Client(), input)
	require.Equal(t, registry.CachePlanIneligible, missing.Outcome)
	require.False(t, missing.SidecarCalled, "missing catalog weight must fail cold before planning")
	reg.SetModelCatalog([]registry.CatalogEntry{{ID: input.Model, WeightHash: input.ModelAggregateSHA256}})
	first := reg.PlanCacheRouteWithResult(ctx, supervisor.Client(), input)
	again := reg.PlanCacheRouteWithResult(ctx, supervisor.Client(), input)
	otherInput := input
	otherInput.Account = "testbed-user-1"
	other := reg.PlanCacheRouteWithResult(ctx, supervisor.Client(), otherInput)
	for _, result := range []registry.CachePlanResult{first, again, other} {
		require.Equal(t, registry.CachePlanPlanned, result.Outcome)
		require.True(t, result.SidecarCalled)
		require.Equal(t, 4207, result.Plan.PromptTokenCount, "matches the retained native reference")
		require.GreaterOrEqual(t, len(result.Plan.Boundaries), 16)
		require.True(t, result.Plan.CacheScope != "", "real planner must derive an account scope")
	}
	// Do not print or persist the raw derived scopes/chain hashes, even in a
	// failed assertion. The request body and caller labels are identical.
	require.True(t, first.Plan.CacheScope == again.Plan.CacheScope)
	require.True(t, first.Plan.CacheScope != other.Plan.CacheScope)
	for _, field := range []string{"aggregate", "contract", "account"} {
		invalid := input
		switch field {
		case "aggregate":
			invalid.ModelAggregateSHA256 = strings.Repeat("0", 64)
		case "contract":
			invalid.PromptContractID = strings.Repeat("0", 64)
		case "account":
			invalid.Account = ""
		}
		result := reg.PlanCacheRouteWithResult(ctx, supervisor.Client(), invalid)
		require.Equal(t, registry.CachePlanIneligible, result.Outcome, field)
		require.False(t, result.SidecarCalled, field)
	}
}
