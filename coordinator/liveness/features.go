package liveness

import (
	"context"
	"encoding/json"
	"log/slog"
	"math"
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Feature rollup defaults — tunable via env in cmd/coordinator/main.go.
const (
	defaultFeatureInterval   = 5 * time.Minute
	defaultFeatureWindowDays = 14
)

// DefaultFeatureInterval is the default cadence of feature rollup runs.
func DefaultFeatureInterval() time.Duration { return defaultFeatureInterval }

// DefaultFeatureWindowDays is the default window the rollup considers when
// computing per-provider behavioral features.
func DefaultFeatureWindowDays() int { return defaultFeatureWindowDays }

// FeaturesConfig parameterizes the rollup worker.
type FeaturesConfig struct {
	Interval   time.Duration
	WindowDays int
}

func (c FeaturesConfig) withDefaults() FeaturesConfig {
	if c.Interval <= 0 {
		c.Interval = defaultFeatureInterval
	}
	if c.WindowDays <= 0 {
		c.WindowDays = defaultFeatureWindowDays
	}
	return c
}

// FeaturesQuery is the subset of store.Store the rollup needs. Decoupled
// from the store package so test fakes can implement just these methods.
type FeaturesQuery interface {
	ListSessionsSince(ctx context.Context, since time.Time) ([]store.SessionRow, error)
	UpsertReliabilityFeatures(ctx context.Context, row store.ReliabilityFeatures) error
}

// StartFeaturesLoop runs the rollup periodically. Like the retention loop,
// it runs once eagerly on boot, then on cfg.Interval.
//
// `count` is the metrics callback (nil-safe). Counters emitted:
//   - "liveness_features_runs_total"     incremented per scheduled run
//   - "liveness_features_providers_total" incremented by # of providers updated per run
//   - "liveness_features_errors_total"   incremented on DB error
func StartFeaturesLoop(ctx context.Context, q FeaturesQuery, logger *slog.Logger, count CounterFn, cfg FeaturesConfig) {
	cfg = cfg.withDefaults()
	if logger == nil {
		logger = slog.Default()
	}
	logger = logger.With("component", "liveness.features")

	saferun.Go(logger, "liveness.featuresLoop", func() {
		runFeatures(ctx, q, logger, count, cfg)

		ticker := time.NewTicker(cfg.Interval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				runFeatures(ctx, q, logger, count, cfg)
			}
		}
	})
}

func runFeatures(ctx context.Context, q FeaturesQuery, logger *slog.Logger, count CounterFn, cfg FeaturesConfig) {
	if count != nil {
		count("liveness_features_runs_total", 1)
	}

	window := time.Duration(cfg.WindowDays) * 24 * time.Hour
	now := time.Now()
	since := now.Add(-window)

	sessions, err := q.ListSessionsSince(ctx, since)
	if err != nil {
		if count != nil {
			count("liveness_features_errors_total", 1)
		}
		logger.Warn("list sessions failed", "error", err)
		return
	}

	// Bucket by provider.
	byProvider := make(map[string][]store.SessionRow, 128)
	for _, s := range sessions {
		byProvider[s.ProviderID] = append(byProvider[s.ProviderID], s)
	}

	updated := 0
	for providerID, rows := range byProvider {
		features := computeFeatures(providerID, rows, since, now, cfg.WindowDays)
		if err := q.UpsertReliabilityFeatures(ctx, features); err != nil {
			if count != nil {
				count("liveness_features_errors_total", 1)
			}
			logger.Warn("upsert features failed",
				"provider_id", providerID,
				"error", err)
			continue
		}
		updated++
	}
	if count != nil && updated > 0 {
		count("liveness_features_providers_total", int64(updated))
	}
	if updated > 0 {
		logger.Info("features rollup complete",
			"providers", updated,
			"window_days", cfg.WindowDays)
	}
}

