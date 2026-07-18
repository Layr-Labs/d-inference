package api

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestExactCacheStatusIsAggregateAndPrivacySafe(t *testing.T) {
	logger := slog.New(slog.DiscardHandler)
	reg := registry.New(logger)
	srv := NewServer(reg, store.NewMemory(store.Config{}), ServerConfig{}, logger)
	srv.SetPromptSupervisor(promptcontract.NewSupervisor(promptcontract.SupervisorConfig{
		Enabled: true,
	}))

	reg.Register("private-provider-v0", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: "private-model-v0"}},
	})
	reg.Register("private-provider-v1", nil, &protocol.RegisterMessage{
		PrefixCacheProtocol: 1,
		Models:              []protocol.ModelInfo{{ID: "private-model-v1"}},
	})
	v2 := reg.Register("private-provider-v2", nil, &protocol.RegisterMessage{
		PrefixCacheProtocol: 2,
		Models: []protocol.ModelInfo{{
			ID: "private-model-v2", WeightHash: strings.Repeat("a", 64),
		}},
		PrefixCacheV2Models: []protocol.PrefixCacheV2Capability{{
			ModelID: "private-model-v2", ModelAggregateHash: strings.Repeat("a", 64),
			PromptContractID: strings.Repeat("b", 64),
			BlockHashVersion: promptcontract.BlockHashVersion,
			BlockSize:        promptcontract.BlockSize,
			CacheEpoch:       "11111111-1111-1111-1111-111111111111",
			Enabled:          true, Ready: true,
		}},
	})
	if v2 == nil {
		t.Fatal("register v2 provider")
	}

	request := httptest.NewRequest(http.MethodGet, "/v1/cache/status", nil)
	response := httptest.NewRecorder()
	srv.Handler().ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	var status ExactCacheStatus
	if err := json.Unmarshal(response.Body.Bytes(), &status); err != nil {
		t.Fatal(err)
	}
	if status.Providers.V0 != 1 || status.Providers.V1 != 1 ||
		status.Providers.V2 != 1 || status.Providers.V2ReadyModels != 1 {
		t.Fatalf("provider protocol status=%+v", status.Providers)
	}
	if status.RoutingMode != registry.CacheRoutingOff {
		t.Fatalf("routing mode=%q, want off", status.RoutingMode)
	}
	if !status.Sidecar.Enabled || status.Sidecar.Running || status.Sidecar.Ready {
		t.Fatalf("sidecar status=%+v", status.Sidecar)
	}
	for _, sensitive := range []string{
		"private-provider", "private-model", strings.Repeat("a", 64),
		strings.Repeat("b", 64), "11111111-1111-1111-1111-111111111111",
	} {
		if strings.Contains(response.Body.String(), sensitive) {
			t.Fatalf("cache status leaked %q: %s", sensitive, response.Body.String())
		}
	}

	gauges := srv.Metrics().Snapshot().Gauges
	for _, key := range []string{
		"exact_cache_routing_mode{mode=off}",
		"exact_cache_routing_mode{mode=on}",
		"exact_cache_sidecar_enabled",
		"exact_cache_sidecar_running",
		"exact_cache_sidecar_ready",
		"exact_cache_prompt_artifacts{state=ready}",
		"exact_cache_prompt_artifacts{state=pending}",
		"exact_cache_prompt_artifacts{state=failed}",
		"exact_cache_provider_protocol{version=0}",
		"exact_cache_provider_protocol{version=1}",
		"exact_cache_provider_protocol{version=2}",
		"exact_cache_v2_ready_models",
		"exact_cache_holders",
		"exact_cache_attempts",
	} {
		if _, ok := gauges[key]; !ok {
			t.Fatalf("missing exact-cache gauge %q", key)
		}
	}
}

func TestSummarizePromptArtifactsCoversAllStates(t *testing.T) {
	summary := summarizePromptArtifacts([]promptcontract.ProvisionStatus{
		{ModelID: "private-ready", ArtifactReady: true},
		{ModelID: "private-pending"},
		{ModelID: "private-failed", LastError: "private filesystem detail"},
	})
	if summary.Ready != 1 || summary.Pending != 1 || summary.Failed != 1 {
		t.Fatalf("summary=%+v", summary)
	}
	encoded, err := json.Marshal(summary)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), "private") {
		t.Fatalf("artifact summary leaked detail: %s", encoded)
	}
}
