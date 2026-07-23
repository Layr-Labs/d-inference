package api

import (
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (s *Server) registerExactCacheGauges() {
	s.metrics.RegisterSnapshotHook(func() {
		status := s.cachedExactCacheStatusSnapshot()
		s.exactCacheGaugeMu.Lock()
		s.exactCacheGaugeStatus = status
		s.exactCacheGaugeMu.Unlock()
	})
	gauge := func(value func(ExactCacheStatus) float64) GaugeFunc {
		return func() float64 { return value(s.exactCacheGaugeSnapshot()) }
	}
	for _, mode := range []string{registry.CacheRoutingOff, registry.CacheRoutingOn} {
		mode := mode
		s.metrics.RegisterGaugeLabels("exact_cache_routing_mode", gauge(func(s ExactCacheStatus) float64 {
			return boolGauge(s.RoutingMode == mode)
		}), MetricLabel{"mode", mode})
	}
	s.metrics.RegisterGauge("exact_cache_sidecar_enabled", gauge(func(s ExactCacheStatus) float64 {
		return boolGauge(s.Sidecar.Enabled)
	}))
	s.metrics.RegisterGauge("exact_cache_activation_percent", gauge(func(s ExactCacheStatus) float64 {
		return s.Activation.Percent
	}))
	s.metrics.RegisterGauge("exact_cache_activation_max_plan_qps", gauge(func(s ExactCacheStatus) float64 {
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
		s.metrics.RegisterGaugeLabels("exact_cache_activation", gauge(func(s ExactCacheStatus) float64 {
			return float64(activationOutcome.value(s.Activation))
		}), MetricLabel{"outcome", activationOutcome.name})
	}
	s.metrics.RegisterGauge("exact_cache_sidecar_running", gauge(func(s ExactCacheStatus) float64 {
		return boolGauge(s.Sidecar.Running)
	}))
	s.metrics.RegisterGauge("exact_cache_sidecar_ready", gauge(func(s ExactCacheStatus) float64 {
		return boolGauge(s.Sidecar.Ready)
	}))
	s.metrics.RegisterGauge("exact_cache_sidecar_restarts", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Sidecar.Restarts)
	}))
	for _, reason := range []string{
		"none", "socket_error", "start_error", "child_exit", "startup_timeout",
		"health_failure_threshold", "rss_limit", "restart_cooldown",
	} {
		reason := reason
		s.metrics.RegisterGaugeLabels("exact_cache_sidecar_restart_reason", gauge(func(s ExactCacheStatus) float64 {
			current := s.Sidecar.RestartReason
			if current == "" {
				current = "none"
			}
			return boolGauge(current == reason)
		}), MetricLabel{"reason", reason})
	}
	s.metrics.RegisterGauge("exact_cache_sidecar_restart_suppressed", gauge(func(s ExactCacheStatus) float64 {
		return boolGauge(s.Sidecar.RestartSuppressed)
	}))
	s.metrics.RegisterGauge("exact_cache_sidecar_child_generation", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Sidecar.ChildGeneration)
	}))
	s.metrics.RegisterGauge("exact_cache_sidecar_consecutive_health_failures", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Sidecar.ConsecutiveHealthFailures)
	}))
	s.metrics.RegisterGauge("exact_cache_sidecar_timeouts", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Sidecar.Timeouts)
	}))
	s.metrics.RegisterGauge("exact_cache_sidecar_health_timeouts", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Sidecar.HealthTimeouts)
	}))
	s.metrics.RegisterGauge("exact_cache_sidecar_preload_timeouts", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Sidecar.PreloadTimeouts)
	}))
	s.metrics.RegisterGauge("exact_cache_sidecar_overloads", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Sidecar.Overloads)
	}))
	s.metrics.RegisterGauge("exact_cache_sidecar_rss_bytes", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Sidecar.RSSBytes)
	}))
	s.metrics.RegisterGauge("exact_cache_preload_ready", gauge(func(s ExactCacheStatus) float64 {
		return boolGauge(s.Preload.Ready)
	}))
	s.metrics.RegisterGauge("exact_cache_preload_contracts", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Preload.ContractCount)
	}))
	s.metrics.RegisterGauge("exact_cache_preload_runs", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Preload.Runs)
	}))
	s.metrics.RegisterGauge("exact_cache_preload_failures", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Preload.Failures)
	}))
	s.metrics.RegisterGaugeLabels("exact_cache_preload_results", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Preload.Warm)
	}), MetricLabel{"state", "warm"})
	s.metrics.RegisterGaugeLabels("exact_cache_preload_results", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Preload.Cold)
	}), MetricLabel{"state", "cold"})
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
		s.metrics.RegisterGaugeLabels("exact_cache_sidecar_plans", gauge(func(s ExactCacheStatus) float64 {
			return float64(plannerOutcome.value(s.Sidecar.Planner.Plans))
		}), MetricLabel{"outcome", plannerOutcome.name})
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
		s.metrics.RegisterGaugeLabels("exact_cache_sidecar_contract_loads", gauge(func(s ExactCacheStatus) float64 {
			return float64(loadState.value(s.Sidecar.Planner.ContractLoads))
		}), MetricLabel{"state", loadState.name})
	}
	s.metrics.RegisterGaugeLabels("exact_cache_prompt_artifacts", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.PromptArtifacts.Ready)
	}), MetricLabel{"state", "ready"})
	s.metrics.RegisterGaugeLabels("exact_cache_prompt_artifacts", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.PromptArtifacts.Pending)
	}), MetricLabel{"state", "pending"})
	s.metrics.RegisterGaugeLabels("exact_cache_prompt_artifacts", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.PromptArtifacts.Failed)
	}), MetricLabel{"state", "failed"})
	s.metrics.RegisterGaugeLabels("exact_cache_provider_protocol", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Providers.V0)
	}), MetricLabel{"version", "0"})
	s.metrics.RegisterGaugeLabels("exact_cache_provider_protocol", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Providers.V1)
	}), MetricLabel{"version", "1"})
	s.metrics.RegisterGaugeLabels("exact_cache_provider_protocol", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Providers.V2)
	}), MetricLabel{"version", "2"})
	s.metrics.RegisterGauge("exact_cache_v2_ready_models", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Providers.V2ReadyModels)
	}))
	s.metrics.RegisterGauge("exact_cache_holders", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Holders)
	}))
	s.metrics.RegisterGauge("exact_cache_attempts", gauge(func(s ExactCacheStatus) float64 {
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
		s.metrics.RegisterGaugeLabels("exact_cache_ssd_lifecycle", gauge(func(s ExactCacheStatus) float64 {
			return float64(lifecycle.value(s.Lifecycle))
		}), MetricLabel{"event", lifecycle.name})
	}
}

func (s *Server) exactCacheGaugeSnapshot() ExactCacheStatus {
	s.exactCacheGaugeMu.RLock()
	status := s.exactCacheGaugeStatus
	s.exactCacheGaugeMu.RUnlock()
	return status
}

func (s *Server) emitExactCacheDDGauges() {
	status := s.cachedExactCacheStatusSnapshot()
	s.ddGauge("exact_cache.routing_mode", 1, []string{"mode:" + status.RoutingMode})
	s.ddGauge("exact_cache.activation.percent", status.Activation.Percent, nil)
	s.ddGauge("exact_cache.activation.max_plan_qps", status.Activation.MaxPlanQPS, nil)
	s.ddGauge("exact_cache.activation.total", float64(status.Activation.Evaluated), []string{"outcome:evaluated"})
	s.ddGauge("exact_cache.activation.total", float64(status.Activation.SampledIn), []string{"outcome:sampled_in"})
	s.ddGauge("exact_cache.activation.total", float64(status.Activation.SampledOut), []string{"outcome:sampled_out"})
	s.ddGauge("exact_cache.activation.total", float64(status.Activation.RateLimited), []string{"outcome:rate_limited"})
	s.ddGauge("exact_cache.activation.total", float64(status.Activation.Admitted), []string{"outcome:admitted"})
	s.ddGauge("exact_cache.activation.total", float64(status.Activation.Planned), []string{"outcome:planned"})
	s.ddGauge("exact_cache.activation.total", float64(status.Activation.ColdOnly), []string{"outcome:cold_only"})
	s.ddGauge("exact_cache.activation.total", float64(status.Activation.PlanEmpty), []string{"outcome:plan_empty"})
	s.ddGauge("exact_cache.activation.total", float64(status.Activation.PlanFailed), []string{"outcome:plan_failed"})
	s.ddGauge("exact_cache.sidecar.enabled", boolGauge(status.Sidecar.Enabled), nil)
	s.ddGauge("exact_cache.sidecar.running", boolGauge(status.Sidecar.Running), nil)
	s.ddGauge("exact_cache.sidecar.ready", boolGauge(status.Sidecar.Ready), nil)
	s.ddGauge("exact_cache.sidecar.restarts", float64(status.Sidecar.Restarts), nil)
	restartReason := status.Sidecar.RestartReason
	if restartReason == "" {
		restartReason = "none"
	}
	s.ddGauge("exact_cache.sidecar.restart_reason", 1, []string{"reason:" + restartReason})
	s.ddGauge("exact_cache.sidecar.restart_suppressed", boolGauge(status.Sidecar.RestartSuppressed), nil)
	s.ddGauge("exact_cache.sidecar.child_generation", float64(status.Sidecar.ChildGeneration), nil)
	s.ddGauge("exact_cache.sidecar.consecutive_health_failures", float64(status.Sidecar.ConsecutiveHealthFailures), nil)
	s.ddGauge("exact_cache.sidecar.timeouts", float64(status.Sidecar.Timeouts), nil)
	s.ddGauge("exact_cache.sidecar.health_timeouts", float64(status.Sidecar.HealthTimeouts), nil)
	s.ddGauge("exact_cache.sidecar.preload_timeouts", float64(status.Sidecar.PreloadTimeouts), nil)
	s.ddGauge("exact_cache.sidecar.overloads", float64(status.Sidecar.Overloads), nil)
	s.ddGauge("exact_cache.sidecar.rss_bytes", float64(status.Sidecar.RSSBytes), nil)
	s.ddGauge("exact_cache.preload.ready", boolGauge(status.Preload.Ready), nil)
	s.ddGauge("exact_cache.preload.contracts", float64(status.Preload.ContractCount), nil)
	s.ddGauge("exact_cache.preload.runs", float64(status.Preload.Runs), nil)
	s.ddGauge("exact_cache.preload.failures", float64(status.Preload.Failures), nil)
	s.ddGauge("exact_cache.preload.results", float64(status.Preload.Warm), []string{"state:warm"})
	s.ddGauge("exact_cache.preload.results", float64(status.Preload.Cold), []string{"state:cold"})
	s.ddGauge("exact_cache.sidecar.plans", float64(status.Sidecar.Planner.Plans.Started), []string{"outcome:started"})
	s.ddGauge("exact_cache.sidecar.plans", float64(status.Sidecar.Planner.Plans.Succeeded), []string{"outcome:succeeded"})
	s.ddGauge("exact_cache.sidecar.plans", float64(status.Sidecar.Planner.Plans.ColdOnly), []string{"outcome:cold_only"})
	s.ddGauge("exact_cache.sidecar.plans", float64(status.Sidecar.Planner.Plans.Failed), []string{"outcome:failed"})
	s.ddGauge("exact_cache.sidecar.plans", float64(status.Sidecar.Planner.Plans.AtCapacity), []string{"outcome:overload"})
	s.ddGauge("exact_cache.sidecar.plans", float64(status.Sidecar.Planner.Plans.NotReady), []string{"outcome:not_ready"})
	s.ddGauge("exact_cache.sidecar.plans", float64(status.Sidecar.Planner.Plans.TimedOut), []string{"outcome:timeout"})
	s.ddGauge("exact_cache.sidecar.contract_loads", float64(status.Sidecar.Planner.ContractLoads.Cold), []string{"state:cold"})
	s.ddGauge("exact_cache.sidecar.contract_loads", float64(status.Sidecar.Planner.ContractLoads.Warm), []string{"state:warm"})
	s.ddGauge("exact_cache.sidecar.contract_loads", float64(status.Sidecar.Planner.ContractLoads.Waited), []string{"state:waited"})
	s.ddGauge("exact_cache.sidecar.contract_loads", float64(status.Sidecar.Planner.ContractLoads.Failed), []string{"state:failed"})
	s.ddGauge("exact_cache.prompt_artifacts", float64(status.PromptArtifacts.Ready), []string{"state:ready"})
	s.ddGauge("exact_cache.prompt_artifacts", float64(status.PromptArtifacts.Pending), []string{"state:pending"})
	s.ddGauge("exact_cache.prompt_artifacts", float64(status.PromptArtifacts.Failed), []string{"state:failed"})
	s.ddGauge("exact_cache.provider_protocol", float64(status.Providers.V0), []string{"version:0"})
	s.ddGauge("exact_cache.provider_protocol", float64(status.Providers.V1), []string{"version:1"})
	s.ddGauge("exact_cache.provider_protocol", float64(status.Providers.V2), []string{"version:2"})
	s.ddGauge("exact_cache.v2_ready_models", float64(status.Providers.V2ReadyModels), nil)
	s.ddGauge("exact_cache.holders", float64(status.Holders), nil)
	s.ddGauge("exact_cache.attempts", float64(status.Attempts), nil)
	s.ddGauge("exact_cache.ssd_lifecycle", float64(status.Lifecycle.SSDLookups), []string{"event:lookup"})
	s.ddGauge("exact_cache.ssd_lifecycle", float64(status.Lifecycle.SSDHits), []string{"event:hit"})
	s.ddGauge("exact_cache.ssd_lifecycle", float64(status.Lifecycle.SSDMisses), []string{"event:miss"})
	s.ddGauge("exact_cache.ssd_lifecycle", float64(status.Lifecycle.SSDDonations), []string{"event:donation"})
}

func boolGauge(value bool) float64 {
	if value {
		return 1
	}
	return 0
}
