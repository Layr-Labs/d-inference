package metrics

import (
	"sync"
)

// Kind is the wire type a declaration commits to. It is not a formatting
// detail: Datadog stores a name's type on first submission and rejects a later
// submission that disagrees, so changing a Kind on a name that has shipped
// breaks that name until someone deletes it out of the metric summary.
type Kind string

const (
	KindCount        Kind = "count"
	KindGauge        Kind = "gauge"
	KindDistribution Kind = "distribution"
)

// declaration is what every collector has: the identity of a series. The
// recording methods live on the typed wrappers below so a counter cannot be
// Set() and a gauge cannot be Observe()d.
type declaration struct {
	// name is the DogStatsD metric name without the namespace; the client
	// prefixes `d_inference.`.
	name string
	// mirror is the name this metric has in the in-process registry, empty when
	// it has no mirror. The two names differ for historical reasons and the
	// declaration is the only place that pairing is visible.
	mirror string
	// mirrorPrefix is how many of the leading labelKeys the mirror carries; 0
	// means all of them. The two sides are not always tagged alike —
	// `ws.disconnects` splits by close code and `ws_disconnects_total` never did
	// — and the mirror's key set is a stored Prometheus series that this
	// migration must not widen.
	mirrorPrefix int
	// help says what the series means to someone who did not write it. It is
	// not decoration: Document() is what an operator reads instead of grepping.
	help string
	// labelKeys are the tag keys, in the order recording methods take values.
	// A metric's key set is fixed by declaration — that is the invariant this
	// package exists to hold, because two call sites tagging one series
	// differently produce two series that no query reunites.
	labelKeys []string
	kind      Kind
	// locked marks a name Datadog already stores under a type that is not the
	// one this package would choose today. See lockedGauge.
	locked bool

	sinks    *sinks
	warnOnce sync.Once
}

// tags renders declared keys against ordered values. An empty value omits its
// tag, which is how a metric with a conditional dimension (a close code that
// exists only for a clean close) keeps the exact series shape it shipped with
// rather than growing a `code:` tag full of empty strings.
func (d *declaration) tags(values []string) []string {
	if len(values) != len(d.labelKeys) {
		d.reportArity(values)
		if len(values) > len(d.labelKeys) {
			values = values[:len(d.labelKeys)]
		}
	}
	tags := make([]string, 0, len(values))
	for i, value := range values {
		if value == "" {
			continue
		}
		tags = append(tags, d.labelKeys[i]+":"+value)
	}
	return tags
}

// labels renders the same pairing for the in-process mirror, narrowed to the
// keys that mirror actually carries.
func (d *declaration) labels(values []string) []Label {
	if len(values) > len(d.labelKeys) {
		values = values[:len(d.labelKeys)]
	}
	if d.mirrorPrefix > 0 && d.mirrorPrefix < len(values) {
		values = values[:d.mirrorPrefix]
	}
	labels := make([]Label, 0, len(values))
	for i, value := range values {
		if value == "" {
			continue
		}
		labels = append(labels, Label{Name: d.labelKeys[i], Value: value})
	}
	return labels
}

// reportArity logs a call site that passed the wrong number of label values.
// This is a programming error, so it is reported — but it is reported once per
// metric and the sample is still recorded with the values that could be paired.
// Telemetry does not get to panic a request path, and dropping the sample
// silently would hide the very drift the declaration is here to catch.
func (d *declaration) reportArity(values []string) {
	d.warnOnce.Do(func() {
		d.sinks.warn("metrics: label arity mismatch, series will be mis-tagged",
			"metric", d.name, "declared_keys", d.labelKeys, "values_passed", len(values))
	})
}

// Counter is a monotonically increasing count. On this transport each sample is
// a delta the intake sums, never a running total: a cumulative counter read from
// a provider heartbeat must be differenced before it reaches Add.
type Counter struct{ *declaration }

// Inc records one occurrence.
func (c *Counter) Inc(labelValues ...string) { c.Add(1, labelValues...) }

// Add records delta occurrences. A zero or negative delta is not recorded: the
// producers of a delta are counter differences, and a provider that restarted
// its counters must contribute nothing rather than a negative correction.
func (c *Counter) Add(delta int64, labelValues ...string) {
	if delta <= 0 {
		return
	}
	c.sinks.dd.Count(c.name, delta, c.tags(labelValues))
	if c.mirror != "" && c.sinks.mirror != nil {
		c.sinks.mirror.AddCounter(c.mirror, delta, c.labels(labelValues)...)
	}
}

// Gauge is a point-in-time value. Pushed gauges are not remembered by anything:
// the value exists in the flush window it was sent in, so a gauge that must stay
// readable has to be re-emitted on a loop.
type Gauge struct{ *declaration }

// Set records the current value.
func (g *Gauge) Set(value float64, labelValues ...string) {
	g.sinks.dd.Gauge(g.name, value, g.tags(labelValues))
}

// Distribution forwards raw values so Datadog computes aggregates over the
// queried range. This is the type for anything whose spread matters — a latency,
// a per-heartbeat reading of a fleet-wide quantity — and it is the type a new
// snapshot metric should have, because a gauge tagged only by coarse dimensions
// is aggregated client-side to one arbitrary reporter's value per flush window.
//
// `pNN:` queries additionally need percentile aggregators enabled on the metric
// (deploy/datadog/enable-distribution-percentiles.sh); avg/max/count work
// without them.
type Distribution struct{ *declaration }

// Observe records one sample.
func (d *Distribution) Observe(value float64, labelValues ...string) {
	d.sinks.dd.Distribution(d.name, value, d.tags(labelValues))
	if d.mirror != "" && d.sinks.mirror != nil {
		d.sinks.mirror.ObserveHistogram(d.mirror, value, d.labels(labelValues)...)
	}
}
