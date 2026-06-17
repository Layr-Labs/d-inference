package api

// Throughput anomaly detector — periodic fleet sweep + metric/log emission.
//
// This is the IO half of workstream W8 (docs/architecture/routing-v2.md §5). It
// periodically snapshots every provider's per-model observed decode TPS, groups
// the observations by (model, chip-class), and asks the pure evaluator in
// coordinator/registry/throughput_anomaly.go whether each bucket is decoding far
// below its active-param/hardware expectation. Buckets that are (e.g. a 4B-active
// MoE being read as if dense — the gemma case) get a Datadog counter, an
// in-process counter (visible at /v1/admin/metrics), and a Warn log.

import (
	"context"
	"os"
	"sort"
	"strconv"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
)

// throughputAnomalySweepInterval is how often the detector compares each
// (model, chip-class) bucket's observed decode to its expectation. The provider
// EWMA of observed_decode_tps needs time to populate after (re)connect, so this
// is deliberately coarse.
const throughputAnomalySweepInterval = 5 * time.Minute

// StartThroughputAnomalyDetector launches the periodic throughput-anomaly sweep
// as a panic-safe goroutine. It stops when ctx is cancelled. Call once from
// main. The sweep is read-only with respect to the registry.
func (s *Server) StartThroughputAnomalyDetector(ctx context.Context) {
	cfg := throughputAnomalyConfigFromEnv()
	interval := throughputAnomalySweepInterval
	if v := os.Getenv("EIGENINFERENCE_THROUGHPUT_ANOMALY_INTERVAL"); v != "" {
		if d, err := time.ParseDuration(v); err == nil && d > 0 {
			interval = d
		} else {
			s.logger.Warn("invalid EIGENINFERENCE_THROUGHPUT_ANOMALY_INTERVAL; using default", "value", v)
		}
	}
	s.logger.Info("throughput anomaly detector started",
		"interval", interval.String(),
		"ratio_threshold", cfg.RatioThreshold,
		"min_samples", cfg.MinSamples,
		"efficiency", cfg.Efficiency,
	)
	saferun.Go(s.logger, "api.throughputAnomalyDetector", func() {
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				s.sweepThroughputAnomalies(cfg)
			}
		}
	})
}

// throughputAnomalyConfigFromEnv builds the detector config from the registry
// defaults, applying optional env overrides. Reading env here (rather than in
// main) keeps the detector self-contained.
func throughputAnomalyConfigFromEnv() registry.ThroughputAnomalyConfig {
	cfg := registry.DefaultThroughputAnomalyConfig()
	if v := os.Getenv("EIGENINFERENCE_THROUGHPUT_ANOMALY_RATIO"); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil && f > 0 {
			cfg.RatioThreshold = f
		}
	}
	if v := os.Getenv("EIGENINFERENCE_THROUGHPUT_ANOMALY_MIN_SAMPLES"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			cfg.MinSamples = n
		}
	}
	if v := os.Getenv("EIGENINFERENCE_THROUGHPUT_ANOMALY_EFFICIENCY"); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil && f > 0 {
			cfg.Efficiency = f
		}
	}
	return cfg
}

// throughputBucket accumulates observed decode TPS (and reported bandwidths) for
// one (model, chip-class) group across the fleet.
type throughputBucket struct {
	model      string
	chipClass  string
	tpsSamples []float64
	bandwidths []float64
}

// sweepThroughputAnomalies snapshots the fleet, groups observed decode TPS by
// (model, chip-class), evaluates each bucket, and emits on anomalies.
func (s *Server) sweepThroughputAnomalies(cfg registry.ThroughputAnomalyConfig) {
	for _, b := range s.collectThroughputBuckets() {
		res := registry.EvaluateThroughputAnomaly(registry.ThroughputAnomalyInput{
			Model:         b.model,
			ChipClass:     b.chipClass,
			BandwidthGBps: medianFloat(b.bandwidths), // 0 ⇒ evaluator uses the chip table
			ObservedTPS:   medianFloat(b.tpsSamples),
			Samples:       len(b.tpsSamples),
		}, cfg)
		if res.Anomalous {
			s.emitThroughputAnomaly(res)
		}
	}
}

// collectThroughputBuckets reads every provider's per-model observed decode TPS
// under the provider lock, copies the scalars out, and groups them by
// (model, chip-class). All registry/provider locks are released before the
// caller evaluates or emits.
func (s *Server) collectThroughputBuckets() map[string]*throughputBucket {
	buckets := make(map[string]*throughputBucket)
	s.registry.ForEachProvider(func(p *registry.Provider) {
		p.Mu().Lock()
		hw := p.Hardware
		var slots []protocol.BackendSlotCapacity
		if p.BackendCapacity != nil {
			slots = append(slots, p.BackendCapacity.Slots...)
		}
		p.Mu().Unlock()

		chipClass := registry.ResolveChipClass(hw.ChipFamily, hw.ChipTier, hw.ChipName)
		if chipClass == "" {
			return
		}
		for _, slot := range slots {
			if slot.Model == "" || slot.ObservedDecodeTPS <= 0 {
				continue
			}
			// Only sample near-solo slots (batch <= 1). The expected-decode bound
			// is a batch≈1 memory-bandwidth ceiling; comparing it against a
			// batch-degraded observed rate would false-flag a healthy model under
			// load. Skipping loaded slots keeps the comparison apples-to-apples.
			if slot.NumRunning > 1 {
				continue
			}
			key := slot.Model + "\x00" + chipClass
			b := buckets[key]
			if b == nil {
				b = &throughputBucket{model: slot.Model, chipClass: chipClass}
				buckets[key] = b
			}
			b.tpsSamples = append(b.tpsSamples, slot.ObservedDecodeTPS)
			if hw.MemoryBandwidthGBs > 0 {
				b.bandwidths = append(b.bandwidths, hw.MemoryBandwidthGBs)
			}
		}
	})
	return buckets
}

// emitThroughputAnomaly records an anomaly to Datadog, the in-process metrics
// registry (visible at /v1/admin/metrics), and the log. The metric is
// routing.throughput_anomaly, tagged {model, chip_family}.
func (s *Server) emitThroughputAnomaly(res registry.ThroughputAnomalyResult) {
	s.ddIncr("routing.throughput_anomaly", []string{
		"model:" + res.Model,
		"chip_family:" + res.ChipClass,
	})
	if s.metrics != nil {
		s.metrics.IncCounter("routing.throughput_anomaly",
			MetricLabel{Name: "model", Value: res.Model},
			MetricLabel{Name: "chip_family", Value: res.ChipClass},
		)
	}
	s.logger.Warn("throughput anomaly: model decoding far below active-param class",
		"model", res.Model,
		"chip_family", res.ChipClass,
		"observed_decode_tps", res.ObservedTPS,
		"expected_decode_tps", res.ExpectedTPS,
		"ratio", res.Ratio,
		"active_params", res.ActiveParams,
		"bandwidth_gbps", res.BandwidthGBps,
		"samples", res.Samples,
	)
}

// medianFloat returns the median of xs, or 0 for an empty slice.
func medianFloat(xs []float64) float64 {
	if len(xs) == 0 {
		return 0
	}
	sorted := append([]float64(nil), xs...)
	sort.Float64s(sorted)
	mid := len(sorted) / 2
	if len(sorted)%2 == 0 {
		return (sorted[mid-1] + sorted[mid]) / 2
	}
	return sorted[mid]
}
