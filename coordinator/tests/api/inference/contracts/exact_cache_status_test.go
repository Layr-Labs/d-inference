package inference_test

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	api "github.com/eigeninference/d-inference/coordinator/api"
	infer "github.com/eigeninference/d-inference/coordinator/api/inference"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	testkit "github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
)

func TestExactCacheStatusIsAggregateAndPrivacySafe(t *testing.T) {
	logger := slog.New(slog.DiscardHandler)
	reg := registry.New(logger)
	srv := testkit.NewServer(t, reg, memory.NewMemory(store.Config{}), api.ServerConfig{}, logger)
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
	memory := protocol.PrefixCacheV2Capability{
		ModelID: "private-model-memory", ModelAggregateHash: strings.Repeat("a", 64),
		PromptContractID: strings.Repeat("b", 64),
		BlockHashVersion: promptcontract.BlockHashVersion, BlockSize: promptcontract.BlockSize,
		CacheEpoch: "11111111-1111-1111-1111-111111111111", Enabled: true, Ready: true,
	}
	reg.Register("private-provider-memory", nil, &protocol.RegisterMessage{
		PrefixCacheProtocol:     2,
		Models:                  []protocol.ModelInfo{{ID: memory.ModelID, WeightHash: memory.ModelAggregateHash}},
		PrefixCacheMemoryModels: []protocol.PrefixCacheV2Capability{memory},
	})

	request := httptest.NewRequest(http.MethodGet, "/v1/cache/status", nil)
	response := httptest.NewRecorder()
	srv.Handler().ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	var status infer.ExactCacheStatus
	if err := json.Unmarshal(response.Body.Bytes(), &status); err != nil {
		t.Fatal(err)
	}
	if status.Providers.V0 != 1 || status.Providers.V1 != 1 ||
		status.Providers.V2 != 2 || status.Providers.V2ReadyModels != 1 ||
		status.Providers.MemoryReadyModels != 1 {
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
	// A typed decode reads an absent key as 0. Readers of the body rely on the
	// key itself, which is present before first sight has applied to anything.
	if !strings.Contains(response.Body.String(), `"first_sight":`) {
		t.Fatalf("cache status body has no first_sight key: %s", response.Body.String())
	}
	if !status.Sidecar.Enabled || status.Sidecar.Running || status.Sidecar.Ready {
		t.Fatalf("sidecar status=%+v", status.Sidecar)
	}
	requireEmptyFunnelShape(t, response.Body.Bytes())
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
		"exact_cache_activation{outcome=first_sight}",
		"exact_cache_artifact_allowlist_configured",
		"exact_cache_artifact_allowlist_count",
		"exact_cache_artifact_allowlist_stale_models",
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
		"exact_cache_memory_ready_models",
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
		"exact_cache_eligibility_strategy{strategy=tail_replay}",
		"exact_cache_holders",
		"exact_cache_attempts",
		"exact_cache_ssd_lifecycle{event=lookup}",
		"exact_cache_ssd_lifecycle{event=miss}",
		"exact_cache_ssd_lifecycle{event=hit}",
		"exact_cache_ssd_lifecycle{event=donation}",
		"exact_cache_holder_added",
		"exact_cache_holder_removed{reason=ttl}",
		"exact_cache_holder_removed{reason=capability_change}",
		"exact_cache_holder_removed{reason=shorter_hit}",
		"exact_cache_donation_outcome{outcome=donated}",
		"exact_cache_donation_outcome{outcome=write_queue_full}",
		"exact_cache_fence{event=applied}",
		"exact_cache_fence{event=expired}",
		"exact_cache_fenced_capabilities",
		"exact_cache_attempt_bytes",
		"exact_cache_attempt_budget_refused",
		"exact_cache_attempt_grace_reclaimed",
		"exact_cache_donation_outcome{outcome=skipped_novel}",
		"exact_cache_demand_entries",
		"exact_cache_demand_cap_evictions",
	} {
		if _, ok := gauges[key]; !ok {
			t.Fatalf("missing exact-cache gauge %q", key)
		}
	}
}

