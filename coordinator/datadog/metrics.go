package datadog

// DogStatsD metrics. The local agent owns aggregation and delivery; see the
// package doc for why none of that lives here.

import (
	"errors"
	"time"
)

// statsdErrReportInterval throttles the delivery-error report. A dead agent
// refuses roughly every other datagram, so this is the difference between one
// actionable line a minute and a log nobody can read.
const statsdErrReportInterval = time.Minute

// errStatsdDisabled is the second way metrics can be dropped: statsd.New itself
// failed at startup, so there is no client to report a delivery error. NewClient
// warns once when that happens, but a line in the first second of a process's
// life is not what an operator greps for hours later — and the runbook tells them
// to look for exactly one string. Reporting this through the same throttled
// handler means "DogStatsD delivery failing" covers both drop modes.
var errStatsdDisabled = errors.New("DogStatsD client was never initialized (see the init failure at startup)")

// statsdError is the statsd client's error handler. The library default is
// `func(error) {}`, which is why an agentless host discarded every metric
// without complaint; this turns that condition into a log line naming the
// address, which is the one thing an operator needs to fix it.
func (c *Client) statsdError(err error) {
	if c == nil || err == nil {
		return
	}
	c.statsdErrMu.Lock()
	c.statsdErrs++
	count := c.statsdErrs
	if time.Since(c.statsdErrLast) < statsdErrReportInterval {
		c.statsdErrMu.Unlock()
		return
	}
	c.statsdErrLast = time.Now()
	c.statsdErrs = 0
	c.statsdErrMu.Unlock()

	c.warn("datadog: DogStatsD delivery failing (metrics are being dropped)",
		"error", err, "addr", c.statsdAddr, "errors_since_last_report", count)
}

// Incr increments a counter.
func (c *Client) Incr(name string, tags []string) {
	c.Count(name, 1, tags)
}

// Count increments a counter by the given value.
func (c *Client) Count(name string, value int64, tags []string) {
	if c == nil {
		return
	}
	if c.Statsd == nil {
		c.statsdError(errStatsdDisabled)
		return
	}
	_ = c.Statsd.Count(name, value, tags, 1)
}

// Histogram records a histogram value as a DogStatsD *distribution* (`d`), not
// a histogram (`h`). With `h` the agent aggregates locally and submits
// `<metric>.95percentile` gauges, which cannot be re-aggregated — averaging
// per-window percentiles is not a percentile of anything. With `d` the agent
// forwards the raw values and Datadog computes percentiles over the queried
// range, which is what the dashboard's `pNN:` widgets ask for. Those
// aggregators are enabled per metric, per organization:
// deploy/datadog/enable-distribution-percentiles.sh.
func (c *Client) Histogram(name string, value float64, tags []string) {
	if c == nil {
		return
	}
	if c.Statsd == nil {
		c.statsdError(errStatsdDisabled)
		return
	}
	_ = c.Statsd.Distribution(name, value, tags, 1)
}

// Gauge sets a gauge value.
func (c *Client) Gauge(name string, value float64, tags []string) {
	if c == nil {
		return
	}
	if c.Statsd == nil {
		c.statsdError(errStatsdDisabled)
		return
	}
	_ = c.Statsd.Gauge(name, value, tags, 1)
}
