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
	v1Statuses := []protocol.PrefixCacheModelStatus{{
		ModelID: "private-model-v1", Backend: "paged", ReplayStrategy: "none",
		State: "disabled", Reason: "paged_hybrid_unsupported",
	}}
	reg.Register("private-provider-v1", nil, &protocol.RegisterMessage{
		PrefixCacheProtocol: 1,
		Models:              []protocol.ModelInfo{{ID: "private-model-v1"}},
		PrefixCacheStatuses: &v1Statuses,
	})
	v2Statuses := []protocol.PrefixCacheModelStatus{{
		ModelID: "private-model-v2", Backend: "contiguous", ReplayStrategy: "frozen_full",
		State: "ready", Reason: "ready",
	}}
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
		PrefixCacheStatuses: &v2Statuses,
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
	if status.Providers.LoadedModels != 2 ||
		status.Providers.ReportedLoadedModels != 2 ||
		status.Providers.ExcludedModels != 1 ||
		status.Providers.ByReason["paged_hybrid_unsupported"] != 1 ||
		status.Providers.ByReplayStrategy["frozen_full"] != 1 {
		t.Fatalf("provider eligibility status=%+v", status.Providers)
	}
	if status.RoutingMode != registry.CacheRoutingOff {
		t.Fatalf("routing mode=%q, want off", status.RoutingMode)
	}
	if status.Activation.Percent != 100 || status.Activation.MaxPlanQPS != 0 {
		t.Fatalf("activation status=%+v", status.Activation)
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
		"exact_cache_activation_percent",
		"exact_cache_activation_max_plan_qps",
		"exact_cache_activation{outcome=admitted}",
		"exact_cache_activation{outcome=sampled_out}",
		"exact_cache_activation{outcome=rate_limited}",
		"exact_cache_activation{outcome=cold_only}",
		"exact_cache_sidecar_enabled",
		"exact_cache_sidecar_running",
		"exact_cache_sidecar_ready",
		"exact_cache_sidecar_restart_reason{reason=none}",
		"exact_cache_sidecar_restart_suppressed",
		"exact_cache_sidecar_child_generation",
		"exact_cache_sidecar_consecutive_health_failures",
		"exact_cache_sidecar_health_timeouts",
		"exact_cache_sidecar_preload_timeouts",
		"exact_cache_preload_ready",
		"exact_cache_preload_contracts",
		"exact_cache_preload_runs",
		"exact_cache_preload_failures",
		"exact_cache_preload_results{state=warm}",
		"exact_cache_preload_results{state=cold}",
		"exact_cache_sidecar_plans{outcome=succeeded}",
		"exact_cache_sidecar_plans{outcome=cold_only}",
		"exact_cache_sidecar_plans{outcome=overload}",
		"exact_cache_sidecar_plans{outcome=timeout}",
		"exact_cache_sidecar_contract_loads{state=cold}",
		"exact_cache_sidecar_contract_loads{state=warm}",
		"exact_cache_prompt_artifacts{state=ready}",
		"exact_cache_prompt_artifacts{state=pending}",
		"exact_cache_prompt_artifacts{state=failed}",
		"exact_cache_provider_protocol{version=0}",
		"exact_cache_provider_protocol{version=1}",
		"exact_cache_provider_protocol{version=2}",
		"exact_cache_v2_ready_models",
		"exact_cache_loaded_models",
		"exact_cache_reported_loaded_models",
		"exact_cache_unreported_loaded_models",
		"exact_cache_excluded_models",
		"exact_cache_eligibility_state{state=ready}",
		"exact_cache_eligibility_state{state=disabled}",
		"exact_cache_eligibility_reason{reason=paged_hybrid_unsupported}",
		"exact_cache_eligibility_reason{reason=scan_failed}",
		"exact_cache_eligibility_backend{backend=contiguous}",
		"exact_cache_eligibility_backend{backend=paged}",
		"exact_cache_eligibility_strategy{strategy=frozen_full}",
		"exact_cache_holders",
		"exact_cache_attempts",
		"exact_cache_ssd_lifecycle{event=lookup}",
		"exact_cache_ssd_lifecycle{event=miss}",
		"exact_cache_ssd_lifecycle{event=hit}",
		"exact_cache_ssd_lifecycle{event=donation}",
		"exact_cache_holder_added",
		"exact_cache_holder_removed{reason=ttl}",
		"exact_cache_holder_removed{reason=capability_change}",
		"exact_cache_donation_outcome{outcome=donated}",
		"exact_cache_donation_outcome{outcome=write_queue_full}",
	} {
		if _, ok := gauges[key]; !ok {
			t.Fatalf("missing exact-cache gauge %q", key)
		}
	}

	collector := newUDPCollector(t)
	defer collector.Close()
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()
	srv.SetDatadog(ddClient)
	srv.emitExactCacheDDGauges()
	_ = ddClient.Statsd.Flush()
	packets := collector.drain()
	for _, metric := range []string{
		"exact_cache.eligibility_state",
		"exact_cache.eligibility_reason",
		"exact_cache.eligibility_backend",
		"exact_cache.eligibility_strategy",
		"exact_cache.holder_removed",
		"exact_cache.donation_outcome",
	} {
		if !hasMetric(packets, metric) {
			t.Fatalf("missing Datadog gauge %q in %v", metric, packets)
		}
	}
	encodedPackets := strings.Join(packets, "\n")
	for _, sensitive := range []string{
		"private-provider", "private-model", strings.Repeat("a", 64),
		strings.Repeat("b", 64), "11111111-1111-1111-1111-111111111111",
	} {
		if strings.Contains(encodedPackets, sensitive) {
			t.Fatalf("Datadog cache gauges leaked %q: %s", sensitive, encodedPackets)
		}
	}
}