// requireEmptyFunnelShape pins the funnel section's wire names: the three
// conservation counters, every terminal reason in lifecycle order with the
// same request-level counters as the total and no token sum, and the stages
// declared unobserved.
func requireEmptyFunnelShape(t *testing.T, body []byte) {
	t.Helper()
	var decoded struct {
		Funnel struct {
			Entered    *uint64             `json:"entered"`
			Closed     *uint64             `json:"closed"`
			InFlight   *uint64             `json:"in_flight"`
			Total      map[string]uint64   `json:"total"`
			Reasons    []map[string]any    `json:"reasons"`
			Unobserved []map[string]string `json:"unobserved"`
		} `json:"funnel"`
	}
	if err := json.Unmarshal(body, &decoded); err != nil {
		t.Fatal(err)
	}
	funnel := decoded.Funnel
	if funnel.Entered == nil || funnel.Closed == nil || funnel.InFlight == nil ||
		*funnel.Entered != 0 || *funnel.Closed != 0 || *funnel.InFlight != 0 {
		t.Fatalf("funnel counters = %v %v %v, want entered, closed and in_flight present and zero",
			funnel.Entered, funnel.Closed, funnel.InFlight)
	}
	// Counts of requests and attempts only. A token sum on this unauthenticated
	// endpoint would give away one request's exact prompt-derived counts to
	// anyone differencing two snapshots around its close.
	counters := []string{
		"requests", "attempts", "dispatched_without_scope", "lookup_outcome_reported",
		"prompt_tokens_unknown", "repeated_prefix_tokens_unknown", "predicted_tokens_unknown", "reused_tokens_unknown",
	}
	tokenSums := []string{"prompt_tokens", "repeated_prefix_tokens", "predicted_tokens", "reused_tokens"}
	if len(funnel.Total) != len(counters) {
		t.Fatalf("funnel total = %v, want exactly %v", funnel.Total, counters)
	}
	for _, sum := range tokenSums {
		if _, exposed := funnel.Total[sum]; exposed {
			t.Fatalf("public funnel total exposes token sum %q", sum)
		}
	}
	for _, counter := range counters {
		if _, ok := funnel.Total[counter]; !ok {
			t.Fatalf("funnel total is missing %q: %v", counter, funnel.Total)
		}
	}
	reasons := []string{
		"not_eligible", "planner_unavailable", "gate_refused", "sampled_out", "rate_limited",
		"plan_failed", "plan_empty", "planning_unobserved",
		"cancelled_before_dispatch", "errored_before_dispatch",
		"routing_unobserved", "no_repeat_observed", "repeat_without_holder",
		"holder_unusable_or_unavailable", "holder_not_selected",
		"selected_without_scope", "cancelled_after_dispatch", "errored_after_dispatch",
		"selected_outcome_unknown", "selected_skip", "selected_miss", "hit_without_selection", "hit",
	}
	if len(funnel.Reasons) != len(reasons) {
		t.Fatalf("funnel lists %d reasons, want %d: %v", len(funnel.Reasons), len(reasons), funnel.Reasons)
	}
	for i, reason := range reasons {
		entry := funnel.Reasons[i]
		if entry["reason"] != reason {
			t.Fatalf("funnel reason %d = %v, want %q", i, entry["reason"], reason)
		}
		if len(entry) != len(counters)+1 {
			t.Fatalf("funnel reason %q = %v, want the reason name and %v", reason, entry, counters)
		}
		for _, sum := range tokenSums {
			if _, exposed := entry[sum]; exposed {
				t.Fatalf("public funnel reason %q exposes token sum %q", reason, sum)
			}
		}
		for _, counter := range counters {
			if value, ok := entry[counter]; !ok || value != float64(0) {
				t.Fatalf("funnel reason %q counter %q = %v, want present and zero", reason, counter, value)
			}
		}
	}
	unobserved := make(map[string]bool)
	for _, stage := range funnel.Unobserved {
		if stage["reason"] == "" {
			t.Fatalf("unobserved stage %q gives no reason", stage["stage"])
		}
		unobserved[stage["stage"]] = true
	}
	if len(unobserved) != 2 || !unobserved["predicted_tokens"] || !unobserved["lookup_receipt"] {
		t.Fatalf("funnel unobserved = %v, want predicted_tokens and lookup_receipt", funnel.Unobserved)
	}
}
