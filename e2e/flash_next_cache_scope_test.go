package e2e

import (
	"context"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/e2e/testbed"
	"github.com/stretchr/testify/require"
)

// One real native Qwen4 provider, two test accounts, and a real prompt sidecar.
// This is not a multi-host, signed persistence, raw-logit or hosted-route gate.
func TestIntegration_FlashNextCacheScope(t *testing.T) {
	if os.Getenv("DARKBLOOM_FLASH_NEXT_CACHE_SCOPE") != "1" {
		t.Skip("requires an explicitly owned Qwen4 cache qualification window")
	}
	require.Equal(t, flashNextMatrixModel, testbed.DefaultTestModelID())
	mode := os.Getenv("DARKBLOOM_FLASH_NEXT_MATRIX_MTP")
	require.Contains(t, []string{"off", "auto"}, mode)
	output := os.Getenv("DARKBLOOM_FLASH_NEXT_MATRIX_OUTPUT")
	require.True(t, filepath.IsAbs(output))
	require.NoError(t, os.Mkdir(output, 0700))
	fixture := flashNextCacheArtifacts(t)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	require.NoError(t, err)
	port := listener.Addr().(*net.TCPAddr).Port
	require.NoError(t, listener.Close())
	relay := &testbed.ProviderWireRelay{}
	s := testbed.NewSuite(testbed.SuiteConfig{
		ModelSpecs: []testbed.ModelSpec{{ModelID: flashNextMatrixModel, NumProviders: 1}},
		NumUsers:   2, KVBackend: "paged", ExpectKVBackend: "paged", MaxConcurrent: 1,
		MTPMode: mode, PrefixCacheMode: "ssd", EnableEphemeralPrefixCache: true,
		LocalEndpointPort: port, ProviderRelay: relay,
	})
	t.Cleanup(s.Stop)
	require.NoError(t, s.Start(context.Background()))
	require.Len(t, s.Providers, 1)
	require.Len(t, s.Users, 2)
	ids := s.Coordinator.Registry.ProviderIDs()
	require.Len(t, ids, 1)
	providerID := ids[0]
	_, err = flashNextMatrixIdle(s, providerID, mode)
	require.NoError(t, err)
	model := flashNextMatrixModel
	loaded := waitForLoadedModel(t, s.Coordinator.Registry.GetProvider(providerID), model, time.Minute)
	require.Equal(t, fixture.manifest.AggregateSHA256, loaded.WeightHash,
		"actual native full-model hash must match the explicit complete manifest")
	promptArtifacts, err := promptcontract.PromptArtifacts(fixture.manifest.Files)
	require.NoError(t, err)
	contract, err := promptcontract.ContractID(promptArtifacts, promptcontract.CurrentVersions())
	require.NoError(t, err)
	require.Eventually(t, func() bool {
		slots := connectedSlots(s, model)
		return len(slots) == 1 && slots[0].Aggregate == loaded.WeightHash &&
			slots[0].Capability != nil && slots[0].Capability.Ready &&
			slots[0].Capability.PromptContractID == contract
	}, time.Minute, 250*time.Millisecond, "exact native checkpoint capability not ready")
	metricsURL := "http://127.0.0.1:" + strconv.Itoa(port)
	nativeKey := filepath.Join(s.Providers[0].StateDir, "local", "local_token")
	require.NoError(t, flashNextMatrixWrite(filepath.Join(output, "binding.json"), map[string]any{
		"model": model, "model_aggregate_sha256": loaded.WeightHash,
		"prompt_contract_id": contract, "mtp_mode": mode, "provider_count": 1,
		"cache": "ssd", "kv_backend": "paged", "max_concurrent": 1,
		"scope": "Synthetic authenticated accounts; one real provider and sidecar; ephemeral key; no hosted or signed persistence claim.",
	}))
	body := flashNextCacheScopeBody()
	rows := []connectedCase{}
	var reference *connectedStream
	run := func(name string, tenant int, cacheMode, expect string) connectedCase {
		t.Helper()
		row := connectedCase{Name: name, Tenant: tenant, Status: "running", Request: body,
			RequestDateUTC: time.Now().UTC().Format(time.DateOnly)}
		defer func() {
			row.Status = "passed"
			if t.Failed() {
				row.Status = "failed"
			}
			rows = append(rows, row)
			require.NoError(t, flashNextMatrixWrite(filepath.Join(output, name+".json"), row))
		}()
		_, err := flashNextMatrixIdle(s, providerID, mode)
		require.NoError(t, err)
		flashNextCacheMetrics(t, output, name+".before", metricsURL, nativeKey)
		prior, dropped := relay.Snapshot()
		require.Zero(t, dropped)
		row.Before = s.Coordinator.Server.ExactCacheStatusSnapshot()
		row.SlotsBefore = connectedSlots(s, model)
		row.HTTP, err = postConnectedStream(s.Ctx, s.Coordinator.BaseURL(), s.Users[tenant].APIKey, body, false)
		require.NoError(t, err)
		require.Equal(t, providerID, row.HTTP.ProviderID)
		_, err = flashNextMatrixIdle(s, providerID, mode)
		require.NoError(t, err)
		settleCacheRoutingTelemetry(t, s.Coordinator.Registry)
		all, dropped := relay.Snapshot()
		require.Zero(t, dropped)
		row.Wire = all[len(prior):]
		row.After = s.Coordinator.Server.ExactCacheStatusSnapshot()
		row.SlotsAfter = connectedSlots(s, model)
		flashNextCacheMetrics(t, output, name+".after", metricsURL, nativeKey)
		require.Equal(t, row.RequestDateUTC, time.Now().UTC().Format(time.DateOnly))
		mtpExpectation := map[string]string{"off": "off", "auto": "on"}[mode]
		require.NoError(t, validateConnectedCase(row, cacheMode, mtpExpectation, expect))
		require.NoError(t, validateFlashNextCacheUsage(row))
		if reference != nil {
			flashNextCacheEquivalent(t, *reference, row.HTTP)
		}
		return row
	}
	// The same body (including deliberately identical caller cache labels) is
	// used throughout. Only the authenticated test account changes.
	baseline := run("unscoped_reference", 0, "off", "outage")
	reference = &baseline.HTTP
	supervisorConfig, provisioner, supervisor, preloader := startExactCacheSidecar(t, s, fixture, model, contract)
	s.Coordinator.Server.SetPromptSupervisor(supervisor)
	s.Coordinator.Registry.SetModelCatalog([]registry.CatalogEntry{{ID: model, WeightHash: loaded.WeightHash}})
	require.NoError(t, s.Coordinator.Registry.ConfigureCacheRouting(flashNextCacheRoutingConfig(t, fixture, contract)))
	for _, cell := range []struct {
		name   string
		tenant int
		expect string
	}{
		{"account_a_cold", 0, "cold"}, {"account_a_hit", 0, "hit"},
		{"account_b_cold_same_caller_labels", 1, "cold"}, {"account_b_hit", 1, "hit"},
		{"account_a_after_b", 0, "hit"},
	} {
		row := run(cell.name, cell.tenant, "ssd", cell.expect)
		if cell.expect == "cold" {
			require.Greater(t, row.After.Lifecycle.SSDDonations, row.Before.Lifecycle.SSDDonations)
		}
	}
	preloader.Close()
	supervisor.Close()
	run("sidecar_outage_cold", 0, "ssd", "outage")
	// Restart only the CPU sidecar, not the loaded model or cache. The old
	// provider state must remain usable once the exact contract is re-preloaded.
	restarted := promptcontract.NewSupervisor(supervisorConfig)
	restarted.Start(s.Ctx)
	t.Cleanup(restarted.Close)
	waitForSidecarLive(t, restarted, 15*time.Second)
	restartedPreloader, err := promptcontract.NewPreloadController(provisioner, restarted,
		promptcontract.PreloadControllerConfig{PollInterval: 50 * time.Millisecond})
	require.NoError(t, err)
	restartedPreloader.Start(s.Ctx)
	t.Cleanup(restartedPreloader.Close)
	s.Coordinator.Server.SetPromptContractClient(restarted.Client())
	s.Coordinator.Server.SetPromptPreloadController(restartedPreloader)
	s.Coordinator.Server.SetPromptSupervisor(restarted)
	waitForPreloadedContract(t, restartedPreloader, contract, 30*time.Second)
	run("sidecar_restart_hit", 0, "ssd", "hit")
	assertAccounting(t, s)
	require.NoError(t, flashNextMatrixWrite(filepath.Join(output, "summary.json"), map[string]any{
		"passed": !t.Failed(), "cases": len(rows), "mtp_mode": mode,
		"scope":         "Account isolation, caller-label non-authority, native SSD reuse and CPU sidecar restart only.",
		"not_qualified": []string{"provider process restart", "signed persistence", "multi-host routing", "raw-logit equivalence", "all model quality"},
	}))
}