// computeFeatures derives one ReliabilityFeatures row from a provider's
// session history within [since, now]. Open sessions (DisconnectedAt zero)
// are treated as if they end at `now`.
//
// The math here is intentionally simple — anything fancier (real Kaplan-Meier
// survival curves, weekday vs weekend disaggregation) is v2.
func computeFeatures(providerID string, rows []store.SessionRow, since, now time.Time, windowDays int) store.ReliabilityFeatures {
	windowSeconds := int64(now.Sub(since).Seconds())

	var (
		uptimeSeconds  int64
		durations      = make([]int64, 0, len(rows))
		hourlyOnline   [168]int64 // hour_of_week → seconds online in that bucket
		discReasons    = make(map[string]int, 4)
		stays4h        int
		stays8h        int
		lastDisconnect time.Time
		lastClosedDur  int64
	)

	for _, s := range rows {
		// Clip to window.
		start := s.ConnectedAt
		if start.Before(since) {
			start = since
		}
		end := s.DisconnectedAt
		if end.IsZero() || end.After(now) {
			end = now
		}
		if !end.After(start) {
			continue
		}
		dur := int64(end.Sub(start).Seconds())
		uptimeSeconds += dur
		durations = append(durations, dur)

		// Hour-of-week buckets: walk by hour from start to end, charge each
		// bucket the fraction of an hour that overlaps. Bounded loop: ≤ 168
		// per session per week, with at most 168×N sessions to total in a
		// 14-day window. Cheap enough.
		for t := start; t.Before(end); {
			next := t.Truncate(time.Hour).Add(time.Hour)
			if next.After(end) {
				next = end
			}
			bucket := int(t.Weekday())*24 + t.Hour()
			hourlyOnline[bucket] += int64(next.Sub(t).Seconds())
			t = next
		}

		// Conditional stays-N stats: count UNCLIPPED session duration. We
		// want "if they came online, did they stay ≥ 4h" — clipping at the
		// window edge would artificially shorten long sessions started
		// before the window.
		rawEnd := s.DisconnectedAt
		if rawEnd.IsZero() || rawEnd.After(now) {
			rawEnd = now
		}
		rawStart := s.ConnectedAt
		rawDur := rawEnd.Sub(rawStart)
		if rawDur >= 4*time.Hour {
			stays4h++
		}
		if rawDur >= 8*time.Hour {
			stays8h++
		}

		// Disconnect reasons: only count CLOSED sessions.
		if !s.DisconnectedAt.IsZero() {
			reason := s.DisconnectReason
			if reason == "" {
				reason = "unspecified"
			}
			discReasons[reason]++
			if s.DisconnectedAt.After(lastDisconnect) {
				lastDisconnect = s.DisconnectedAt
				lastClosedDur = int64(s.DisconnectedAt.Sub(s.ConnectedAt).Seconds())
			}
		}
	}

	uptimePct := 0.0
	if windowSeconds > 0 {
		uptimePct = float64(uptimeSeconds) / float64(windowSeconds)
		if uptimePct > 1 {
			uptimePct = 1
		}
	}

	// Hourly availability matrix as fractions of an hour: divide by 3600.
	// Stored as a flat 168-element array; consumers reshape to 7×24 if they
	// want a matrix.
	hourly := make([]float64, 168)
	for i, sec := range hourlyOnline {
		// Each hour-of-week appears `windowDays/7` times in a windowDays
		// window. Normalize so a perfectly-online provider gets 1.0 in
		// every bucket.
		occurrences := float64(windowDays) / 7.0
		if occurrences <= 0 {
			occurrences = 1
		}
		hourly[i] = math.Min(1.0, float64(sec)/(3600.0*occurrences))
	}

	hourlyJSON, _ := json.Marshal(hourly)
	disconnectJSON, _ := json.Marshal(discReasons)

	// MTBF: mean gap between consecutive CLOSED sessions, in seconds.
	// If we have <2 closed sessions, MTBF is meaningless → 0.
	var (
		closed   = make([]store.SessionRow, 0, len(rows))
		mtbfSecs int64
	)
	for _, s := range rows {
		if !s.DisconnectedAt.IsZero() {
			closed = append(closed, s)
		}
	}
	sort.Slice(closed, func(i, j int) bool {
		return closed[i].ConnectedAt.Before(closed[j].ConnectedAt)
	})
	if len(closed) >= 2 {
		var totalGap int64
		gaps := 0
		for i := 1; i < len(closed); i++ {
			gap := closed[i].ConnectedAt.Sub(closed[i-1].DisconnectedAt)
			if gap > 0 {
				totalGap += int64(gap.Seconds())
				gaps++
			}
		}
		if gaps > 0 {
			mtbfSecs = totalGap / int64(gaps)
		}
	}

	sort.Slice(durations, func(i, j int) bool { return durations[i] < durations[j] })
	p10 := percentile(durations, 0.10)
	p50 := percentile(durations, 0.50)
	p90 := percentile(durations, 0.90)

	pStays4h := 0.0
	pStays8h := 0.0
	if len(rows) > 0 {
		pStays4h = float64(stays4h) / float64(len(rows))
		pStays8h = float64(stays8h) / float64(len(rows))
	}

	score := computeLivenessScore(uptimePct, pStays4h, pStays8h, mtbfSecs, lastDisconnect, now)

	return store.ReliabilityFeatures{
		ProviderID:                 providerID,
		WindowDays:                 windowDays,
		UptimePct:                  uptimePct,
		SessionsCount:              len(rows),
		MTBFSeconds:                mtbfSecs,
		MedianSessionSeconds:       p50,
		P10SessionSeconds:          p10,
		P90SessionSeconds:          p90,
		HourlyAvailability:         hourlyJSON,
		DisconnectReasons:          disconnectJSON,
		PStays4h:                   pStays4h,
		PStays8h:                   pStays8h,
		LastDisconnectAt:           lastDisconnect,
		LastSessionDurationSeconds: lastClosedDur,
		LivenessScore:              score,
	}
}

