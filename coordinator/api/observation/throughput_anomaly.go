package observation

// Throughput anomaly detector — periodic fleet sweep + metric/log emission.
//
// This is the IO half of workstream W8 (docs/design/routing-v2.md §5). It
// periodically snapshots every provider's per-model observed decode TPS, groups
// the observations by (model, chip-class), and asks the pure evaluator in
// coordinator/registry/throughput_anomaly.go whether each bucket is decoding far
// below its active-param/hardware expectation. Buckets that are (e.g. a 4B-active
// MoE being read as if dense — the gemma case) get a Datadog counter, an
// in-process counter (visible at /v1/admin/metrics), and a Warn log.

import (
	"context"
	"os"
	"strconv"
	"time"

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
func (s *Owner) StartThroughputAnomalyDetector(ctx context.Context) {
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
				s.throughputDetector.Sweep(cfg)
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
