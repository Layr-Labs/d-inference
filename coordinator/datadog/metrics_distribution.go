package datadog

import (
	"bytes"
	"encoding/json"
	"io"
	"math/rand/v2"
	"net/http"
	"sync"
)

// HTTPS distribution submission for histograms. DogStatsD histograms are
// aggregated by a local agent, and a host with no agent has none: the datagrams
// are discarded by the kernel and every histogram the coordinator records is
// lost with no error reported anywhere, because opening a UDP socket succeeds
// whether or not anything is listening. This routes histograms to the v1
// distribution_points intake the same way metrics_http.go routes gauges and
// counters, so no metric the coordinator records about itself depends on a
// sidecar being present.
//
// Distributions also mean better numbers than the DogStatsD leg produced. An
// agent computes percentiles locally per flush window and submits them as plain
// gauges named `<metric>.95percentile`, which cannot be re-aggregated: a widget
// asking `avg:<metric>.95percentile{...}` averages percentiles, which is not a
// percentile of anything, and zooming the time range makes it more wrong. A
// distribution carries the raw values and Datadog computes percentiles over
// whatever range is queried.
//
// One deploy-side step comes with it: percentile aggregators (`p50:`, `p95:`,
// `p99:`) must be enabled per metric before a query can use them, otherwise
// only avg/sum/min/max/count are available. See
// deploy/datadog/enable-distribution-percentiles.sh.

const (
	// maxDistValuesPerSeries bounds the values one flush window retains for a
	// single (metric, tags) series. Past it the window is reservoir-sampled
	// rather than grown, so a traffic burst costs resolution instead of
	// unbounded heap. The sample is uniform within the window, so percentiles
	// over that window stay unbiased; count/sum do not, which is why sampling is
	// reported. (Across windows the guarantee is weaker: a sampled window
	// contributes the same 2000 values as an unsampled one, so a wide time range
	// weighs a busy window like a quiet one.)
	maxDistValuesPerSeries = 2000

	// The v1 spec documents a 3.2 MB (3200000 B) cap on the request body for
	// /api/v1/series and states no limit for /api/v1/distribution_points; 3.2 MB
	// is assumed here as the conservative intake-wide figure. One flush is split
	// across POSTs on whichever of these two bounds comes first: value count
	// alone is not enough, because 50k values spread over 50k thin one-value
	// series is ~14 MB of metric names and tags.
	maxDistValuesPerRequest = 50000
	maxDistBytesPerRequest  = 2 << 20 // 2 MB

	// Per-entry cost estimates for that byte bound. distEntryBytes covers the
	// metric name, tags, host and JSON scaffolding (the widest real entry
	// measures 294 B). distValueBytes is the widest a json.Marshal'd float64
	// gets — "-1.2345678901234567e-308" plus its comma — not the ~16 B a
	// latency reading actually takes, so the estimate stays above the real body
	// even for values that encode in scientific notation. It only has to be
	// conservative: it decides where to split, nothing else.
	distEntryBytes = 320
	distValueBytes = 25
)

// distBuffer accumulates raw histogram values per (metric, tags) between
// flushes. Unlike seriesBuffer it cannot pre-aggregate: the point of a
// distribution is that the intake sees every observation.
type distBuffer struct {
	mu     sync.Mutex
	points map[string]*distPoint
}

type distPoint struct {
	metric string
	tags   []string
	values []float64
	// seen counts observations offered, including any the reservoir dropped;
	// len(values) < seen is exactly the condition that sampling engaged.
	seen int
	ts   int64 // last observation, mirroring seriesBuffer
}

func newDistBuffer() *distBuffer {
	return &distBuffer{points: make(map[string]*distPoint)}
}

