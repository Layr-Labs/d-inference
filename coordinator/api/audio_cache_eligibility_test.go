package api

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func audioCacheBodies() []string {
	return []string{
		`{"messages":[{"role":"user","content":[{"type":"text","text":"describe"},{"type":"input_audio","input_audio":{"data":"AAAA","format":"wav"}}]}]}`,
		`{"messages":[{"role":"user","content":[{"type":"input_audio"}]}]}`,
		`{"messages":[{"role":"user","content":[{"type":"input_audio","input_audio":null}]}]}`,
		`{"messages":[{"role":"tool","tool_call_id":"c","content":[{"type":"audio_url","audio_url":42}]}]}`,
		`{"messages":[{"role":"user","content":[{"type":"input_audio","input_audio":{"data":"AAAA","format":"mp3"}}]}]}`,
		`{"input":[{"type":"message","role":"user","content":[{"type":"audio_url","audio_url":{"url":"https://example.invalid/private"}}]}]}`,
		`{"input":[{"type":"function_call_output","call_id":"c","output":[{"type":"input_audio","input_audio":null}]}]}`,
		`{"input":[{"type":"function_call_output","call_id":"c","output":{"type":"audio_url"}}]}`,
		`{"messages":[{"role":"user","content":[{"type":"tool_result","tool_use_id":"c","content":[{"type":"input_audio"}]}]}]}`,
	}
}

func TestAudioCachePresenceDoesNotChangeVisionOrEstimates(t *testing.T) {
	for _, body := range audioCacheBodies() {
		var parsed map[string]any
		if err := json.Unmarshal([]byte(body), &parsed); err != nil {
			t.Fatal(err)
		}
		before, err := json.Marshal(parsed)
		if err != nil {
			t.Fatal(err)
		}
		if !requestHasAudioForCache(parsed) || !cachePlanHasMedia(false, parsed) {
			t.Fatal("declared audio did not close text-cache admission")
		}
		if detectMediaRequirement(parsed) || countMediaParts(parsed) != 0 {
			t.Fatal("audio acquired a vision requirement/count")
		}
		// Independent pre-existing estimators: cache classification is not a
		// new routing price and must never replace the billing byte bound.
		routing, billing, media := legacyEstimates(parsed)
		shape := introspectRequest(parsed)
		if shape.routingPromptTokens(parsed) != routing ||
			shape.billingPromptTokens(parsed) != billing || media != 0 {
			t.Fatal("audio cache detection changed routing/billing/vision estimates")
		}
		after, err := json.Marshal(parsed)
		if err != nil || string(before) != string(after) {
			t.Fatal("presence classification mutated request bytes")
		}
	}
}

func TestAudioCachePresenceIgnoresWordsSchemasAndArguments(t *testing.T) {
	for _, body := range []string{
		`{"messages":[{"role":"user","content":"input_audio audio_url"}]}`,
		`{"messages":[{"role":"user","content":[{"type":"text","text":"{\"type\":\"input_audio\"}"}]}]}`,
		`{"messages":[{"role":"assistant","tool_calls":[{"type":"function","function":{"name":"f","arguments":"{\"type\":\"input_audio\"}"}}]}],"tools":[{"type":"function","function":{"parameters":{"type":"audio_url"}}}]}`,
		`{"input":[{"type":"function_call","name":"f","arguments":{"type":"input_audio"}},{"type":"function_call_output","call_id":"c","output":"audio_url"}]}`,
		`{"messages":[{"role":"user","content":"plain"}],"metadata":{"content":{"type":"audio_url"}}}`,
		`{"prompt":"input_audio audio_url"}`,
	} {
		var parsed map[string]any
		if err := json.Unmarshal([]byte(body), &parsed); err != nil {
			t.Fatal(err)
		}
		if requestHasAudioForCache(parsed) || cachePlanHasMedia(false, parsed) {
			t.Fatal("non-content audio words became cache media")
		}
		if !cachePlanHasMedia(true, parsed) {
			t.Fatal("existing visual cache exclusion was weakened")
		}
	}
}

func TestAudioCacheHasMediaRefusesBeforeWorkingSidecar(t *testing.T) {
	// Same actual registry/client and bounded Unix socket framework as the
	// existing cache_preparation_helpers_test.go. No model/runtime is involved.
	reg := registry.New(quietLogger())
	configureCachePreparationTest(t, reg)
	capability := cacheEligibilityV2Capability("model")
	reg.SetModelCatalog([]registry.CatalogEntry{{
		ID: capability.ModelID, WeightHash: capability.ModelAggregateHash,
	}})
	root, err := os.MkdirTemp("/tmp", "audio-cache-api-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(root) })
	socket := filepath.Join(root, "sidecar.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(socket, 0o600); err != nil {
		_ = listener.Close()
		t.Fatal(err)
	}
	var calls atomic.Int32
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls.Add(1)
		hash := strings.Repeat("c", 64)
		_ = json.NewEncoder(w).Encode(promptcontract.Plan{
			PromptContractID: capability.PromptContractID, PromptTokenCount: 257,
			BlockBoundaries:       []promptcontract.Boundary{{TokenCount: 256, ChainHash: hash}},
			LastCompleteBlockHash: &hash,
		})
	})}
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(func() { _ = server.Close() })
	client := promptcontract.NewClient(promptcontract.ClientConfig{
		SocketPath: socket, RequestTimeout: time.Second,
	})
	t.Cleanup(client.Close)
	plan := func(body string) registry.CachePlanResult {
		var parsed map[string]any
		if err := json.Unmarshal([]byte(body), &parsed); err != nil {
			t.Fatal(err)
		}
		return reg.PlanCacheRouteWithResult(context.Background(), client, registry.CachePlanInput{
			Account: "account", Model: capability.ModelID,
			ModelAggregateSHA256: capability.ModelAggregateHash,
			PromptContractID:     capability.PromptContractID, Body: []byte(body),
			HasMedia: cachePlanHasMedia(detectMediaRequirement(parsed), parsed),
		})
	}
	control := plan(`{"messages":[{"role":"user","content":"plain input_audio word"}]}`)
	if control.Outcome != registry.CachePlanPlanned || !control.SidecarCalled || calls.Load() != 1 {
		t.Fatal("text control did not reach the working sidecar")
	}
	for _, body := range audioCacheBodies() {
		result := plan(body)
		if result.Outcome != registry.CachePlanIneligible || result.SidecarCalled || calls.Load() != 1 {
			t.Fatal("audio body reached cache activation/sidecar planning")
		}
	}
}
