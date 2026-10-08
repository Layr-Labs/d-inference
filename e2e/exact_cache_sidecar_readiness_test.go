package e2e

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"os"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/e2e/testbed"
	"github.com/stretchr/testify/require"
)

// Exercise the shared fixture against the real Rust planner without starting a
// provider or model. Native preload success alone must not hide an unattached
// API controller; production installs its Registry projection before Start.
func TestExactCacheSidecarPublishesAPIReadiness(t *testing.T) {
	path := os.Getenv("DARKBLOOM_RELEASE_DEFAULT_INPUT")
	if path == "" {
		t.Skip("explicit immutable artifact input and verified Rust sidecar required")
	}
	raw, err := os.ReadFile(path)
	require.NoError(t, err)
	var input connectedCacheInput
	require.NoError(t, json.Unmarshal(raw, &input))
	fixture, err := input.validateArtifacts()
	require.NoError(t, err)
	digest, err := fileSHA256(input.SidecarBinary)
	require.NoError(t, err)
	require.Equal(t, input.SidecarSHA256, digest)
	t.Setenv("DARKBLOOM_PROMPT_SIDECAR_BINARY", input.SidecarBinary)
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	reg := registry.New(logger)
	server := api.NewServer(reg, testbed.NewMemoryStore(), api.ServerConfig{}, logger)
	t.Cleanup(server.Close)
	reg.SetModelCatalog([]registry.CatalogEntry{{ID: input.Artifact.ModelID, WeightHash: input.Artifact.ModelAggregateSHA256}})
	require.NoError(t, reg.ConfigureCacheRouting(flashNextCacheRoutingConfig(t, fixture, input.Artifact.PromptContractID)))
	suite := &testbed.Suite{Ctx: ctx, Coordinator: &testbed.Coordinator{Server: server, Registry: reg}}
	_, provisioner, supervisor, preloader := startExactCacheSidecar(t, suite, fixture, input.Artifact.ModelID, input.Artifact.PromptContractID)
	server.SetPromptSupervisor(supervisor)
	require.True(t, preloader.ReadyFor(input.Artifact.PromptContractID), "native tokenizer must actually acknowledge preload")
	require.True(t, server.ExactCacheStatusSnapshot().Preload.Ready, "preload controller was never attached to API")
	_, verified := provisioner.VerifiedPreloadArtifacts()
	require.Len(t, verified, 1)
	require.Positive(t, verified[0].CatalogGeneration)
	require.Equal(t, input.Artifact.ModelID, verified[0].ModelID)
	require.Equal(t, input.Artifact.ModelAggregateSHA256, verified[0].ModelAggregateSHA256)
	require.Equal(t, input.Artifact.PromptContractID, verified[0].PromptContractID)
	state := preloader.PlanningState(verified[0])
	require.True(t, state.Acknowledged)
	require.True(t, state.Participating, "API must use the current Registry projection")
	stale := verified[0]
	stale.CatalogGeneration = 0
	require.Equal(t, promptcontract.PreloadPlanningState{}, preloader.PlanningState(stale),
		"missing catalog generation must never gain API participation")
}
