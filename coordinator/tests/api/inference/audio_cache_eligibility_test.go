package inference_test

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

	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
	"github.com/eigeninference/d-inference/coordinator/api/promptwork"
	routeplan "github.com/eigeninference/d-inference/coordinator/internal/inference/routeplan"
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
		var result registry.CachePlanResult
		planningCalls := 0
		memo := routeplan.New(
			func(string) ([]byte, error) { return []byte(body), nil },
			func(model string, encoded []byte, hasMedia bool) promptwork.Result {
				planningCalls++
				result = reg.PlanCacheRouteWithResult(context.Background(), client, registry.CachePlanInput{
					Account: "account", Model: model,
					ModelAggregateSHA256: capability.ModelAggregateHash,
					PromptContractID:     capability.PromptContractID, Body: encoded,
					HasMedia: hasMedia,
				})
				return promptwork.Result{Cache: result.Plan}
			}, inreq.DetectMediaRequirement(parsed), parsed)
		_ = memo.ForModel(capability.ModelID)              // actual preflight entry
		_ = memo.ForBody(capability.ModelID, []byte(body)) // actual dispatch entry
		if planningCalls != 1 {
			t.Fatal("matching preflight/dispatch repeated planning or lost a media refusal")
		}
		return result
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
