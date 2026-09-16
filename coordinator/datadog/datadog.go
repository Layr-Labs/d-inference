// Package datadog provides Datadog APM, DogStatsD, and Logs API integration
// for the coordinator. All configuration is driven by environment variables:
//
//   - DD_API_KEY: required for Logs API forwarding (empty = forwarding disabled)
//   - DD_SITE: Datadog intake site (default "datadoghq.com")
//   - DD_ENV: environment tag (default "production")
//   - DD_SERVICE: service name override (default "d-inference-coordinator")
//   - DD_DOGSTATSD_URL: DogStatsD address (default "localhost:8125")
//
// # Metrics go through the agent
//
// Counters, gauges and histograms are handed to DogStatsD and the local agent
// owns everything after that: aggregation, batching, compression, retries and
// back-pressure. The coordinator deliberately does not reimplement any of it —
// an earlier revision buffered and POSTed to the v1 series and
// distribution_points intakes directly, which meant ~400 lines of reservoir
// sampling and payload chunking in a service whose job is inference routing.
// The agent is a deployment step (deploy/gcp/vm-startup.sh for dev,
// docs/operations/datadog-agent.md for prod), not a Go problem.
//
// Histograms use the DogStatsD *distribution* type, not the histogram type.
// That distinction is load-bearing: with `h`, the agent computes percentiles
// locally per flush window and submits them as plain gauges named
// `<metric>.95percentile`, which cannot be re-aggregated — `avg:` of a
// percentile is not a percentile of anything, and it gets more wrong as a
// widget's time range widens. With `d`, the agent forwards the raw values and
// Datadog computes percentiles server-side over whatever range is queried.
// Percentile aggregators must then be enabled per metric, per organization:
// deploy/datadog/enable-distribution-percentiles.sh.
//
// # Delivery failures are reported
//
// The agent being absent used to be invisible. Opening a UDP socket succeeds
// with nothing listening, the statsd client is asynchronous so every call
// returns nil regardless, and the library's default error handler is
// `func(error) {}` — so a host with no agent discarded every metric and said
// nothing. A connected UDP socket does surface the dead listener (ICMP
// port-unreachable makes the following write return ECONNREFUSED); nobody was
// listening for it. NewClient installs an error handler, so that condition is
// now logged instead of guessed at.
//
// # Logs stay on HTTPS
//
// Logs and events go straight to the Logs API, not through the agent. They
// carry structured attributes through an allowlist (see
// api/telemetry_handlers.go, the privacy backstop) and include provider-sourced
// telemetry that never appears in this process's stdout, so an agent tailing
// journald or docker logs is not a substitute. Everything submitted this way
// carries env and service explicitly: an agent stamps the log stream it
// collects itself, the intake does not, and the dashboards scope every query by
// that pair.
package datadog

import (
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/DataDog/datadog-go/v5/statsd"
)

// Client wraps DogStatsD and the Logs API forwarder.
type Client struct {
	Statsd *statsd.Client
	logger *slog.Logger

	// Logs API forwarding.
	apiKey     string
	logsURL    string
	eventsURL  string
	httpClient *http.Client
	// service is the log payload's service field and env/service the tags
	// every forwarded log carries — the same pair metricsTags puts on metrics.
	// Held on the client because a log is tagged where it is built, not where
	// it is flushed.
	env     string
	service string

	// Batching for log forwarding.
	logMu      sync.Mutex
	logBuf     []ddLog
	logTicker  *time.Ticker
	logDone    chan struct{}
	logFlushWg sync.WaitGroup
	closeOnce  sync.Once

	// statsdAddr is kept only to name it in the delivery-error log. "metrics are
	// being dropped" is not actionable without the address nobody is listening
	// on, and the statsd client does not expose it back.
	statsdAddr string

	// statsdErrs rate-limits the DogStatsD delivery-error report. A dead agent
	// refuses roughly every other datagram, so an unthrottled handler would emit
	// thousands of identical lines a second and bury the signal it exists to
	// raise.
	statsdErrMu   sync.Mutex
	statsdErrs    uint64
	statsdErrLast time.Time
}

