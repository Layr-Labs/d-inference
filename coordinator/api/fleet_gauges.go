package api

import (
	"context"
	"sync"
	"time"
)

// Only the immediately preceding set is retained. A departing model gets one
// zero sample, then leaves the tracker rather than accumulating forever.
type queueGaugeState struct {
	mu     sync.Mutex
	models map[string]struct{}
}

func (state *queueGaugeState) reconcile(current map[string]struct{}) []string {
	state.mu.Lock()
	defer state.mu.Unlock()
	var retired []string
	for model := range state.models {
		if _, present := current[model]; !present {
			retired = append(retired, model)
		}
	}
	state.models = current
	return retired
}

// Per-model queue gauges, pushed from StartDDGaugeLoop.
//
// request_queue.depth is a single fleet-wide number and queue_wait_ms is
// sampled only at request terminals, so a model whose queue is backing up is
// invisible until its requests time out. These gauges close that gap.
const (
	// metricQueueDepthByModel is a distinct name (not request_queue.depth with a
	// model tag): the untagged fleet-wide gauge already exists under that name
	// and a mixed tag set would double-count in sum:/avg: queries.
	metricQueueDepthByModel = "request_queue.depth_by_model"
	metricQueueOldestAgeMs  = "request_queue.oldest_age_ms"
)

// emitPerModelQueueGauges pushes request_queue.depth_by_model{model} and
// request_queue.oldest_age_ms{model}. servedModels is the live per-model
// provider snapshot the gauge loop already computed; every served model gets a
// point (0 when nothing is queued) so the series does not go blank between
// queueing episodes, and models that are queued without a live provider are
// still reported.
func (s *Server) emitPerModelQueueGauges(servedModels map[string]int64) {
	if s == nil || s.dd == nil || s.registry == nil {
		return
	}
	q := s.registry.Queue()
	if q == nil {
		return
	}
	models := make(map[string]struct{}, len(servedModels)+4)
	for model := range servedModels {
		models[model] = struct{}{}
	}
	for _, model := range q.QueuedModels() {
		models[model] = struct{}{}
	}
	retired := s.queueGauges.reconcile(models)
	for model := range models {
		depth, oldestAge := q.QueueStats(model)
		tags := []string{"model:" + model}
		s.ddGauge(metricQueueDepthByModel, float64(depth), tags)
		s.ddGauge(metricQueueOldestAgeMs, float64(oldestAge.Milliseconds()), tags)
	}
	for _, model := range retired {
		tags := []string{"model:" + model}
		s.ddGauge(metricQueueDepthByModel, 0, tags)
		s.ddGauge(metricQueueOldestAgeMs, 0, tags)
	}
}

// registerDefaultGauges wires live-computed gauges (fleet size, etc.) into
// the metrics registry at construction time.
func (s *Server) registerDefaultGauges() {
	s.metrics.RegisterGauge("providers_online", func() float64 {
		return float64(s.registry.ProviderCount())
	})
	s.metrics.RegisterGauge("min_provider_version_set", func() float64 {
		if s.minProviderVersion != "" {
			return 1
		}
		return 0
	})
	s.registerExactCacheGauges()
}

// StartDDGaugeLoop periodically pushes gauge values to DogStatsD. Gauges
// are point-in-time values and must be pushed regularly (not on-demand like
// counters). Call as a goroutine; stops when ctx is cancelled.
func (s *Server) StartDDGaugeLoop(ctx context.Context) {
	if s.dd == nil {
		return
	}
	ticker := time.NewTicker(15 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.ddGauge("providers.online", float64(s.registry.OnlineCount()), nil)
			// APNs code-identity coverage — watch this climb during the grace
			// window before letting APNS_ENFORCE_AFTER pass.
			codeAttested, _ := s.registry.CodeAttestationCoverage()
			s.ddGauge("attestation.code_attested", float64(codeAttested), nil)
			enforced := 0.0
			if s.registry.CodeAttestationEnforced() {
				enforced = 1.0
			}
			s.ddGauge("attestation.code_enforced", enforced, nil)
			perModel := s.registry.ModelProviderSnapshot()
			for model, count := range perModel {
				s.ddGauge("providers.per_model", float64(count), []string{"model:" + model})
			}
			// Per-model queue depth/age (fleet_gauges.go).
			s.emitPerModelQueueGauges(perModel)
			for ver, count := range s.registry.ProviderCountByVersion() {
				s.ddGauge("providers.per_version", float64(count), []string{"version:" + ver})
			}
			// Trust-state cohort gauges — alert when self_signed/untrusted grows.
			for _, b := range s.registry.ProviderCountByTrustStatus() {
				s.ddGauge("providers.by_trust_status", float64(b.Count),
					[]string{"trust_level:" + b.TrustLevel, "status:" + b.Status})
			}
			// Stuck-cohort breakdown — distinguishes never-enrolled from
			// enrolled-but-SecurityInfo-timing-out so we know if the problem is
			// provider-side enrollment or APNs/MDM delivery.
			for reason, count := range s.registry.ProviderCountByMDMFailure() {
				s.ddGauge("providers.by_mdm_failure", float64(count), []string{"reason:" + reason})
			}
			if s.minProviderVersion != "" {
				s.ddGauge("coordinator.min_provider_version_set", 1, []string{"min_version:" + s.minProviderVersion})
			}
			if q := s.registry.Queue(); q != nil {
				s.ddGauge("request_queue.depth", float64(q.TotalSize()), nil)
			}
			s.emitExactCacheDDGauges()
			s.emitStoreCacheGauges()
			// Network utilization — demand/capacity across the warm-serving and
			// token-budget axes, plus a per-model breakdown.
			util := s.registry.NetworkUtilizationSnapshot()
			s.ddGauge("utilization.network", util.Utilization, nil)
			s.ddGauge("utilization.warm", util.WarmUtilization, nil)
			s.ddGauge("utilization.token_budget", util.TokenBudgetUtilization, nil)
			s.ddGauge("utilization.bottleneck", util.BottleneckUtilization, nil)
			s.ddGauge("capacity.tps", util.CapacityTPS, nil)
			s.ddGauge("capacity.demand_concurrency", util.DemandConcurrency, nil)
			s.ddGauge("capacity.serving_capacity", util.ServingCapacity, nil)
			s.ddGauge("capacity.spill_arrival_rate", util.SpillArrivalRate, nil)
			for _, m := range util.Models {
				s.ddGauge("utilization.model", m.Utilization, []string{"model:" + m.Model})
			}
		}
	}
}