func (b *distBuffer) add(metric string, value float64, tags []string, ts int64) {
	key := seriesKey(metric, tags)
	b.mu.Lock()
	defer b.mu.Unlock()
	p, ok := b.points[key]
	if !ok {
		// Copy the caller's slice: it is held until the next flush (seconds, not
		// the synchronous DogStatsD format call this replaced), and Histogram is
		// exported, so the buffer must not depend on the caller leaving a slice
		// it still owns alone. Once per new series.
		p = &distPoint{
			metric: metric,
			tags:   append([]string(nil), tags...),
			values: make([]float64, 0, 16),
		}
		b.points[key] = p
	}
	p.ts = ts
	p.seen++
	if len(p.values) < maxDistValuesPerSeries {
		p.values = append(p.values, value)
		return
	}
	// Reservoir sampling (Vitter's Algorithm R): the i-th observation takes a
	// random reservoir slot with probability k/i, which leaves every
	// observation in the window equally likely to survive. Truncating instead
	// would keep only the start of the window and bias every percentile.
	if j := rand.IntN(p.seen); j < maxDistValuesPerSeries {
		p.values[j] = value
	}
}

// drain returns and clears the buffered points.
func (b *distBuffer) drain() []distPoint {
	b.mu.Lock()
	defer b.mu.Unlock()
	out := make([]distPoint, 0, len(b.points))
	for _, p := range b.points {
		out = append(out, *p)
	}
	b.points = make(map[string]*distPoint)
	return out
}

// ddDistribution is a v1 /distribution_points payload entry. A point is
// [timestamp, [values...]] — a heterogeneous pair with no struct shape, hence
// [2]any.
type ddDistribution struct {
	Metric string   `json:"metric"`
	Points [][2]any `json:"points"`
	Type   string   `json:"type,omitempty"`
	Tags   []string `json:"tags,omitempty"`
	Host   string   `json:"host,omitempty"`
}

// flushDistributions POSTs buffered histogram values to the Datadog v1
// distribution_points API. Best-effort: errors are logged, never fatal. No-op
// without an API key or buffered points.
func (c *Client) flushDistributions() {
	if c == nil || c.apiKey == "" || c.dist == nil {
		return
	}
	points := c.dist.drain()
	if len(points) == 0 {
		return
	}

	var (
		batch   []ddDistribution
		values  int
		payload int
		sampled int
		worst   distPoint
	)
	for _, p := range points {
		if p.seen > len(p.values) {
			sampled++
			if p.seen > worst.seen {
				worst = p
			}
		}
		batch = append(batch, ddDistribution{
			Metric: "d_inference." + p.metric, // mirror the DogStatsD WithNamespace prefix
			Points: [][2]any{{p.ts, p.values}},
			Type:   "distribution",
			Tags:   append(append([]string{}, c.metricsTags...), p.tags...),
			Host:   c.metricsHost,
		})
		values += len(p.values)
		payload += distEntryBytes + distValueBytes*len(p.values)
		if values >= maxDistValuesPerRequest || payload >= maxDistBytesPerRequest {
			c.postDistributions(batch)
			batch, values, payload = nil, 0, 0
		}
	}
	if len(batch) > 0 {
		c.postDistributions(batch)
	}

	if sampled > 0 {
		// Percentiles over this window survive sampling; counts and sums do not,
		// and a wide time range now weighs this window like a quiet one. Say so
		// rather than let a truncated window look like a quiet one.
		c.warn("datadog: distribution window sampled (window percentiles remain valid, count/sum under-report)",
			"series", sampled, "worst_metric", worst.metric,
			"observed", worst.seen, "submitted", len(worst.values))
	}
}

func (c *Client) postDistributions(batch []ddDistribution) {
	body, err := json.Marshal(map[string]any{"series": batch})
	if err != nil {
		c.warn("datadog: failed to marshal distribution batch", "error", err)
		return
	}
	req, err := http.NewRequest(http.MethodPost, c.distURL, bytes.NewReader(body))
	if err != nil {
		c.warn("datadog: failed to create distribution request", "error", err)
		return
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Dd-Api-Key", c.apiKey)

	resp, err := c.httpClient.Do(req)
	if err != nil {
		c.warn("datadog: distribution API request failed", "error", err, "batch_size", len(batch))
		return
	}
	respBody, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode >= 400 {
		c.warn("datadog: distribution API returned error",
			"status", resp.StatusCode, "batch_size", len(batch),
			"body", truncate(string(respBody), 200))
	}
}
