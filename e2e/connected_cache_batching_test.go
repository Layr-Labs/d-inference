package e2e

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/e2e/testbed"
	"github.com/stretchr/testify/require"
)

// This opt-in fixture requires two successful, output-equivalent concurrent
// requests AND observed native multirow processing. Merely configuring B2 or
// accepting one of several requests is not batching qualification.
func TestIntegrationConnectedCacheBatching(t *testing.T) {
	path := os.Getenv("DARKBLOOM_CONNECTED_BATCH_INPUT")
	if testing.Short() || path == "" {
		t.Skip("explicit immutable local B2 input required")
	}
	raw, err := os.ReadFile(path)
	require.NoError(t, err)
	var in connectedCacheInput
	require.NoError(t, json.Unmarshal(raw, &in))
	require.Equal(t, 2, in.MaxConcurrent)
	require.Equal(t, "paged", in.Backend)
	require.Equal(t, "off", in.MTPMode)
	require.Contains(t, []string{"off", "ssd"}, in.CacheMode)
	require.Nil(t, in.Providers)
	require.False(t, in.CorrectnessOnly)
	fixture, err := in.validate()
	require.NoError(t, err)
	require.NoError(t, releaseDefaultEnvironment(os.Environ()))
	canonical, original, err := connectedHostPreflight(in)
	require.NoError(t, err)
	t.Cleanup(func() {
		current, err := fileSHA256(canonical)
		require.NoError(t, err)
		require.Equal(t, original, current)
	})
	root := os.Getenv("DARKBLOOM_CONNECTED_BATCH_OUTPUT")
	require.NotEmpty(t, root)
	require.NoError(t, os.Mkdir(root, 0700))
	binary, err := stageConnectedRuntime(root, in.ProviderBinary)
	require.NoError(t, err)
	for path, wanted := range map[string]string{binary: in.ProviderSHA256, filepath.Join(filepath.Dir(binary), "mlx.metallib"): in.MetallibSHA256} {
		got, err := fileSHA256(path)
		require.NoError(t, err)
		require.Equal(t, wanted, got)
	}
	t.Setenv("DARKBLOOM_PROVIDER_BINARY", binary)
	t.Setenv("DARKBLOOM_PROMPT_SIDECAR_BINARY", in.SidecarBinary)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	relay := &testbed.ProviderWireRelay{}
	suite := testbed.NewSuite(testbed.SuiteConfig{
		ModelSpecs: []testbed.ModelSpec{{ModelID: in.Artifact.ModelID, NumProviders: 1}},
		NumUsers:   1, UseMemoryStore: true, CatalogModels: in.Catalog, ProviderRelay: relay,
		EnableEphemeralPrefixCache: true, PrefixCacheMode: in.CacheMode,
		KVBackend: "paged", ExpectKVBackend: "paged", MTPMode: "off", MaxConcurrent: 2,
	})
	defer func() { require.NoError(t, suite.StopAndWait()) }()
	report := struct {
		State      string                      `json:"state"`
		Mode       string                      `json:"cache_mode"`
		Serial     connectedStream             `json:"serial"`
		Concurrent []connectedStream           `json:"concurrent"`
		Wire       []testbed.ProviderWireEvent `json:"concurrent_wire"`
		Dropped    int                         `json:"dropped"`
		Error      string                      `json:"error,omitempty"`
	}{State: "running", Mode: in.CacheMode}
	t.Cleanup(func() {
		report.State = "completed"
		if t.Failed() {
			report.State = "failed"
		}
		data, err := json.MarshalIndent(report, "", "  ")
		require.NoError(t, err)
		require.NoError(t, os.WriteFile(filepath.Join(root, "report.json"), append(data, '\n'), 0600))
	})
	require.NoError(t, suite.Start(ctx))
	providers, err := suite.BoundProviders()
	require.NoError(t, err)
	require.Len(t, providers, 1)
	if in.CacheMode == "ssd" {
		_, _, supervisor, _ := startExactCacheSidecar(t, suite, fixture, in.Artifact.ModelID, in.Artifact.PromptContractID)
		suite.Coordinator.Server.SetPromptSupervisor(supervisor)
		key := make([]byte, 32)
		_, err = rand.Read(key)
		require.NoError(t, err)
		require.NoError(t, suite.Coordinator.Registry.ConfigureCacheRouting(registry.CacheRoutingConfig{
			Mode: registry.CacheRoutingOn, ActivationPct: 100, TTL: 10 * time.Minute,
			MaxHolders: 1, MasterKey: base64.RawURLEncoding.EncodeToString(key), AllowedArtifacts: []registry.CacheRoutingArtifact{in.Artifact},
		}))
	}
	body := connectedTextBody(in.Artifact.ModelID, in.Prompt, 128)
	report.Serial, err = postConnectedStream(ctx, suite.Coordinator.BaseURL(), suite.Users[0].APIKey, body, false)
	require.NoError(t, err)
	require.Equal(t, 200, report.Serial.HTTPStatus)
	require.True(t, report.Serial.Done)
	require.NotEmpty(t, report.Serial.Finish)
	require.NoError(t, validateReleaseDefaultRepeat(report.Serial, report.Serial))
	require.Eventually(t, func() bool { return providers[0].PendingCount() == 0 }, 30*time.Second, 50*time.Millisecond)
	require.Eventually(t, func() bool {
		return connectedSlotsQuiescent(connectedSlots(suite, in.Artifact.ModelID), 1, in.Artifact.ModelID)
	}, 30*time.Second, 100*time.Millisecond, "native slot did not become quiescent after serial reference")
	if in.CacheMode == "ssd" {
		settleCacheRoutingTelemetry(t, suite.Coordinator.Registry)
	}
	before := suite.Coordinator.Server.ExactCacheStatusSnapshot()
	if in.CacheMode == "ssd" {
		require.Positive(t, before.Lifecycle.SSDDonations)
	}
	wireBefore, dropped := relay.Snapshot()
	require.Zero(t, dropped)
	type result struct {
		index  int
		output connectedStream
		err    error
	}
	start, done := make(chan struct{}), make(chan result, 2)
	for index := 0; index < 2; index++ {
		go func(index int) {
			<-start
			out, err := postConnectedStream(ctx, suite.Coordinator.BaseURL(), suite.Users[0].APIKey, body, false)
			done <- result{index, out, err}
		}(index)
	}
	close(start)
	report.Concurrent = make([]connectedStream, 2)
	var firstError error
	for range 2 {
		value := <-done // Every started HTTP worker must retire before assertions.
		report.Concurrent[value.index] = value.output
		if value.err != nil && firstError == nil {
			firstError = value.err
		}
	}
	if firstError != nil {
		report.Error = firstError.Error()
	}
	require.NoError(t, firstError)
	require.Eventually(t, func() bool { return providers[0].PendingCount() == 0 }, 30*time.Second, 50*time.Millisecond)
	require.Eventually(t, func() bool {
		return connectedSlotsQuiescent(connectedSlots(suite, in.Artifact.ModelID), 1, in.Artifact.ModelID)
	}, 30*time.Second, 100*time.Millisecond, "native slot did not retire both concurrent requests")
	if in.CacheMode == "ssd" {
		settleCacheRoutingTelemetry(t, suite.Coordinator.Registry)
	}
	all, dropped := relay.Snapshot()
	report.Wire, report.Dropped = all[len(wireBefore):], dropped
	require.Zero(t, dropped)
	for _, out := range report.Concurrent {
		require.Equal(t, 200, out.HTTPStatus)
		require.True(t, out.Done)
		require.False(t, out.CancelledByClient)
		require.NoError(t, validateReleaseDefaultRepeat(report.Serial, out))
		require.NoError(t, validateConnectedBatchUsage(report.Serial.Usage, out.Usage))
	}
	require.NoError(t, validateConnectedBatchWire(report.Wire, in.CacheMode))
	after := suite.Coordinator.Server.ExactCacheStatusSnapshot()
	if in.CacheMode == "ssd" {
		require.EqualValues(t, 2, after.Lifecycle.SSDLookups-before.Lifecycle.SSDLookups)
		require.EqualValues(t, 2, after.Lifecycle.SSDHits-before.Lifecycle.SSDHits)
	}
}