// Config holds Datadog configuration. Populated from env vars in NewClient.
type Config struct {
	APIKey       string // DD_API_KEY
	Site         string // DD_SITE, default "datadoghq.com"
	Env          string // DD_ENV, default "production"
	Service      string // DD_SERVICE, default "d-inference-coordinator"
	StatsdAddr   string // DD_DOGSTATSD_URL, default "localhost:8125"
	FlushSecs    int    // Log batch flush interval (default 5)
	MaxBatchSize int    // Max logs per batch (default 100)
}

// ConfigFromEnv reads Datadog configuration from environment variables.
func ConfigFromEnv() Config {
	return Config{
		APIKey:       os.Getenv("DD_API_KEY"),
		Site:         envOr("DD_SITE", "datadoghq.com"),
		Env:          envOr("DD_ENV", "production"),
		Service:      envOr("DD_SERVICE", "d-inference-coordinator"),
		StatsdAddr:   envOr("DD_DOGSTATSD_URL", "localhost:8125"),
		FlushSecs:    5,
		MaxBatchSize: 100,
	}
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// NewClient initializes the DogStatsD client and log forwarder.
// Returns nil if DD is not configured (no API key and statsd connect fails).
// The caller should defer client.Close().
func NewClient(cfg Config, logger *slog.Logger) (*Client, error) {
	c := &Client{
		logger:     logger,
		apiKey:     cfg.APIKey,
		statsdAddr: cfg.StatsdAddr,
		logBuf:     make([]ddLog, 0, cfg.MaxBatchSize),
		logDone:    make(chan struct{}),
		logTicker:  time.NewTicker(time.Duration(cfg.FlushSecs) * time.Second),
		httpClient: &http.Client{
			Timeout: 10 * time.Second,
		},
	}

	// Build intake URLs from site.
	site := cfg.Site
	if site == "" {
		site = "datadoghq.com"
	}
	c.logsURL = fmt.Sprintf("https://http-intake.logs.%s/api/v2/logs", site)
	c.eventsURL = fmt.Sprintf("https://api.%s/api/v1/events", site)
	c.env = cfg.Env
	c.service = cfg.Service

	// DogStatsD client. The agent owns aggregation and delivery; the only thing
	// this side is responsible for is noticing when it is not there, which is
	// what the error handler is for — the library default discards every
	// delivery error, and that is how an agentless host lost every metric
	// silently for as long as it did.
	sd, err := statsd.New(cfg.StatsdAddr,
		statsd.WithNamespace("d_inference."),
		statsd.WithTags([]string{
			"env:" + cfg.Env,
			"service:" + cfg.Service,
		}),
		statsd.WithErrorHandler(c.statsdError),
	)
	if err != nil {
		// c.warn, not logger.Warn: an embedder may construct a Client with no
		// logger, and a failed statsd connect is the most likely thing to happen
		// on such a host — a nil dereference here would turn "no agent" into a
		// startup panic.
		c.warn("datadog: DogStatsD client init failed (metrics disabled)", "error", err, "addr", cfg.StatsdAddr)
	} else {
		c.Statsd = sd
	}

	// Start the log flush goroutine.
	c.logFlushWg.Add(1)
	go c.logFlushLoop()

	return c, nil
}

// Close flushes remaining logs and closes connections. Safe to call twice, and
// on a Client assembled by hand without a ticker or done channel: the tests in
// this package build exactly that shape, and a shutdown path that panics is
// worse than one that no-ops.
func (c *Client) Close() {
	if c == nil {
		return
	}
	c.closeOnce.Do(func() {
		if c.logTicker != nil {
			c.logTicker.Stop()
		}
		if c.logDone != nil {
			close(c.logDone)
		}
	})
	c.logFlushWg.Wait()
	c.flushLogs()
	// Statsd.Close flushes whatever the client still holds before closing the
	// socket, so buffered metrics from the last few seconds are not lost on a
	// clean shutdown.
	if c.Statsd != nil {
		_ = c.Statsd.Close()
	}
}

// warn logs a submission problem. Every caller is on a best-effort telemetry
// path, and a Client can be assembled by hand (tests, embedders) without a
// logger, so a missing logger must not turn a dropped metric into a panic.
func (c *Client) warn(msg string, args ...any) {
	if c == nil || c.logger == nil {
		return
	}
	c.logger.Warn(msg, args...)
}

// Check validates the configuration.
func (c Config) Check() error { return nil }
