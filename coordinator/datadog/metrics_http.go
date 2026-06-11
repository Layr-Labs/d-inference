package datadog

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"sync"
)

// HTTP gauge submission. DogStatsD sends metrics over UDP to a local agent;
// the EigenCloud TEE container has no agent, so those metrics are silently
// dropped (UDP) and fleet gauges like d_inference.providers.online never appear
// in Datadog. Logs and events already submit directly over the HTTPS API with
// DD_API_KEY (no agent needed) — this routes GAUGES the same way so fleet-health
// metrics land. Counters/histograms still go via DogStatsD only (the agent-side
// aggregation they need isn't replicated here); gauges are the fleet-visibility
// metrics that were the actual gap.

// seriesBuffer holds the latest value per (metric, tags) gauge until the next
// flush — gauges are last-write-wins, so one point per series per interval is
// the correct, agent-equivalent submission.
type seriesBuffer struct {
	mu     sync.Mutex
	points map[string]seriesPoint
}

type seriesPoint struct {
	metric string
	tags   []string
	value  float64
	ts     int64
}

func newSeriesBuffer() *seriesBuffer {
	return &seriesBuffer{points: make(map[string]seriesPoint)}
}

func (b *seriesBuffer) setGauge(metric string, value float64, tags []string, ts int64) {
	key := metric + "|" + strings.Join(tags, ",")
	b.mu.Lock()
	b.points[key] = seriesPoint{metric: metric, tags: tags, value: value, ts: ts}
	b.mu.Unlock()
}

func (b *seriesBuffer) drain() []seriesPoint {
	b.mu.Lock()
	defer b.mu.Unlock()
	if len(b.points) == 0 {
		return nil
	}
	out := make([]seriesPoint, 0, len(b.points))
	for _, p := range b.points {
		out = append(out, p)
	}
	b.points = make(map[string]seriesPoint)
	return out
}

// flushSeries POSTs buffered gauges to the Datadog v1 series API. Best-effort:
// errors are logged, never fatal. No-op without an API key or buffered points.
func (c *Client) flushSeries() {
	if c == nil || c.apiKey == "" || c.series == nil {
		return
	}
	pts := c.series.drain()
	if len(pts) == 0 {
		return
	}

	type ddMetric struct {
		Metric string       `json:"metric"`
		Points [][2]float64 `json:"points"`
		Type   string       `json:"type"`
		Tags   []string     `json:"tags,omitempty"`
		Host   string       `json:"host,omitempty"`
	}
	series := make([]ddMetric, 0, len(pts))
	for _, p := range pts {
		tags := append(append([]string{}, c.metricsTags...), p.tags...)
		series = append(series, ddMetric{
			Metric: "d_inference." + p.metric, // mirror the DogStatsD WithNamespace prefix
			Points: [][2]float64{{float64(p.ts), p.value}},
			Type:   "gauge",
			Tags:   tags,
			Host:   c.metricsHost,
		})
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
