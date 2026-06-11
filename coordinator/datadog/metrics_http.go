package datadog

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"sync"
)

// HTTP metric submission. DogStatsD sends metrics over UDP to a local agent;
// the EigenCloud TEE container has no agent, so those metrics are silently
// dropped (UDP) and fleet metrics like d_inference.providers.online never
// appear in Datadog. Logs and events already submit directly over the HTTPS
// API with DD_API_KEY (no agent needed) — this routes GAUGES and COUNTERS the
// same way. When DD_API_KEY is set the HTTP path is authoritative and the
// DogStatsD leg is skipped (teeing would double-count if an agent ever
// appears, with divergent host tags); without an API key, DogStatsD is the
// only leg. Histograms remain DogStatsD-only: their percentile aggregation
// happens agent-side and isn't replicated here.

// seriesBuffer accumulates metric points between flushes: gauges are
// last-write-wins per (metric, tags) series; counters sum per series over the
// flush interval — both matching what a local agent would submit.
type seriesBuffer struct {
	mu     sync.Mutex
	gauges map[string]seriesPoint
	counts map[string]seriesPoint
}

type seriesPoint struct {
	metric string
	tags   []string
	value  float64
	ts     int64
}

func newSeriesBuffer() *seriesBuffer {
	return &seriesBuffer{
		gauges: make(map[string]seriesPoint),
		counts: make(map[string]seriesPoint),
	}
}

func seriesKey(metric string, tags []string) string {
	return metric + "|" + strings.Join(tags, ",")
}

func (b *seriesBuffer) setGauge(metric string, value float64, tags []string, ts int64) {
	key := seriesKey(metric, tags)
	b.mu.Lock()
	b.gauges[key] = seriesPoint{metric: metric, tags: tags, value: value, ts: ts}
	b.mu.Unlock()
}

func (b *seriesBuffer) addCount(metric string, value float64, tags []string, ts int64) {
	key := seriesKey(metric, tags)
	b.mu.Lock()
	p, ok := b.counts[key]
	if !ok {
		p = seriesPoint{metric: metric, tags: tags}
	}
	p.value += value
	p.ts = ts
	b.counts[key] = p
	b.mu.Unlock()
}

// drain returns and clears the buffered gauges and counts.
func (b *seriesBuffer) drain() (gauges, counts []seriesPoint) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, p := range b.gauges {
		gauges = append(gauges, p)
	}
	for _, p := range b.counts {
		counts = append(counts, p)
	}
	b.gauges = make(map[string]seriesPoint)
	b.counts = make(map[string]seriesPoint)
	return gauges, counts
}

// ddMetric is the v1 /series payload entry.
type ddMetric struct {
	Metric   string       `json:"metric"`
	Points   [][2]float64 `json:"points"`
	Type     string       `json:"type"`
	Interval int64        `json:"interval,omitempty"` // counts: the flush window
	Tags     []string     `json:"tags,omitempty"`
	Host     string       `json:"host,omitempty"`
}

// flushSeries POSTs buffered gauges and counters to the Datadog v1 series API.
// Best-effort: errors are logged, never fatal. No-op without an API key or
// buffered points.
func (c *Client) flushSeries() {
	if c == nil || c.apiKey == "" || c.series == nil {
		return
	}
	gauges, counts := c.series.drain()
	if len(gauges)+len(counts) == 0 {
		return
	}

	series := make([]ddMetric, 0, len(gauges)+len(counts))
	emit := func(p seriesPoint, typ string, interval int64) {
		tags := append(append([]string{}, c.metricsTags...), p.tags...)
		series = append(series, ddMetric{
			Metric:   "d_inference." + p.metric, // mirror the DogStatsD WithNamespace prefix
			Points:   [][2]float64{{float64(p.ts), p.value}},
			Type:     typ,
			Interval: interval,
			Tags:     tags,
			Host:     c.metricsHost,
		})
	}
	for _, p := range gauges {
		emit(p, "gauge", 0)
	}
	for _, p := range counts {
		emit(p, "count", c.flushIntervalSecs)
	}

	body, err := json.Marshal(map[string]any{"series": series})
	if err != nil {
		c.logger.Warn("datadog: failed to marshal series batch", "error", err)
		return
	}
	req, err := http.NewRequest(http.MethodPost, c.seriesURL, bytes.NewReader(body))
	if err != nil {
		c.logger.Warn("datadog: failed to create series request", "error", err)
		return
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Dd-Api-Key", c.apiKey)

	resp, err := c.httpClient.Do(req)
	if err != nil {
		c.logger.Warn("datadog: series API request failed", "error", err, "batch_size", len(series))
		return
	}
	_, _ = io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode >= 400 {
		c.logger.Warn("datadog: series API returned error", "status", resp.StatusCode, "batch_size", len(series))
	}
}
