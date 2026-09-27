package e2e

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/e2e/testbed"
	"github.com/stretchr/testify/require"
)

// A bounded two-request smoke. It does not replace connected lifecycle or B2/B4 gates.
func TestIntegrationReleaseDefaultsHTTP(t *testing.T) {
	runReleaseDefaultHTTP(t, false)
}

func runReleaseDefaultHTTP(t *testing.T, capabilities bool) {
	inputKey, outputKey := "DARKBLOOM_RELEASE_DEFAULT_INPUT", "DARKBLOOM_RELEASE_DEFAULT_OUTPUT"
	if capabilities {
		inputKey, outputKey = "DARKBLOOM_RELEASE_CAPABILITIES_INPUT", "DARKBLOOM_RELEASE_CAPABILITIES_OUTPUT"
	}
	inputPath := os.Getenv(inputKey)
	if testing.Short() || inputPath == "" {
		t.Skip("explicit final-candidate default smoke input required")
	}
	require.NoError(t, releaseDefaultEnvironment(os.Environ()))
	root := os.Getenv(outputKey)
	require.NotEmpty(t, root)
	require.NoError(t, os.Mkdir(root, 0700))
	report := connectedReport{Schema: 4, Scope: "release_defaults_b1_text", State: "running", Cases: []connectedCase{{Name: "cold", Status: "not_run"}, {Name: "repeat", Status: "not_run"}}, Limits: []string{"One local provider, two text requests, default backend/cache/MTP selection only; no B2/B4, tools, vision, cancellation, restart or two-host claim.", "Cache keys are explicitly ephemeral; cache enablement and model allowlist remain production defaults.", "Raw generated token IDs unavailable through HTTP; content/reasoning/finish/count comparison retained."}}
	relay := &testbed.ProviderWireRelay{}
	t.Cleanup(func() {
		report.Wire, report.WireDropped = relay.Snapshot()
		report.State = "completed"
		if t.Failed() {
			report.State = "failed"
		}
		saveConnectedReport(t, root, &report)
	})
	raw, err := os.ReadFile(inputPath)
	require.NoError(t, err)
	require.NoError(t, json.Unmarshal(raw, &report.Input))
	in := report.Input
	if capabilities {
		report.Scope = "release_defaults_b1_capabilities"
		report.Limits = []string{"One local provider; one original tools request and, for the three vision targets, one original image request. No text repeat, cache restoration, cancellation, concurrency or routing winner claim.", "Backend/cache/MTP remain production defaults. Original tool and vision semantics are validated; broad model quality requires separate review."}
		report.Cases, err = releaseCapabilityCases(in)
		require.NoError(t, err)
	}
	expected, err := releaseDefaultSelection(in)
	require.NoError(t, err)
	require.NoError(t, validateConnectedTargetBindings(in))
	fixture, err := in.validateArtifacts()
	require.NoError(t, err)
	canonical, original, err := connectedHostPreflight(in)
	require.NoError(t, err)
	t.Cleanup(func() {
		current, err := fileSHA256(canonical)
		require.NoError(t, err)
		require.Equal(t, original, current, "canonical config changed; no repair performed")
	})
	binary, err := stageConnectedRuntime(root, in.ProviderBinary)
	require.NoError(t, err)
	for path, expectedHash := range map[string]string{binary: in.ProviderSHA256, filepath.Join(filepath.Dir(binary), "mlx.metallib"): in.MetallibSHA256} {
		actual, err := fileSHA256(path)
		require.NoError(t, err)
		require.Equal(t, expectedHash, actual)
	}
	t.Setenv("DARKBLOOM_PROVIDER_BINARY", binary)
	t.Setenv("DARKBLOOM_PROMPT_SIDECAR_BINARY", in.SidecarBinary)
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	defer cancel()
	cfg := releaseDefaultSuite(in, relay)
	for _, catalog := range in.Catalog {
		if catalog.Entry.ID == in.Artifact.ModelID {
			cfg.ExpectedProviderCapabilities = catalog.Entry.RequiredProviderCapabilities
		}
	}
	suite := testbed.NewSuite(cfg)
	defer suite.Stop()
	require.NoError(t, suite.Start(ctx))
	require.Len(t, suite.Providers, 1)
	actualConfig, err := os.ReadFile(filepath.Join(suite.Providers[0].StateDir, "provider.toml"))
	require.NoError(t, err)
	require.Contains(t, string(actualConfig), `engine_v2_kv_backend = "auto"`)
	require.Contains(t, string(actualConfig), `mtp_mode = "auto"`)
	require.NoError(t, os.WriteFile(filepath.Join(root, "provider-config.toml"), actualConfig, 0600))
	require.Eventually(t, func() bool {
		return validateReleaseDefaultSlots(connectedSlots(suite, in.Artifact.ModelID), in, expected) == nil
	}, time.Minute, 100*time.Millisecond, "loaded slot does not prove release defaults")
	if expected.cache == "ssd" {
		_, _, supervisor, _ := startExactCacheSidecar(t, suite, fixture, in.Artifact.ModelID, in.Artifact.PromptContractID)
		suite.Coordinator.Server.SetPromptSupervisor(supervisor)
		key := make([]byte, 32)
		_, err = rand.Read(key)
		require.NoError(t, err)
		require.NoError(t, suite.Coordinator.Registry.ConfigureCacheRouting(registry.CacheRoutingConfig{Mode: registry.CacheRoutingOn, ActivationPct: 100, TTL: 10 * time.Minute, MaxHolders: 1, MasterKey: base64.RawURLEncoding.EncodeToString(key), AllowedArtifacts: []registry.CacheRoutingArtifact{in.Artifact}}))
	}
	body := connectedTextBody(in.Artifact.ModelID, in.Prompt, 64)
	providers, err := suite.BoundProviders()
	require.NoError(t, err)
	require.Len(t, providers, 1)
	for index := range report.Cases {
		row := &report.Cases[index]
		row.Status = "running"
		if !capabilities {
			row.Request = body
		}
		row.RequestDateUTC = time.Now().UTC().Format(time.DateOnly)
		row.Before = suite.Coordinator.Server.ExactCacheStatusSnapshot()
		row.SlotsBefore = connectedSlots(suite, in.Artifact.ModelID)
		before, _ := relay.Snapshot()
		saveConnectedReport(t, root, &report)
		row.HTTP, err = postConnectedStream(ctx, suite.Coordinator.BaseURL(), suite.Users[0].APIKey, row.Request, false)
		require.NoError(t, err)
		require.Eventually(t, func() bool {
			wire, _ := relay.Snapshot()
			terminal := false
			for _, event := range wire[len(before):] {
				if event.Type == "inference_complete" {
					terminal = true
				}
			}
			return terminal && providers[0].PendingCount() == 0
		}, 30*time.Second, 50*time.Millisecond, "request did not complete and retire")
		if expected.cache == "ssd" {
			settleCacheRoutingTelemetry(t, suite.Coordinator.Registry)
		}
		wire, dropped := relay.Snapshot()
		require.Zero(t, dropped)
		row.Wire = wire[len(before):]
		row.After = suite.Coordinator.Server.ExactCacheStatusSnapshot()
		row.SlotsAfter = connectedSlots(suite, in.Artifact.ModelID)
		require.NoError(t, validateReleaseDefaultSlots(row.SlotsAfter, in, expected))
		expectation := "cold"
		if capabilities {
			expectation = row.Name
		} else if index == 1 && expected.cache == "ssd" {
			expectation = "hit"
		}
		require.NoError(t, validateConnectedCase(*row, expected.cache, expected.mtp, expectation))
		if capabilities {
			// Reuse the accounting validator without asserting a nonexistent repeat.
			require.NoError(t, validateReleaseDefaultRepeat(row.HTTP, row.HTTP))
		}
		require.Equal(t, row.RequestDateUTC, time.Now().UTC().Format(time.DateOnly), "request date rollover")
		if !capabilities && index == 0 && expected.cache == "ssd" {
			require.Greater(t, row.After.Lifecycle.SSDDonations, row.Before.Lifecycle.SSDDonations)
		}
		row.Status = "passed"
		saveConnectedReport(t, root, &report)
	}
	if !capabilities {
		require.NoError(t, validateReleaseDefaultRepeat(report.Cases[0].HTTP, report.Cases[1].HTTP))
	}
}