// Preserve all usage detail, including reasoning counts. Only cached-token
// discounts may differ between the cold serial reference and warm requests.
func validateConnectedBatchUsage(reference, actual json.RawMessage) error {
	strip := func(raw json.RawMessage) (map[string]any, error) {
		var usage map[string]any
		if err := json.Unmarshal(raw, &usage); err != nil {
			return nil, err
		}
		if usage == nil {
			return nil, fmt.Errorf("missing usage")
		}
		if detail, ok := usage["prompt_tokens_details"]; ok {
			fields, valid := detail.(map[string]any)
			if !valid {
				return nil, fmt.Errorf("invalid prompt usage details")
			}
			delete(fields, "cached_tokens")
			if len(fields) == 0 {
				delete(usage, "prompt_tokens_details")
			}
		}
		return usage, nil
	}
	a, err := strip(reference)
	if err != nil {
		return err
	}
	b, err := strip(actual)
	if err != nil {
		return err
	}
	if !reflect.DeepEqual(a, b) {
		return fmt.Errorf("concurrent usage detail differs from serial reference")
	}
	return nil
}

func validateConnectedBatchWire(events []testbed.ProviderWireEvent, cache string) error {
	type counts struct{ dispatch, terminal, hit int }
	byID := map[string]*counts{}
	multirow := false
	for _, event := range events {
		if event.RequestID == "" {
			continue
		}
		c := byID[event.RequestID]
		if c == nil {
			c = &counts{}
			byID[event.RequestID] = c
		}
		switch event.Type {
		case "inference_request":
			c.dispatch++
			var encrypted, scope bool
			if json.Unmarshal(event.Fields["encrypted_body_present"], &encrypted) != nil || !encrypted {
				return fmt.Errorf("unencrypted dispatch")
			}
			_ = json.Unmarshal(event.Fields["cache_scope_present"], &scope)
			if scope != (cache == "ssd") {
				return fmt.Errorf("wrong cache participation")
			}
			if cache == "ssd" {
				var nonce bool
				var boundary string
				_ = json.Unmarshal(event.Fields["cache_receipt_nonce_present"], &nonce)
				_ = json.Unmarshal(event.Fields["cache_receipt_boundary_mode"], &boundary)
				if !nonce || boundary != "checkpoint" {
					return fmt.Errorf("missing attempt binding")
				}
			}
		case "prefix_cache_lookup_v2":
			var outcome string
			_ = json.Unmarshal(event.Fields["outcome"], &outcome)
			if outcome != "hit" {
				return fmt.Errorf("warm concurrent lookup did not hit")
			}
			c.hit++
		case "inference_complete":
			c.terminal++
			var profile struct {
				MTPActive *bool `json:"mtp_active"`
				Engine    struct {
					BatchRowsMax *int `json:"batch_rows_max"`
				} `json:"engine"`
			}
			if json.Unmarshal(event.Fields["profile"], &profile) != nil || profile.MTPActive == nil || *profile.MTPActive {
				return fmt.Errorf("MTP posture missing or wrong")
			}
			if profile.Engine.BatchRowsMax == nil || *profile.Engine.BatchRowsMax < 1 || *profile.Engine.BatchRowsMax > 2 {
				return fmt.Errorf("batch width missing or outside B2")
			}
			if *profile.Engine.BatchRowsMax == 2 {
				multirow = true
			}
			var usage struct {
				Prompt     int    `json:"prompt_tokens"`
				Completion int    `json:"completion_tokens"`
				Cached     int    `json:"cached_tokens"`
				Saved      int    `json:"prefill_tokens_saved"`
				Outcome    string `json:"cache_outcome"`
				Tier       string `json:"cache_tier"`
			}
			if json.Unmarshal(event.Fields["usage"], &usage) != nil || usage.Prompt <= 0 || usage.Completion <= 0 {
				return fmt.Errorf("terminal usage absent")
			}
			if cache == "ssd" && (usage.Cached <= 0 || usage.Saved <= 0 || usage.Outcome != "hit" || usage.Tier != "ssd") {
				return fmt.Errorf("terminal lacks actual adoption")
			}
			if cache == "off" && (usage.Cached != 0 || usage.Saved != 0) {
				return fmt.Errorf("OFF reused cache")
			}
		case "inference_error":
			return fmt.Errorf("concurrent provider error")
		}
	}
	if len(byID) != 2 || !multirow {
		return fmt.Errorf("two distinct requests and actual native multirow evidence required")
	}
	for _, c := range byID {
		if c.dispatch != 1 || c.terminal != 1 || (cache == "ssd" && c.hit != 1) || (cache == "off" && c.hit != 0) {
			return fmt.Errorf("incomplete concurrent request lifecycle")
		}
	}
	return nil
}
