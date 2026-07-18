package api

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

type ExactCacheStatus struct {
	RoutingMode     string                             `json:"routing_mode"`
	Sidecar         ExactCacheSidecarStatus            `json:"sidecar"`
	PromptArtifacts ExactCachePromptArtifactStatus     `json:"prompt_artifacts"`
	Providers       registry.PrefixCacheProtocolStatus `json:"providers"`
	Holders         int                                `json:"holders"`
	Attempts        int                                `json:"attempts"`
}

type ExactCacheSidecarStatus struct {
	Enabled   bool   `json:"enabled"`
	Running   bool   `json:"running"`
	Ready     bool   `json:"ready"`
	Restarts  uint64 `json:"restarts"`
	Timeouts  uint64 `json:"timeouts"`
	Overloads uint64 `json:"overloads"`
	RSSBytes  uint64 `json:"rss_bytes"`
}

type ExactCachePromptArtifactStatus struct {
	Ready   int `json:"ready"`
	Pending int `json:"pending"`
	Failed  int `json:"failed"`
}

func (s *Server) SetPromptSupervisor(supervisor *promptcontract.Supervisor) {
	s.promptSupervisor = supervisor
}

// ExactCacheStatusSnapshot exposes aggregate optimizer health only. It never
// includes models, providers, accounts, scopes, route keys, prompt material, or
// token-chain hashes.
func (s *Server) ExactCacheStatusSnapshot() ExactCacheStatus {
	routingMode := s.registry.CacheRoutingConfigSnapshot().Mode
	if routingMode != registry.CacheRoutingOn {
		routingMode = registry.CacheRoutingOff
	}
	status := ExactCacheStatus{
		RoutingMode: routingMode,
		Providers:   s.registry.PrefixCacheProtocolStatus(),
	}
	status.Holders, status.Attempts = s.registry.CacheRoutingStateCounts()
	if s.promptSupervisor != nil {
		supervisor := s.promptSupervisor.Status()
		status.Sidecar.Enabled = supervisor.Enabled
		status.Sidecar.Running = supervisor.Running
		status.Sidecar.Ready = supervisor.Ready
		status.Sidecar.Restarts = supervisor.Restarts
		status.Sidecar.RSSBytes = supervisor.RSSBytes
	}
	if s.promptContract != nil {
		client := s.promptContract.Stats()
		status.Sidecar.Timeouts = client.Timeouts
		status.Sidecar.Overloads = client.Overloads
	}
	if s.promptArtifacts != nil {
		counts := s.promptArtifacts.Counts()
		status.PromptArtifacts = ExactCachePromptArtifactStatus{
			Ready: counts.Ready, Pending: counts.Pending, Failed: counts.Failed,
		}
	}
	return status
}

func (s *Server) handleExactCacheStatus(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, s.ExactCacheStatusSnapshot())
}

func (s *Server) registerExactCacheGauges() {
	gauge := func(value func(ExactCacheStatus) float64) GaugeFunc {
		return func() float64 { return value(s.ExactCacheStatusSnapshot()) }
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
	s.metrics.RegisterGauge("exact_cache_sidecar_running", gauge(func(s ExactCacheStatus) float64 {
		return boolGauge(s.Sidecar.Running)
	}))
	s.metrics.RegisterGauge("exact_cache_sidecar_ready", gauge(func(s ExactCacheStatus) float64 {
		return boolGauge(s.Sidecar.Ready)
	}))
	s.metrics.RegisterGauge("exact_cache_sidecar_restarts", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Sidecar.Restarts)
	}))
	s.metrics.RegisterGauge("exact_cache_sidecar_timeouts", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Sidecar.Timeouts)
	}))
	s.metrics.RegisterGauge("exact_cache_sidecar_overloads", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Sidecar.Overloads)
	}))
	s.metrics.RegisterGauge("exact_cache_sidecar_rss_bytes", gauge(func(s ExactCacheStatus) float64 {
		return float64(s.Sidecar.RSSBytes)
	}))
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
}

func (s *Server) emitExactCacheDDGauges() {
	status := s.ExactCacheStatusSnapshot()
	s.ddGauge("exact_cache.routing_mode", 1, []string{"mode:" + status.RoutingMode})
	s.ddGauge("exact_cache.sidecar.enabled", boolGauge(status.Sidecar.Enabled), nil)
	s.ddGauge("exact_cache.sidecar.running", boolGauge(status.Sidecar.Running), nil)
	s.ddGauge("exact_cache.sidecar.ready", boolGauge(status.Sidecar.Ready), nil)
	s.ddGauge("exact_cache.sidecar.restarts", float64(status.Sidecar.Restarts), nil)
	s.ddGauge("exact_cache.sidecar.timeouts", float64(status.Sidecar.Timeouts), nil)
	s.ddGauge("exact_cache.sidecar.overloads", float64(status.Sidecar.Overloads), nil)
	s.ddGauge("exact_cache.sidecar.rss_bytes", float64(status.Sidecar.RSSBytes), nil)
	s.ddGauge("exact_cache.prompt_artifacts", float64(status.PromptArtifacts.Ready), []string{"state:ready"})
	s.ddGauge("exact_cache.prompt_artifacts", float64(status.PromptArtifacts.Pending), []string{"state:pending"})
	s.ddGauge("exact_cache.prompt_artifacts", float64(status.PromptArtifacts.Failed), []string{"state:failed"})
	s.ddGauge("exact_cache.provider_protocol", float64(status.Providers.V0), []string{"version:0"})
	s.ddGauge("exact_cache.provider_protocol", float64(status.Providers.V1), []string{"version:1"})
	s.ddGauge("exact_cache.provider_protocol", float64(status.Providers.V2), []string{"version:2"})
	s.ddGauge("exact_cache.v2_ready_models", float64(status.Providers.V2ReadyModels), nil)
	s.ddGauge("exact_cache.holders", float64(status.Holders), nil)
	s.ddGauge("exact_cache.attempts", float64(status.Attempts), nil)
}

func boolGauge(value bool) float64 {
	if value {
		return 1
	}
	return 0
}