// Liveness-score weights. Tuned for "is this provider suitable for a
// long-running job?" — uptime dominates, but session stickiness (PStays4h)
// gets meaningful weight and MTBF rewards providers with infrequent failures.
// The positive weights sum to 1.0 so a perfectly reliable, non-recent-disconnect
// provider scores 1.0; recency is a [0, recencyWeight] subtractive penalty.
const (
	scoreWeightUptime  = 0.35
	scoreWeightStays4h = 0.25
	scoreWeightStays8h = 0.15
	scoreWeightMTBF    = 0.25
	scoreWeightRecency = 0.10

	// Sigmoid parameters for MTBF: target 4h, scale 1h.
	// sigmoid((mtbf - target) / scale) — at 4h: 0.5, at 5h: ~0.73, at 8h: ~0.98.
	scoreMTBFTargetSec = 4 * 3600
	scoreMTBFScaleSec  = 3600

	// Recency penalty decays linearly from 1.0 at t=0 to 0 at 24h.
	scoreRecencyWindowSec = 24 * 3600
)

// computeLivenessScore collapses the per-provider reliability features into a
// single number in [0, 1]. Higher = more reliable for long-running jobs.
// Formula (see scoreWeight* constants above):
//
//	score = 0.35·uptime + 0.25·p_stays_4h + 0.15·p_stays_8h
//	      + 0.25·sigmoid((mtbf - 4h) / 1h)
//	      - 0.10·recency_penalty(last_disconnect)
//
// All inputs are pre-clamped to their natural ranges by callers, so the
// output here is guaranteed in [-0.10, 1.00]. We clamp to [0, 1] at the end
// to keep the public contract clean.
func computeLivenessScore(uptimePct, pStays4h, pStays8h float64, mtbfSecs int64, lastDisconnect, now time.Time) float64 {
	mtbfTerm := sigmoid(float64(mtbfSecs-int64(scoreMTBFTargetSec)) / float64(scoreMTBFScaleSec))

	var recencyPenalty float64
	if !lastDisconnect.IsZero() {
		ageSec := now.Sub(lastDisconnect).Seconds()
		if ageSec < 0 {
			ageSec = 0
		}
		if ageSec < scoreRecencyWindowSec {
			recencyPenalty = 1 - ageSec/float64(scoreRecencyWindowSec)
		}
	}

	score := scoreWeightUptime*uptimePct +
		scoreWeightStays4h*pStays4h +
		scoreWeightStays8h*pStays8h +
		scoreWeightMTBF*mtbfTerm -
		scoreWeightRecency*recencyPenalty

	if score < 0 {
		return 0
	}
	if score > 1 {
		return 1
	}
	return score
}

func sigmoid(x float64) float64 {
	return 1.0 / (1.0 + math.Exp(-x))
}

func percentile(sorted []int64, p float64) int64 {
	if len(sorted) == 0 {
		return 0
	}
	idx := int(math.Floor(p * float64(len(sorted)-1)))
	if idx < 0 {
		idx = 0
	}
	if idx >= len(sorted) {
		idx = len(sorted) - 1
	}
	return sorted[idx]
}
