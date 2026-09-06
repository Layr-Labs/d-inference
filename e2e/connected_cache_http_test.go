package e2e

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/e2e/testbed"
	"github.com/stretchr/testify/require"
)

// Opt-in only. Ordinary go test -short never launches Swift, GPU or sidecar.
// Run twice with the same final binary/artifacts and cache_mode off/ssd.
func TestIntegrationConnectedCacheHTTP(t *testing.T) {
	runConnectedCacheHTTP(t, "DARKBLOOM_CONNECTED_CACHE_INPUT", "DARKBLOOM_CONNECTED_CACHE_OUTPUT", false)
}

func runConnectedCacheHTTP(t *testing.T, inputEnvironment, outputEnvironment string, correctnessOnly bool) {
	inputPath := os.Getenv(inputEnvironment)
	if testing.Short() || inputPath == "" {
		t.Skip("explicit connected real-provider fixture input required")
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	defer cancel()
	root := os.Getenv(outputEnvironment)
	require.NotEmpty(t, root)
	require.NoError(t, os.Mkdir(root, 0700), "output must be new")
	report := connectedReport{Schema: 1, State: "running", Limits: []string{
		"Real testbed wire/control-plane fixture; same-host providers do not prove independent-machine capacity or latency.",
		"Test-only trust override, ephemeral SSD keys; no attestation or signed restart durability proof.",
		"HTTP retains SSE/content/tools/counts; raw generated token IDs are unavailable.",
		"WS receipts are observed separately from coordinator acceptance counters; cases are sequential and donations drain before the next case.",
		"Provider read bytes and process memory are heartbeat snapshots; per-request read bytes unavailable. Capture overhead remains total cold-path delta.",
		"Old-echo, expiry/eviction, reconnect, queued revoke and expensive-holder score controls remain separate coordinator unit gates, not model results from this runner.",
	}}
	names := []string{"cold_donor_a", "same_prompt_a", "tenant_isolation_a", "continuation_b", "original_after_continuation", "tools", "vision", "cancel", "after_cancel", "sidecar_unavailable"}
	for _, name := range names {
		report.Cases = append(report.Cases, connectedCase{Name: name, Status: "not_run"})
	}
	relay := &testbed.ProviderWireRelay{}
	routes := &connectedRouteLog{}
	t.Cleanup(func() {
		report.Wire, report.WireDropped = relay.Snapshot()
		report.Routes = routes.snapshot()
		if t.Failed() {
			report.State = "failed"
		} else {
			report.State = "completed"
		}
		saveConnectedReport(t, root, &report)
	})
	saveConnectedReport(t, root, &report)
	raw, err := os.ReadFile(inputPath)
	require.NoError(t, err)
	require.NoError(t, json.Unmarshal(raw, &report.Input))
	in := report.Input
	require.NoError(t, validateConnectedRunScope(in, correctnessOnly))
	fixture, err := in.validate()
	require.NoError(t, err)
	if in.Providers == nil {
		canonical, original, err := connectedHostPreflight(in)
		require.NoError(t, err)
		// This check never restores or deletes somebody else's config on mismatch.
		t.Cleanup(func() {
			current, err := fileSHA256(canonical)
			require.NoError(t, err)
			require.Equal(t, original, current, "host canonical config changed; no repair performed")
		})
		runtimeBinary, err := stageConnectedRuntime(root, in.ProviderBinary)
		require.NoError(t, err)
		copiedBinaryHash, err := fileSHA256(runtimeBinary)
		require.NoError(t, err)
		require.Equal(t, in.ProviderSHA256, copiedBinaryHash)
		copiedMetallibHash, err := fileSHA256(filepath.Join(filepath.Dir(runtimeBinary), "mlx.metallib"))
		require.NoError(t, err)
		require.Equal(t, in.MetallibSHA256, copiedMetallibHash)
		t.Setenv("DARKBLOOM_PROVIDER_BINARY", runtimeBinary)
	} else {
		report.Schema = 2
		report.Scope = "two_host_base_routing"
		report.Cases = report.Cases[:5]
		report.Limits[0] = "Two explicitly owned provider hosts; this base fixture covers donor/repeat/tenant/continuation/original routing only."
		if correctnessOnly {
			report.Schema = 3
			report.Scope = "two_host_cache_routing_correctness"
			report.Cases = append(report.Cases, connectedCase{Name: "cancel", Status: "not_run"}, connectedCase{Name: "after_cancel", Status: "not_run"})
			report.Limits[0] = "Two explicitly owned provider hosts; correctness covers donor/repeat/tenant/continuation/original routing, cancellation and post-cancel reuse."
			report.Limits[4] = "Provider read bytes and process memory are heartbeat snapshots; per-request read bytes unavailable. Timing is retained for diagnostics only."
			report.Limits = append(report.Limits, "Correctness-only: launch retains cold thermal/load limits; between requests temperature/load are observations without benchmark thresholds. No latency or throughput conclusions.")
		}
		sidecarHash, err := fileSHA256(in.SidecarBinary)
		require.NoError(t, err)
		require.Equal(t, in.SidecarSHA256, sidecarHash)
	}
	t.Setenv("DARKBLOOM_PROMPT_SIDECAR_BINARY", in.SidecarBinary)
	t.Setenv("DARKBLOOM_PREFIX_CACHE", map[string]string{"ssd": "1", "off": "0"}[in.CacheMode])
	// Never inherit resident cache, persistent-key overrides, kill switches or
	// allocator/grant tuning from an unrelated benchmark process.
	for _, key := range []string{"DARKBLOOM_PREFIX_CACHE_MEMORY", "DARKBLOOM_PREFIX_CACHE_TEST_PERSISTENT_KEY", "DARKBLOOM_CBV2_PAGED_KV", "DARKBLOOM_ACTIVATION_RESERVE_GB", "DARKBLOOM_MEM_CAP_FRACTION"} {
		if _, ok := os.LookupEnv(key); ok {
			t.Fatalf("unset inherited serving-policy override %s before this gate", key)
		}
	}
	var requiredCapabilities []string
	for _, catalog := range in.Catalog {
		if catalog.Entry.ID == in.Artifact.ModelID {
			requiredCapabilities = catalog.Entry.RequiredProviderCapabilities
		}
	}
	suite := testbed.NewSuite(testbed.SuiteConfig{
		ModelSpecs: []testbed.ModelSpec{{ModelID: in.Artifact.ModelID, NumProviders: 2}}, NumUsers: 2, UseMemoryStore: true,
		ProviderTargets: in.Providers, PrefixCacheMode: in.CacheMode,
		CatalogModels: in.Catalog, ExpectedProviderCapabilities: requiredCapabilities, EnableEphemeralPrefixCache: true, ProviderRelay: relay,
		MTPMode: in.MTPMode, MTPDrafterPath: in.AssistantPath, KVBackend: in.Backend, MaxConcurrent: in.MaxConcurrent, ExpectKVBackend: in.Backend,
	})
	suite.Logger = slog.New(routes)
	started := false
	defer func() {
		if in.Providers == nil {
			suite.Stop()
			return
		}
		var bindingErr error
		if started {
			report.Hosts, bindingErr = suite.HostBindings()
		}
		cleanupErr := suite.StopAndWait()
		report.HostLifecycles = suite.HostLifecycles()
		for i, p := range suite.Providers {
			if i < len(report.Hosts) {
				report.Hosts[i].Cleanup = p.HostCleanup()
			}
		}
		// Cleanup has run before any assertion can terminate this deferred function.
		require.NoError(t, errors.Join(bindingErr, cleanupErr), "owned host binding or cleanup failed")
	}()
	require.NoError(t, suite.Start(ctx))
	started = true
	model := in.Artifact.ModelID
	providers, err := suite.BoundProviders()
	require.NoError(t, err)
	require.Len(t, providers, 2)
	require.Eventually(t, func() bool {
		slots := connectedSlots(suite, model)
		if len(slots) != 2 {
			return false
		}
		for _, slot := range slots {
			found := false
			if slot.Capacity != nil {
				for _, capacity := range slot.Capacity.Slots {
					if capacity.Model == model {
						found = true
					}
				}
			}
			if !found {
				return false
			}
			if slot.Aggregate != in.Artifact.ModelAggregateSHA256 {
				return false
			}
			if in.CacheMode == "ssd" && (slot.Capability == nil || !slot.Capability.Ready) {
				return false
			}
		}
		return true
	}, time.Minute, 100*time.Millisecond, "exact loaded cache capability did not arrive")
	loadedSlots := connectedSlots(suite, model)
	require.Len(t, loadedSlots, 2)
	for _, slot := range loadedSlots {
		foundCapacity := false
		require.Equal(t, in.Artifact.ModelAggregateSHA256, slot.Aggregate)
		if in.CacheMode == "ssd" {
			require.Equal(t, in.Artifact.PromptContractID, slot.Capability.PromptContractID)
			require.Equal(t, protocol.PrefixCacheReadyBoundaryCheckpoint, slot.Capability.ReadyBoundaryMode)
		}
		require.NotNil(t, slot.Capacity)
		for _, capacity := range slot.Capacity.Slots {
			if capacity.Model == model {
				foundCapacity = true
				require.NotNil(t, capacity.KVBackend)
				require.Equal(t, in.Backend, *capacity.KVBackend)
				require.Nil(t, capacity.KVBackendFallbackReason)
			}
		}
		require.True(t, foundCapacity, "exact model capacity slot missing")
	}
	_, _, supervisor, preloader := startExactCacheSidecar(t, suite, fixture, model, in.Artifact.PromptContractID)
	suite.Coordinator.Server.SetPromptSupervisor(supervisor)
	key := make([]byte, 32)
	_, err = rand.Read(key)
	require.NoError(t, err)
	require.NoError(t, suite.Coordinator.Registry.ConfigureCacheRouting(registry.CacheRoutingConfig{
		Mode: registry.CacheRoutingOn, ActivationPct: 100, TTL: 10 * time.Minute, MaxHolders: 4,
		MasterKey: base64.RawURLEncoding.EncodeToString(key), AllowedArtifacts: []registry.CacheRoutingArtifact{in.Artifact},
	}))
	// Planning itself is checked against real tokenization, before any donation.
	body := connectedTextBody(model, in.Prompt, 64)
	var normalized map[string]any
	require.NoError(t, json.Unmarshal(body, &normalized))
	promptcontract.SetRequestDate(normalized, time.Now())
	plannedBody, err := json.Marshal(normalized)
	require.NoError(t, err)
	plan := suite.Coordinator.Registry.PlanCacheRouteWithResult(ctx, supervisor.Client(), registry.CachePlanInput{Account: suite.Users[0].AccountID, Model: model, ModelAggregateSHA256: in.Artifact.ModelAggregateSHA256, PromptContractID: in.Artifact.PromptContractID, Body: plannedBody})
	require.Equal(t, registry.CachePlanPlanned, plan.Outcome)
	require.GreaterOrEqual(t, plan.Plan.PromptTokenCount, 2048, "fixture must clear the unchanged 1024-token SSD hit floor with checkpoint/tail room")
	selectOnly := func(index int) {
		for i, p := range providers {
			p.Mu().Lock()
			p.Status = registry.StatusOnline
			if index >= 0 && i != index {
				p.Status = registry.StatusUntrusted
			}
			p.Mu().Unlock()
		}
	}
	// Only candidate membership is controlled; no cache receipt, cost, load or
	// capacity is fabricated. Natural routing wins when both are enabled.
	run := func(index, user int, request []byte, cancel bool, expect string) bool {
		row := &report.Cases[index]
		return t.Run(row.Name, func(t *testing.T) {
			if in.Providers != nil {
				var entryErr error
				row.HostEntry, entryErr = waitConnectedHostEntry(ctx, suite, model, in)
				if entryErr != nil {
					row.Status = "not_ready"
					row.Error = entryErr.Error()
					t.Error(entryErr)
					return
				}
			}
			row.Status = "running"
			row.Tenant = user
			selected := 0
			if index == 3 {
				selected = 1
			}
			if index == 4 {
				selected = -1
			}
			selectOnly(selected)
			if selected >= 0 {
				row.RequiredProviderID = providers[selected].ID
			}
			row.Request = request
			row.RequestDateUTC = time.Now().UTC().Format(time.DateOnly)
			beforeWire, _ := relay.Snapshot()
			row.Before = suite.Coordinator.Server.ExactCacheStatusSnapshot()
			row.SlotsBefore = connectedSlots(suite, model)
			saveConnectedReport(t, root, &report)
			defer func() {
				row.After = suite.Coordinator.Server.ExactCacheStatusSnapshot()
				row.SlotsAfter = connectedSlots(suite, model)
				all, _ := relay.Snapshot()
				row.Wire = all[len(beforeWire):]
				if t.Failed() {
					row.Status = "failed"
				} else {
					row.Status = "passed"
				}
				saveConnectedReport(t, root, &report)
			}()
			var err error
			row.HTTP, err = postConnectedStream(suite.Ctx, suite.Coordinator.BaseURL(), suite.Users[user].APIKey, request, cancel)
			if err != nil {
				row.Error = err.Error()
			}
			require.NoError(t, err)
			if row.RequiredProviderID != "" {
				require.Equal(t, row.RequiredProviderID, row.HTTP.ProviderID, "controlled candidate selection changed before dispatch")
			}
			require.Equal(t, row.RequestDateUTC, time.Now().UTC().Format(time.DateOnly), "UTC rollover requires rerunning the paired date contract")
			require.Eventually(t, func() bool {
				all, _ := relay.Snapshot()
				terminalSeen := false
				for _, event := range all[len(beforeWire):] {
					if event.Type == "inference_complete" || event.Type == "inference_error" {
						terminalSeen = true
					}
				}
				if !terminalSeen {
					return false
				}
				for _, p := range providers {
					if p.PendingCount() != 0 {
						return false
					}
				}
				return true
			}, 30*time.Second, 50*time.Millisecond, "request did not retire in coordinator")
			if in.CacheMode == "ssd" && expect != "vision" && expect != "outage" {
				// Donor close/Ready and heartbeat telemetry can lag the SSE terminal.
				settleCacheRoutingTelemetry(t, suite.Coordinator.Registry)
			}
			all, dropped := relay.Snapshot()
			require.Zero(t, dropped)
			row.Wire = all[len(beforeWire):]
			row.After = suite.Coordinator.Server.ExactCacheStatusSnapshot()
			if err := validateConnectedCase(*row, in.CacheMode, in.MTPMode, expect); err != nil {
				row.Error = err.Error()
				t.Fatal(err)
			}
			if err := validateConnectedRoute(*row, routes.snapshot(), in.CacheMode, expect); err != nil {
				row.Error = err.Error()
				t.Fatal(err)
			}
		})
	}
	if !run(0, 0, body, false, "cold") {
		return
	}
	if in.CacheMode == "ssd" {
		require.Greater(t, report.Cases[0].After.Lifecycle.SSDDonations, report.Cases[0].Before.Lifecycle.SSDDonations)
	}
	if !run(1, 0, body, false, "hit") {
		return
	}
	require.Equal(t, report.Cases[0].HTTP.Content, report.Cases[1].HTTP.Content)
	require.Equal(t, report.Cases[0].HTTP.Reasoning, report.Cases[1].HTTP.Reasoning)
	if !run(2, 1, body, false, "cold") {
		return
	}
	continuation := map[string]any{"model": model, "messages": []map[string]string{{"role": "user", "content": in.Prompt}, {"role": "assistant", "content": report.Cases[0].HTTP.Content, "reasoning_content": report.Cases[0].HTTP.Reasoning}, {"role": "user", "content": "Explain one further detail about the preceding text."}}, "temperature": 0, "seed": 0, "max_tokens": 64, "stream": true, "stream_options": map[string]bool{"include_usage": true}}
	continuationBody, _ := json.Marshal(continuation)
	if !run(3, 0, continuationBody, false, "cold") {
		return
	}
	// A longer endpoint on B is not evidence for the original shorter endpoint;
	// validate actual matched position against its explicit earlier Ready list.
	if !run(4, 0, body, false, "branch") {
		return
	}
	require.Equal(t, report.Cases[0].HTTP.Content, report.Cases[4].HTTP.Content)
	require.Equal(t, report.Cases[0].HTTP.Reasoning, report.Cases[4].HTTP.Reasoning)
	require.NoError(t, validateConnectedBranch(report.Cases[4], report.Cases[:4]))
	if in.Providers != nil {
		if correctnessOnly {
			if !run(5, 0, connectedTextBody(model, in.Prompt+" Continue producing a long numbered list.", 2048), true, "cancel") {
				return
			}
			run(6, 0, body, false, "hit")
		}
		return
	}
	var tools map[string]any
	require.NoError(t, json.Unmarshal(in.ToolsRequest, &tools))
	tools["model"] = model
	tools["stream"] = true
	tools["stream_options"] = map[string]bool{"include_usage": true}
	toolBody, _ := json.Marshal(tools)
	if !run(5, 0, toolBody, false, "tools") {
		return
	}
	if in.VisionPNG != "" {
		hash, err := fileSHA256(in.VisionPNG)
		require.NoError(t, err)
		require.Equal(t, in.VisionSHA256, hash)
		image, err := os.ReadFile(in.VisionPNG)
		require.NoError(t, err)
		vision := map[string]any{"model": model, "messages": []any{map[string]any{"role": "user", "content": []any{map[string]any{"type": "text", "text": "Describe the visible colors and shape in one short sentence."}, map[string]any{"type": "image_url", "image_url": map[string]string{"url": "data:image/png;base64," + base64.StdEncoding.EncodeToString(image)}}}}}, "temperature": 0, "max_tokens": 64, "stream": true, "stream_options": map[string]bool{"include_usage": true}}
		visionBody, _ := json.Marshal(vision)
		if !run(6, 0, visionBody, false, "vision") {
			return
		}
	} else {
		report.Cases[6].Status = "not_applicable"
		report.Cases[6].Error = "no supported vision fixture supplied; no vision coverage claimed"
	}
	if !run(7, 0, connectedTextBody(model, in.Prompt+" Continue producing a long numbered list.", 2048), true, "cancel") {
		return
	}
	if !run(8, 0, body, false, "hit") {
		return
	}
	preloader.Close()
	supervisor.Close()
	if !run(9, 0, body, false, "outage") {
		return
	}
}
func connectedTextBody(model, prompt string, maxTokens int) []byte {
	body, _ := json.Marshal(map[string]any{"model": model, "messages": []map[string]string{{"role": "user", "content": prompt}}, "temperature": 0, "seed": 0, "max_tokens": maxTokens, "stream": true, "stream_options": map[string]bool{"include_usage": true}})
	return body
}
