package api

import (
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

const exactCacheStatusCacheTTL = time.Second

type ExactCacheStatus struct {
	RoutingMode     string                                `json:"routing_mode"`
	Activation      registry.CacheRoutingActivationStatus `json:"activation"`
	Sidecar         ExactCacheSidecarStatus               `json:"sidecar"`
	Preload         ExactCachePreloadStatus               `json:"preload"`
	PromptArtifacts ExactCachePromptArtifactStatus        `json:"prompt_artifacts"`
	Providers       registry.PrefixCacheProtocolStatus    `json:"providers"`
	Lifecycle       registry.CacheRoutingLifecycleStatus  `json:"lifecycle"`
	Holders         int                                   `json:"holders"`
	Attempts        int                                   `json:"attempts"`
}

type ExactCacheSidecarStatus struct {
	Enabled                   bool                          `json:"enabled"`
	Running                   bool                          `json:"running"`
	Ready                     bool                          `json:"ready"`
	Restarts                  uint64                        `json:"restarts"`
	RestartReason             string                        `json:"restart_reason,omitempty"`
	RestartSuppressed         bool                          `json:"restart_suppressed"`
	ChildGeneration           uint64                        `json:"child_generation"`
	ConsecutiveHealthFailures int                           `json:"consecutive_health_failures"`
	Timeouts                  uint64                        `json:"timeouts"`
	HealthTimeouts            uint64                        `json:"health_timeouts"`
	PreloadTimeouts           uint64                        `json:"preload_timeouts"`
	Overloads                 uint64                        `json:"overloads"`
	RSSBytes                  uint64                        `json:"rss_bytes"`
	Planner                   promptcontract.SidecarMetrics `json:"planner"`
}

type ExactCachePreloadStatus struct {
	Ready             bool   `json:"ready"`
	CatalogGeneration uint64 `json:"catalog_generation"`
	ChildGeneration   uint64 `json:"child_generation"`
	ContractCount     int    `json:"contract_count"`
	Runs              uint64 `json:"runs"`
	Failures          uint64 `json:"failures"`
	Warm              uint64 `json:"warm"`
	Cold              uint64 `json:"cold"`
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
		Activation:  s.registry.CacheRoutingActivationStatus(),
		Providers:   s.registry.PrefixCacheProtocolStatus(),
		Lifecycle:   s.registry.CacheRoutingLifecycleStatus(),
	}
	status.Holders, status.Attempts = s.registry.CacheRoutingStateCounts()
	if s.promptSupervisor != nil {
		supervisor := s.promptSupervisor.Status()
		status.Sidecar.Enabled = supervisor.Enabled
		status.Sidecar.Running = supervisor.Running
		status.Sidecar.Ready = supervisor.Ready
		status.Sidecar.Restarts = supervisor.Restarts
		status.Sidecar.RestartReason = supervisor.RestartReason
		status.Sidecar.RestartSuppressed = !supervisor.RestartSuppressedUntil.IsZero()
		status.Sidecar.ChildGeneration = supervisor.ChildGeneration
		status.Sidecar.ConsecutiveHealthFailures = supervisor.ConsecutiveHealthFailures
		status.Sidecar.RSSBytes = supervisor.RSSBytes
	}
	if s.promptContract != nil {
		client := s.promptContract.Stats()
		status.Sidecar.Timeouts = client.Timeouts
		status.Sidecar.HealthTimeouts = client.HealthTimeouts
		status.Sidecar.PreloadTimeouts = client.PreloadTimeouts
		status.Sidecar.Overloads = client.Overloads
		status.Sidecar.Planner = s.promptContract.SidecarMetrics()
	}
	if s.promptPreloader != nil {
		preload := s.promptPreloader.Status()
		status.Preload = ExactCachePreloadStatus{
			Ready: preload.Ready, CatalogGeneration: preload.CatalogGeneration,
			ChildGeneration: preload.ChildGeneration, ContractCount: preload.ContractCount,
			Runs: preload.Runs, Failures: preload.Failures, Warm: preload.Warm, Cold: preload.Cold,
		}
	}
	if s.promptArtifacts != nil {
		counts := s.promptArtifacts.Counts()
		status.PromptArtifacts = ExactCachePromptArtifactStatus{
			Ready: counts.Ready, Pending: counts.Pending, Failed: counts.Failed,
		}
	}
	return status
}

// cachedExactCacheStatusSnapshot bounds the fleet-wide provider scan used by
// the public rollout surface. Concurrent scrapes share one short-lived
// aggregate, so observability cannot repeatedly contend with routing and
// heartbeat locks.
func (s *Server) cachedExactCacheStatusSnapshot() ExactCacheStatus {
	s.exactCacheStatusCacheMu.Lock()
	defer s.exactCacheStatusCacheMu.Unlock()
	now := time.Now()
	if now.Before(s.exactCacheStatusCacheExpires) {
		return s.exactCacheStatusCache
	}
	status := s.ExactCacheStatusSnapshot()
	s.exactCacheStatusCache = status
	s.exactCacheStatusCacheExpires = time.Now().Add(exactCacheStatusCacheTTL)
	return status
}

func (s *Server) handleExactCacheStatus(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, s.cachedExactCacheStatusSnapshot())
}
