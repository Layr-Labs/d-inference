package observation

import (
	"context"
	"time"
)

// RegisterDefaultGauges wires live-computed fleet gauges into the metrics registry.
func (s *Owner) RegisterDefaultGauges() {
	s.Metrics().RegisterGauge("providers_online", func() float64 {
		return float64(s.registry.ProviderCount())
	})
	s.Metrics().RegisterGauge("min_provider_version_set", func() float64 {
		if s.hooks.MinProviderVersion != nil && s.hooks.MinProviderVersion() != "" {
			return 1
		}
		return 0
	})
}

// StartDDGaugeLoop periodically pushes gauge values to DogStatsD. Gauges
// are point-in-time values and must be pushed regularly (not on-demand like
// counters). Call as a goroutine; stops when ctx is cancelled.
func (s *Owner) StartDDGaugeLoop(ctx context.Context) {
	if s.Datadog() == nil {
		return
	}
	ticker := time.NewTicker(15 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.Gauge("providers.online", float64(s.registry.OnlineCount()), nil)
			// APNs code-identity coverage during the enforcement grace window.
			codeAttested, _ := s.registry.CodeAttestationCoverage()
			s.Gauge("attestation.code_attested", float64(codeAttested), nil)
			enforced := 0.0
			if s.registry.CodeAttestationEnforced() {
				enforced = 1.0
			}
			s.Gauge("attestation.code_enforced", enforced, nil)
			perModel := s.registry.ModelProviderSnapshot()
			for model, count := range perModel {
				s.Gauge("providers.per_model", float64(count), []string{"model:" + model})
			}
			s.emitPerModelQueueGauges(perModel)
			for ver, count := range s.registry.ProviderCountByVersion() {
				s.Gauge("providers.per_version", float64(count), []string{"version:" + ver})
			}
			// Alert when the self-signed/untrusted cohort grows.
			for _, b := range s.registry.ProviderCountByTrustStatus() {
				s.Gauge("providers.by_trust_status", float64(b.Count),
					[]string{"trust_level:" + b.TrustLevel, "status:" + b.Status})
			}
			// Distinguish never-enrolled from SecurityInfo timeout cohorts.
			for reason, count := range s.registry.ProviderCountByMDMFailure() {
				s.Gauge("providers.by_mdm_failure", float64(count), []string{"reason:" + reason})
			}
			if s.hooks.MinProviderVersion != nil && s.hooks.MinProviderVersion() != "" {
				s.Gauge("coordinator.min_provider_version_set", 1, []string{"min_version:" + s.hooks.MinProviderVersion()})
			}
			if q := s.registry.Queue(); q != nil {
				s.Gauge("request_queue.depth", float64(q.TotalSize()), nil)
			}
			if s.hooks.EmitExactCacheDDGauges != nil {
				s.hooks.EmitExactCacheDDGauges()
			}
			s.emitStoreCacheGauges()
			// Demand/capacity across warm-serving and token-budget axes.
			util := s.registry.NetworkUtilizationSnapshot()
			s.Gauge("utilization.network", util.Utilization, nil)
			s.Gauge("utilization.warm", util.WarmUtilization, nil)
			s.Gauge("utilization.token_budget", util.TokenBudgetUtilization, nil)
			s.Gauge("utilization.bottleneck", util.BottleneckUtilization, nil)
			s.Gauge("capacity.tps", util.CapacityTPS, nil)
			s.Gauge("capacity.demand_concurrency", util.DemandConcurrency, nil)
			s.Gauge("capacity.serving_capacity", util.ServingCapacity, nil)
			s.Gauge("capacity.spill_arrival_rate", util.SpillArrivalRate, nil)
			for _, m := range util.Models {
				s.Gauge("utilization.model", m.Utilization, []string{"model:" + m.Model})
			}
		}
	}
}
