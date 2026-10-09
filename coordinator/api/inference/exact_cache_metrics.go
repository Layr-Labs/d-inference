package inference

import (
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (s *Owner) RegisterExactCacheGauges() {
	s.observation.Metrics().RegisterSnapshotHook(func() {
		status := s.cachedExactCacheStatusSnapshot()
		s.exactCacheGaugeMu.Lock()
		s.exactCacheGaugeStatus = status
		s.exactCacheGaugeMu.Unlock()
	})
	gauge := func(value func(ExactCacheStatus) float64) observation.GaugeFunc {
		return func() float64 { return value(s.exactCacheGaugeSnapshot()) }
	}
	for _, mode := range []string{registry.CacheRoutingOff, registry.CacheRoutingOn} {
		mode := mode
		s.observation.Metrics().RegisterGaugeLabels("exact_cache_routing_mode", gauge(func(s ExactCacheStatus) float64 {
			return observation.BoolGauge(s.RoutingMode == mode)
		}), observation.MetricLabel{Name: "mode", Value: mode})
	}
	s.observation.Metrics().RegisterGauge("exact_cache_artifact_allowlist_configured", gauge(func(s ExactCacheStatus) float64 {
		return observation.BoolGauge(s.ArtifactAllowlist.Configured)
	}))
	s.observation.Metrics().RegisterGauge("exact_cache_artifact_allowlist_count", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.ArtifactAllowlist.Count)
	}))
	s.observation.Metrics().RegisterGauge("exact_cache_artifact_allowlist_stale_models", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.ArtifactAllowlist.StaleModels)
	}))
	s.observation.Metrics().RegisterGauge("exact_cache_sidecar_enabled", gauge(func(s ExactCacheStatus) float64 {
		return observation.BoolGauge(s.Sidecar.Enabled)
	}))
	s.observation.Metrics().RegisterGauge("exact_cache_activation_percent", gauge(func(s ExactCacheStatus) float64 {
		return s.Activation.Percent
	}))
	s.observation.Metrics().RegisterGauge("exact_cache_activation_max_plan_qps", gauge(func(s ExactCacheStatus) float64 {
		return s.Activation.MaxPlanQPS
	}))
	for _, activationOutcome := range []struct {
		name  string
		value func(registry.CacheRoutingActivationStatus) uint64
	}{
		{name: "evaluated", value: func(s registry.CacheRoutingActivationStatus) uint64 { return s.Evaluated }},
		{name: "sampled_in", value: func(s registry.CacheRoutingActivationStatus) uint64 { return s.SampledIn }},
		{name: "sampled_out", value: func(s registry.CacheRoutingActivationStatus) uint64 { return s.SampledOut }},
		{name: "rate_limited", value: func(s registry.CacheRoutingActivationStatus) uint64 { return s.RateLimited }},
		{name: "admitted", value: func(s registry.CacheRoutingActivationStatus) uint64 { return s.Admitted }},
		{name: "planned", value: func(s registry.CacheRoutingActivationStatus) uint64 { return s.Planned }},
		{name: "cold_only", value: func(s registry.CacheRoutingActivationStatus) uint64 { return s.ColdOnly }},
		{name: "plan_empty", value: func(s registry.CacheRoutingActivationStatus) uint64 { return s.PlanEmpty }},
		{name: "plan_failed", value: func(s registry.CacheRoutingActivationStatus) uint64 { return s.PlanFailed }},
	} {
		activationOutcome := activationOutcome
		s.observation.Metrics().RegisterGaugeLabels("exact_cache_activation", gauge(func(s ExactCacheStatus) float64 {
			return float64(activationOutcome.value(s.Activation))
		}), observation.MetricLabel{Name: "outcome", Value: activationOutcome.name})
	}
	s.observation.Metrics().RegisterGauge("exact_cache_sidecar_running", gauge(func(s ExactCacheStatus) float64 {
		return observation.BoolGauge(s.Sidecar.Running)
	}))
	s.observation.Metrics().RegisterGauge("exact_cache_sidecar_ready", gauge(func(s ExactCacheStatus) float64 {
		return observation.BoolGauge(s.Sidecar.Ready)
	}))
	s.observation.Metrics().RegisterGauge("exact_cache_sidecar_restarts", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Sidecar.Restarts)
	}))
	for _, reason := range []string{
		"none", "socket_error", "start_error", "child_exit", "startup_timeout",
		"health_failure_threshold", "rss_limit", "restart_cooldown",
	} {
		reason := reason
		s.observation.Metrics().RegisterGaugeLabels("exact_cache_sidecar_restart_reason", gauge(func(s ExactCacheStatus) float64 {
			current := s.Sidecar.RestartReason
			if current == "" {
				current = "none"
			}
			return observation.BoolGauge(current == reason)
		}), observation.MetricLabel{Name: "reason", Value: reason})
	}
	s.observation.Metrics().RegisterGauge("exact_cache_sidecar_restart_suppressed", gauge(func(s ExactCacheStatus) float64 {
		return observation.BoolGauge(s.Sidecar.RestartSuppressed)
	}))
	s.observation.Metrics().RegisterGauge("exact_cache_sidecar_child_generation", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Sidecar.ChildGeneration)
	}))
	s.observation.Metrics().RegisterGauge("exact_cache_sidecar_consecutive_health_failures", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Sidecar.ConsecutiveHealthFailures)
	}))
	s.observation.Metrics().RegisterGauge("exact_cache_sidecar_timeouts", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Sidecar.Timeouts)
	}))
	s.observation.Metrics().RegisterGauge("exact_cache_sidecar_health_timeouts", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Sidecar.HealthTimeouts)
	}))
	s.observation.Metrics().RegisterGauge("exact_cache_sidecar_preload_timeouts", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Sidecar.PreloadTimeouts)
	}))
	s.observation.Metrics().RegisterGauge("exact_cache_sidecar_overloads", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Sidecar.Overloads)
	}))
	s.observation.Metrics().RegisterGauge("exact_cache_sidecar_rss_bytes", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Sidecar.RSSBytes)
	}))
	s.observation.Metrics().RegisterGauge("exact_cache_preload_ready", gauge(func(s ExactCacheStatus) float64 {
		return observation.BoolGauge(s.Preload.Ready)
	}))
	s.observation.Metrics().RegisterGauge("exact_cache_preload_contracts", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Preload.ContractCount)
	}))
	s.observation.Metrics().RegisterGauge("exact_cache_preload_runs", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Preload.Runs)
	}))
	s.observation.Metrics().RegisterGauge("exact_cache_preload_failures", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Preload.Failures)
	}))
	s.observation.Metrics().RegisterGaugeLabels("exact_cache_preload_results", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Preload.Warm)
	}), observation.MetricLabel{Name: "state", Value: "warm"})
	s.observation.Metrics().RegisterGaugeLabels("exact_cache_preload_results", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Preload.Cold)
	}), observation.MetricLabel{Name: "state", Value: "cold"})
	for _, plannerOutcome := range []struct {
		name  string
		value func(promptcontract.SidecarPlanMetrics) uint64
	}{
		{name: "started", value: func(s promptcontract.SidecarPlanMetrics) uint64 { return s.Started }},
		{name: "succeeded", value: func(s promptcontract.SidecarPlanMetrics) uint64 { return s.Succeeded }},
		{name: "cold_only", value: func(s promptcontract.SidecarPlanMetrics) uint64 { return s.ColdOnly }},
		{name: "failed", value: func(s promptcontract.SidecarPlanMetrics) uint64 { return s.Failed }},
		{name: "overload", value: func(s promptcontract.SidecarPlanMetrics) uint64 { return s.AtCapacity }},
		{name: "not_ready", value: func(s promptcontract.SidecarPlanMetrics) uint64 { return s.NotReady }},
		{name: "timeout", value: func(s promptcontract.SidecarPlanMetrics) uint64 { return s.TimedOut }},
	} {
		plannerOutcome := plannerOutcome
		s.observation.Metrics().RegisterGaugeLabels("exact_cache_sidecar_plans", gauge(func(s ExactCacheStatus) float64 {
			return float64(plannerOutcome.value(s.Sidecar.Planner.Plans))
		}), observation.MetricLabel{Name: "outcome", Value: plannerOutcome.name})
	}
	for _, loadState := range []struct {
		name  string
		value func(promptcontract.SidecarContractMetrics) uint64
	}{
		{name: "cold", value: func(s promptcontract.SidecarContractMetrics) uint64 { return s.Cold }},
		{name: "warm", value: func(s promptcontract.SidecarContractMetrics) uint64 { return s.Warm }},
		{name: "waited", value: func(s promptcontract.SidecarContractMetrics) uint64 { return s.Waited }},
		{name: "failed", value: func(s promptcontract.SidecarContractMetrics) uint64 { return s.Failed }},
	} {
		loadState := loadState
		s.observation.Metrics().RegisterGaugeLabels("exact_cache_sidecar_contract_loads", gauge(func(s ExactCacheStatus) float64 {
			return float64(loadState.value(s.Sidecar.Planner.ContractLoads))
		}), observation.MetricLabel{Name: "state", Value: loadState.name})
	}
	s.observation.Metrics().RegisterGaugeLabels("exact_cache_prompt_artifacts", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.PromptArtifacts.Ready)
	}), observation.MetricLabel{Name: "state", Value: "ready"})
	s.observation.Metrics().RegisterGaugeLabels("exact_cache_prompt_artifacts", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.PromptArtifacts.Pending)
	}), observation.MetricLabel{Name: "state", Value: "pending"})
	s.observation.Metrics().RegisterGaugeLabels("exact_cache_prompt_artifacts", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.PromptArtifacts.Failed)
	}), observation.MetricLabel{Name: "state", Value: "failed"})
	s.observation.Metrics().RegisterGaugeLabels("exact_cache_provider_protocol", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Providers.V0)
	}), observation.MetricLabel{Name: "version", Value: "0"})
	s.observation.Metrics().RegisterGaugeLabels("exact_cache_provider_protocol", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Providers.V1)
	}), observation.MetricLabel{Name: "version", Value: "1"})
	s.observation.Metrics().RegisterGaugeLabels("exact_cache_provider_protocol", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Providers.V2)
	}), observation.MetricLabel{Name: "version", Value: "2"})
	s.observation.Metrics().RegisterGauge("exact_cache_v2_ready_models", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Providers.V2ReadyModels)
	}))
	s.observation.Metrics().RegisterGauge("exact_cache_memory_ready_models", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Providers.MemoryReadyModels)
	}))
	s.observation.Metrics().RegisterGauge("exact_cache_loaded_models", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Providers.LoadedModels)
	}))
	s.observation.Metrics().RegisterGauge("exact_cache_reported_loaded_models", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Providers.ReportedLoadedModels)
	}))
	s.observation.Metrics().RegisterGauge("exact_cache_unreported_loaded_models", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Providers.UnreportedLoadedModels)
	}))
	s.observation.Metrics().RegisterGauge("exact_cache_excluded_models", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Providers.ExcludedModels)
	}))
	for _, state := range registry.PrefixCacheStatusStates() {
		state := state
		s.observation.Metrics().RegisterGaugeLabels("exact_cache_eligibility_state", gauge(func(s ExactCacheStatus) float64 {
			return float64(s.Providers.ByState[state])
		}), observation.MetricLabel{Name: "state", Value: state})
	}
	for _, reason := range registry.PrefixCacheStatusReasons() {
		reason := reason
		s.observation.Metrics().RegisterGaugeLabels("exact_cache_eligibility_reason", gauge(func(s ExactCacheStatus) float64 {
			return float64(s.Providers.ByReason[reason])
		}), observation.MetricLabel{Name: "reason", Value: reason})
	}
	for _, backend := range registry.PrefixCacheStatusBackends() {
		backend := backend
		s.observation.Metrics().RegisterGaugeLabels("exact_cache_eligibility_backend", gauge(func(s ExactCacheStatus) float64 {
			return float64(s.Providers.ByBackend[backend])
		}), observation.MetricLabel{Name: "backend", Value: backend})
	}
	for _, strategy := range registry.PrefixCacheReplayStrategies() {
		strategy := strategy
		s.observation.Metrics().RegisterGaugeLabels("exact_cache_eligibility_strategy", gauge(func(s ExactCacheStatus) float64 {
			return float64(s.Providers.ByReplayStrategy[strategy])
		}), observation.MetricLabel{Name: "strategy", Value: strategy})
	}
	s.observation.Metrics().RegisterGauge("exact_cache_holders", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Holders)
	}))
	s.observation.Metrics().RegisterGauge("exact_cache_attempts", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Attempts)
	}))
	for _, lifecycle := range []struct {
		name  string
		value func(registry.CacheRoutingLifecycleStatus) uint64
	}{
		{name: "lookup", value: func(s registry.CacheRoutingLifecycleStatus) uint64 { return s.SSDLookups }},
		{name: "hit", value: func(s registry.CacheRoutingLifecycleStatus) uint64 { return s.SSDHits }},
		{name: "miss", value: func(s registry.CacheRoutingLifecycleStatus) uint64 { return s.SSDMisses }},
		{name: "donation", value: func(s registry.CacheRoutingLifecycleStatus) uint64 { return s.SSDDonations }},
	} {
		lifecycle := lifecycle
		s.observation.Metrics().RegisterGaugeLabels("exact_cache_ssd_lifecycle", gauge(func(s ExactCacheStatus) float64 {
			return float64(lifecycle.value(s.Lifecycle))
		}), observation.MetricLabel{Name: "event", Value: lifecycle.name})
	}
	s.observation.Metrics().RegisterGauge("exact_cache_holder_added", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Lifecycle.HolderAdded)
	}))
	for _, reason := range registry.CacheHolderRemovalReasons() {
		reason := reason
		s.observation.Metrics().RegisterGaugeLabels("exact_cache_holder_removed", gauge(func(s ExactCacheStatus) float64 {
			return float64(s.Lifecycle.HolderRemoved[reason])
		}), observation.MetricLabel{Name: "reason", Value: reason})
	}
	for _, outcome := range registry.PrefixCacheDonationOutcomes() {
		outcome := outcome
		s.observation.Metrics().RegisterGaugeLabels("exact_cache_donation_outcome", gauge(func(s ExactCacheStatus) float64 {
			return float64(s.Lifecycle.DonationOutcomes[outcome])
		}), observation.MetricLabel{Name: "outcome", Value: outcome})
	}
	for _, fence := range []struct {
		name  string
		value func(registry.CacheRoutingLifecycleStatus) uint64
	}{
		{name: "applied", value: func(s registry.CacheRoutingLifecycleStatus) uint64 { return s.FencesApplied }},
		{name: "expired", value: func(s registry.CacheRoutingLifecycleStatus) uint64 { return s.FencesExpired }},
	} {
		fence := fence
		s.observation.Metrics().RegisterGaugeLabels("exact_cache_fence", gauge(func(s ExactCacheStatus) float64 {
			return float64(fence.value(s.Lifecycle))
		}), observation.MetricLabel{Name: "event", Value: fence.name})
	}
	s.observation.Metrics().RegisterGauge("exact_cache_fenced_capabilities", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Lifecycle.FencedCapabilities)
	}))
	s.observation.Metrics().RegisterGauge("exact_cache_attempt_bytes", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Lifecycle.AttemptBytes)
	}))
	s.observation.Metrics().RegisterGauge("exact_cache_attempt_budget_refused", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Lifecycle.AttemptBudgetRefused)
	}))
	s.observation.Metrics().RegisterGauge("exact_cache_attempt_grace_reclaimed", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Lifecycle.AttemptGraceReclaimed)
	}))
	s.observation.Metrics().RegisterGauge("exact_cache_demand_entries", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Lifecycle.DemandEntries)
	}))
	s.observation.Metrics().RegisterGauge("exact_cache_demand_cap_evictions", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Lifecycle.DemandCapEvictions)
	}))
}

