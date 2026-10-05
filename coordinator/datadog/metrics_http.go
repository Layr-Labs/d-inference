package datadog

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"

	metricseries "github.com/eigeninference/d-inference/coordinator/internal/datadog/series"
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
	gauges, counts := c.series.Drain()
	if len(gauges)+len(counts) == 0 {
		return
	}

	series := make([]ddMetric, 0, len(gauges)+len(counts))
	emit := func(p metricseries.Point, typ string, interval int64) {
		tags := append(append([]string{}, c.metricsTags...), p.Tags...)
		series = append(series, ddMetric{
			Metric:   "d_inference." + p.Metric, // mirror the DogStatsD WithNamespace prefix
			Points:   [][2]float64{{float64(p.Timestamp), p.Value}},
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
