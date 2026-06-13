package registry

import (
	"context"
	"math"
	"sync"
	"time"
)

// HistoricalDemandSource returns historical request-rate baselines for a model.
// A nil or no-op implementation is valid; the forecaster falls back to recent
// demand and queue signals.
type HistoricalDemandSource interface {
	// HistoricalDemand returns the expected requests-per-second for the model
	// over the given look-ahead window, based on comparable past intervals.
	HistoricalDemand(ctx context.Context, model string, window time.Duration) (float64, error)
}

// noopHistoricalDemandSource always returns zero demand.
type noopHistoricalDemandSource struct{}

func (noopHistoricalDemandSource) HistoricalDemand(context.Context, string, time.Duration) (float64, error) {
	return 0, nil
}

// DemandForecast is the output of the forecaster for one model.
type DemandForecast struct {
	Model string
	// RequestsPerSecond is the predicted demand over the forecast horizon.
	RequestsPerSecond float64
	// RecentRPS is the EWMA-smoothed recent arrival rate.
	RecentRPS float64
	// HistoricalRPS is the baseline from historical data.
	HistoricalRPS float64
	// QueuedRPS is the queue-depth converted to an equivalent rate.
	QueuedRPS float64
	// Confidence is in [0,1]; higher means more of the signal is recent or queued
	// (strong evidence) versus pure historical baseline.
	Confidence float64
	// Rising is true when the short-term trend is increasing.
	Rising bool
}

// DemandForecaster combines historical baseline, recent arrival-rate EWMAs, and
// current queue depth into a short-term demand forecast per model.
type DemandForecaster struct {
	historical HistoricalDemandSource

	mu       sync.RWMutex
	tickers  map[string]*demandTicker // model -> rate tracker
	queues   map[string]int           // model -> last observed queue depth
	horizon  time.Duration
	weights  forecastWeights
}

type forecastWeights struct {
	historical float64
	s10s       float64
	s60s       float64
	s5m        float64
	queue      float64
}

// demandTicker tracks EWMA demand rates for one model at multiple time scales.
type demandTicker struct {
	model string
	s10s  *ewma
	s60s  *ewma
	s5m   *ewma
	last  time.Time
}

// ewma is an exponentially weighted moving average for a fixed time constant.
type ewma struct {
	alpha float64
	value float64
	init  bool
}

func newEWMA(timeConstant time.Duration) *ewma {
	return &ewma{alpha: 1 - math.Exp(-1.0/timeConstant.Seconds())}
}

func (e *ewma) add(v float64) {
	if !e.init {
		e.value = v
		e.init = true
		return
	}
	e.value = e.alpha*v + (1-e.alpha)*e.value
}

func (e *ewma) valuePerSecond() float64 {
	if !e.init {
		return 0
	}
	return e.value
}

// NewDemandForecaster creates a forecaster. If historical is nil, a no-op
// source is used.
func NewDemandForecaster(historical HistoricalDemandSource, cfg WarmingConfig) *DemandForecaster {
	if historical == nil {
		historical = noopHistoricalDemandSource{}
	}
	return &DemandForecaster{
		historical: historical,
		tickers:    make(map[string]*demandTicker),
		queues:     make(map[string]int),
		horizon:    cfg.ForecastHorizon,
		weights: forecastWeights{
			historical: cfg.HistoricalWeight,
			s10s:       cfg.EWMA10sWeight,
			s60s:       cfg.EWMA60sWeight,
			s5m:        cfg.EWMA5mWeight,
			queue:      1.0,
		},
	}
}

// RecordRequest records that one request arrived for the model.
func (f *DemandForecaster) RecordRequest(model string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	t := f.tickerForLocked(model)
	now := time.Now()
	delta := now.Sub(t.last).Seconds()
	if delta > 0 {
		rate := 1.0 / delta
		t.s10s.add(rate)
		t.s60s.add(rate)
		t.s5m.add(rate)
	}
	t.last = now
}

// RecordQueue records the current queue depth for the model.
func (f *DemandForecaster) RecordQueue(model string, depth int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.queues[model] = depth
}

// Forecast returns the current demand forecast for the model.
func (f *DemandForecaster) Forecast(ctx context.Context, model string) DemandForecast {
	f.mu.RLock()
	ticker, ok := f.tickers[model]
	queueDepth := f.queues[model]
	f.mu.RUnlock()

	hist, _ := f.historical.HistoricalDemand(ctx, model, f.horizon)

	var recent10s, recent60s, recent5m float64
	if ok {
		recent10s = ticker.s10s.valuePerSecond()
		recent60s = ticker.s60s.valuePerSecond()
		recent5m = ticker.s5m.valuePerSecond()
	}

	// Convert queue depth to an equivalent rate. We assume each queued request
	// represents ~3 seconds of backlog (matches estimateRetryAfter heuristic).
	queuedRPS := float64(queueDepth) / 3.0

	// Confidence rises with the presence of strong recent/queued signals.
	confidence := 0.3
	if recent10s > 0 || recent60s > 0 {
		confidence += 0.4
	}
	if queueDepth > 0 {
		confidence += 0.3
	}
	if confidence > 1.0 {
		confidence = 1.0
	}

	// Recent signal uses the highest of the short-term EWMAs, discounted for
	// longer windows.
	recent := math.Max(recent10s, math.Max(recent60s*f.weights.s60s, recent5m*f.weights.s5m))

	// Combine signals. Historical baseline is scaled down when confidence is high
	// so that live demand dominates.
	histWeight := f.weights.historical * (1.0 - confidence*0.5)
	score := histWeight*hist +
		f.weights.s10s*recent10s +
		f.weights.s60s*recent60s +
		f.weights.s5m*recent5m +
		f.weights.queue*queuedRPS

	// Boost when the short-term rate is rising.
	rising := recent10s > recent60s*1.2

	return DemandForecast{
		Model:             model,
		RequestsPerSecond: score,
		RecentRPS:         recent,
		HistoricalRPS:     hist,
		QueuedRPS:         queuedRPS,
		Confidence:        confidence,
		Rising:            rising,
	}
}

// ModelsWithDemand returns the set of models that have any demand signal.
func (f *DemandForecaster) ModelsWithDemand() []string {
	f.mu.RLock()
	defer f.mu.RUnlock()
	models := make([]string, 0, len(f.tickers)+len(f.queues))
	seen := make(map[string]struct{})
	for m := range f.tickers {
		seen[m] = struct{}{}
		models = append(models, m)
	}
	for m := range f.queues {
		if _, ok := seen[m]; !ok {
			models = append(models, m)
		}
	}
	return models
}

func (f *DemandForecaster) tickerForLocked(model string) *demandTicker {
	t, ok := f.tickers[model]
	if !ok {
		t = &demandTicker{
			model: model,
			s10s:  newEWMA(10 * time.Second),
			s60s:  newEWMA(60 * time.Second),
			s5m:   newEWMA(5 * time.Minute),
			last:  time.Now(),
		}
		f.tickers[model] = t
	}
	return t
}