func (s *Owner) exactCacheGaugeSnapshot() ExactCacheStatus {
	s.exactCacheGaugeMu.RLock()
	status := s.exactCacheGaugeStatus
	s.exactCacheGaugeMu.RUnlock()
	return status
}

func (s *Owner) EmitExactCacheDDGauges() {
	status := s.cachedExactCacheStatusSnapshot()
	s.observation.Gauge("exact_cache.routing_mode", 1, []string{"mode:" + status.RoutingMode})
	s.observation.Gauge("exact_cache.artifact_allowlist.configured", observation.BoolGauge(status.ArtifactAllowlist.Configured), nil)
	s.observation.Gauge("exact_cache.artifact_allowlist.count", float64(status.ArtifactAllowlist.Count), nil)
	s.observation.Gauge("exact_cache.artifact_allowlist.stale_models", float64(status.ArtifactAllowlist.StaleModels), nil)
	s.observation.Gauge("exact_cache.activation.percent", status.Activation.Percent, nil)
	s.observation.Gauge("exact_cache.activation.max_plan_qps", status.Activation.MaxPlanQPS, nil)
	s.observation.Gauge("exact_cache.activation.total", float64(status.Activation.Evaluated), []string{"outcome:evaluated"})
	s.observation.Gauge("exact_cache.activation.total", float64(status.Activation.SampledIn), []string{"outcome:sampled_in"})
	s.observation.Gauge("exact_cache.activation.total", float64(status.Activation.SampledOut), []string{"outcome:sampled_out"})
	s.observation.Gauge("exact_cache.activation.total", float64(status.Activation.RateLimited), []string{"outcome:rate_limited"})
	s.observation.Gauge("exact_cache.activation.total", float64(status.Activation.Admitted), []string{"outcome:admitted"})
	s.observation.Gauge("exact_cache.activation.total", float64(status.Activation.Planned), []string{"outcome:planned"})
	s.observation.Gauge("exact_cache.activation.total", float64(status.Activation.ColdOnly), []string{"outcome:cold_only"})
	s.observation.Gauge("exact_cache.activation.total", float64(status.Activation.PlanEmpty), []string{"outcome:plan_empty"})
	s.observation.Gauge("exact_cache.activation.total", float64(status.Activation.PlanFailed), []string{"outcome:plan_failed"})
	s.observation.Gauge("exact_cache.sidecar.enabled", observation.BoolGauge(status.Sidecar.Enabled), nil)
	s.observation.Gauge("exact_cache.sidecar.running", observation.BoolGauge(status.Sidecar.Running), nil)
	s.observation.Gauge("exact_cache.sidecar.ready", observation.BoolGauge(status.Sidecar.Ready), nil)
	s.observation.Gauge("exact_cache.sidecar.restarts", float64(status.Sidecar.Restarts), nil)
	restartReason := status.Sidecar.RestartReason
	if restartReason == "" {
		restartReason = "none"
	}
	s.observation.Gauge("exact_cache.sidecar.restart_reason", 1, []string{"reason:" + restartReason})
	s.observation.Gauge("exact_cache.sidecar.restart_suppressed", observation.BoolGauge(status.Sidecar.RestartSuppressed), nil)
	s.observation.Gauge("exact_cache.sidecar.child_generation", float64(status.Sidecar.ChildGeneration), nil)
	s.observation.Gauge("exact_cache.sidecar.consecutive_health_failures", float64(status.Sidecar.ConsecutiveHealthFailures), nil)
	s.observation.Gauge("exact_cache.sidecar.timeouts", float64(status.Sidecar.Timeouts), nil)
	s.observation.Gauge("exact_cache.sidecar.health_timeouts", float64(status.Sidecar.HealthTimeouts), nil)
	s.observation.Gauge("exact_cache.sidecar.preload_timeouts", float64(status.Sidecar.PreloadTimeouts), nil)
	s.observation.Gauge("exact_cache.sidecar.overloads", float64(status.Sidecar.Overloads), nil)
	s.observation.Gauge("exact_cache.sidecar.rss_bytes", float64(status.Sidecar.RSSBytes), nil)
	s.observation.Gauge("exact_cache.preload.ready", observation.BoolGauge(status.Preload.Ready), nil)
	s.observation.Gauge("exact_cache.preload.contracts", float64(status.Preload.ContractCount), nil)
	s.observation.Gauge("exact_cache.preload.runs", float64(status.Preload.Runs), nil)
	s.observation.Gauge("exact_cache.preload.failures", float64(status.Preload.Failures), nil)
	s.observation.Gauge("exact_cache.preload.results", float64(status.Preload.Warm), []string{"state:warm"})
	s.observation.Gauge("exact_cache.preload.results", float64(status.Preload.Cold), []string{"state:cold"})
	s.observation.Gauge("exact_cache.sidecar.plans", float64(status.Sidecar.Planner.Plans.Started), []string{"outcome:started"})
	s.observation.Gauge("exact_cache.sidecar.plans", float64(status.Sidecar.Planner.Plans.Succeeded), []string{"outcome:succeeded"})
	s.observation.Gauge("exact_cache.sidecar.plans", float64(status.Sidecar.Planner.Plans.ColdOnly), []string{"outcome:cold_only"})
	s.observation.Gauge("exact_cache.sidecar.plans", float64(status.Sidecar.Planner.Plans.Failed), []string{"outcome:failed"})
	s.observation.Gauge("exact_cache.sidecar.plans", float64(status.Sidecar.Planner.Plans.AtCapacity), []string{"outcome:overload"})
	s.observation.Gauge("exact_cache.sidecar.plans", float64(status.Sidecar.Planner.Plans.NotReady), []string{"outcome:not_ready"})
	s.observation.Gauge("exact_cache.sidecar.plans", float64(status.Sidecar.Planner.Plans.TimedOut), []string{"outcome:timeout"})
	s.observation.Gauge("exact_cache.sidecar.contract_loads", float64(status.Sidecar.Planner.ContractLoads.Cold), []string{"state:cold"})
	s.observation.Gauge("exact_cache.sidecar.contract_loads", float64(status.Sidecar.Planner.ContractLoads.Warm), []string{"state:warm"})
	s.observation.Gauge("exact_cache.sidecar.contract_loads", float64(status.Sidecar.Planner.ContractLoads.Waited), []string{"state:waited"})
	s.observation.Gauge("exact_cache.sidecar.contract_loads", float64(status.Sidecar.Planner.ContractLoads.Failed), []string{"state:failed"})
	s.observation.Gauge("exact_cache.prompt_artifacts", float64(status.PromptArtifacts.Ready), []string{"state:ready"})
	s.observation.Gauge("exact_cache.prompt_artifacts", float64(status.PromptArtifacts.Pending), []string{"state:pending"})
	s.observation.Gauge("exact_cache.prompt_artifacts", float64(status.PromptArtifacts.Failed), []string{"state:failed"})
	s.observation.Gauge("exact_cache.provider_protocol", float64(status.Providers.V0), []string{"version:0"})
	s.observation.Gauge("exact_cache.provider_protocol", float64(status.Providers.V1), []string{"version:1"})
	s.observation.Gauge("exact_cache.provider_protocol", float64(status.Providers.V2), []string{"version:2"})
	s.observation.Gauge("exact_cache.v2_ready_models", float64(status.Providers.V2ReadyModels), nil)
	s.observation.Gauge("exact_cache.memory_ready_models", float64(status.Providers.MemoryReadyModels), nil)
	s.observation.Gauge("exact_cache.loaded_models", float64(status.Providers.LoadedModels), nil)
	s.observation.Gauge("exact_cache.reported_loaded_models", float64(status.Providers.ReportedLoadedModels), nil)
	s.observation.Gauge("exact_cache.unreported_loaded_models", float64(status.Providers.UnreportedLoadedModels), nil)
	s.observation.Gauge("exact_cache.excluded_models", float64(status.Providers.ExcludedModels), nil)
	for _, state := range registry.PrefixCacheStatusStates() {
		s.observation.Gauge("exact_cache.eligibility_state", float64(status.Providers.ByState[state]),
			[]string{"state:" + state})
	}
	for _, reason := range registry.PrefixCacheStatusReasons() {
		s.observation.Gauge("exact_cache.eligibility_reason", float64(status.Providers.ByReason[reason]),
			[]string{"reason:" + reason})
	}
	for _, backend := range registry.PrefixCacheStatusBackends() {
		s.observation.Gauge("exact_cache.eligibility_backend", float64(status.Providers.ByBackend[backend]),
			[]string{"backend:" + backend})
	}
	for _, strategy := range registry.PrefixCacheReplayStrategies() {
		s.observation.Gauge("exact_cache.eligibility_strategy", float64(status.Providers.ByReplayStrategy[strategy]),
			[]string{"strategy:" + strategy})
	}
	s.observation.Gauge("exact_cache.holders", float64(status.Holders), nil)
	s.observation.Gauge("exact_cache.attempts", float64(status.Attempts), nil)
	s.observation.Gauge("exact_cache.ssd_lifecycle", float64(status.Lifecycle.SSDLookups), []string{"event:lookup"})
	s.observation.Gauge("exact_cache.ssd_lifecycle", float64(status.Lifecycle.SSDHits), []string{"event:hit"})
	s.observation.Gauge("exact_cache.ssd_lifecycle", float64(status.Lifecycle.SSDMisses), []string{"event:miss"})
	s.observation.Gauge("exact_cache.ssd_lifecycle", float64(status.Lifecycle.SSDDonations), []string{"event:donation"})
	s.observation.Gauge("exact_cache.holder_added", float64(status.Lifecycle.HolderAdded), nil)
	for _, reason := range registry.CacheHolderRemovalReasons() {
		s.observation.Gauge("exact_cache.holder_removed", float64(status.Lifecycle.HolderRemoved[reason]),
			[]string{"reason:" + reason})
	}
	for _, outcome := range registry.PrefixCacheDonationOutcomes() {
		s.observation.Gauge("exact_cache.donation_outcome", float64(status.Lifecycle.DonationOutcomes[outcome]),
			[]string{"outcome:" + outcome})
	}
	s.observation.Gauge("exact_cache.fence", float64(status.Lifecycle.FencesApplied), []string{"event:applied"})
	s.observation.Gauge("exact_cache.fence", float64(status.Lifecycle.FencesExpired), []string{"event:expired"})
	s.observation.Gauge("exact_cache.fenced_capabilities", float64(status.Lifecycle.FencedCapabilities), nil)
	s.observation.Gauge("exact_cache.attempt_bytes", float64(status.Lifecycle.AttemptBytes), nil)
	s.observation.Gauge("exact_cache.attempt_budget_refused", float64(status.Lifecycle.AttemptBudgetRefused), nil)
	s.observation.Gauge("exact_cache.attempt_grace_reclaimed", float64(status.Lifecycle.AttemptGraceReclaimed), nil)
	s.observation.Gauge("exact_cache.demand_entries", float64(status.Lifecycle.DemandEntries), nil)
	s.observation.Gauge("exact_cache.demand_cap_evictions", float64(status.Lifecycle.DemandCapEvictions), nil)
}
