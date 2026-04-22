// Package datadog provides Datadog APM, DogStatsD, and Logs API integration
// for the coordinator. All configuration is driven by environment variables:
//
//   - DD_API_KEY: required for Logs API forwarding (empty = forwarding disabled)
//   - DD_SITE: Datadog intake site (default "datadoghq.com")
//   - DD_ENV: environment tag (default "production")
//   - DD_SERVICE: service name override (default "d-inference-coordinator")
//   - DD_DOGSTATSD_URL: DogStatsD address (default "localhost:8125")
//
// The DD agent sidecar handles trace intake (default localhost:8126) and
// DogStatsD aggregation. The coordinator only pushes directly to the Logs
// API for telemetry event forwarding.
package datadog

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
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

	// Batching for log forwarding.
	logMu      sync.Mutex
	logBuf     []ddLog
	logTicker  *time.Ticker
	logDone    chan struct{}
	logFlushWg sync.WaitGroup
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
		logger:    logger,
		apiKey:    cfg.APIKey,
		logBuf:    make([]ddLog, 0, cfg.MaxBatchSize),
		logDone:   make(chan struct{}),
		logTicker: time.NewTicker(time.Duration(cfg.FlushSecs) * time.Second),
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

	// DogStatsD client — best effort. If the agent isn't running, metrics
	// calls become no-ops (the library handles reconnection).
	sd, err := statsd.New(cfg.StatsdAddr,
		statsd.WithNamespace("d_inference."),
		statsd.WithTags([]string{
			"env:" + cfg.Env,
			"service:" + cfg.Service,
		}),
	)
	if err != nil {
		logger.Warn("datadog: DogStatsD client init failed (metrics disabled)", "error", err, "addr", cfg.StatsdAddr)
	} else {
		c.Statsd = sd
	}

	// Start the log flush goroutine.
	c.logFlushWg.Add(1)
	go c.logFlushLoop()

	return c, nil
}

// Close flushes remaining logs and closes connections.
func (c *Client) Close() {
	if c == nil {
		return
	}
	c.logTicker.Stop()
	close(c.logDone)
	c.logFlushWg.Wait()
	c.flushLogs()
	if c.Statsd != nil {
		_ = c.Statsd.Close()
	}
}

// ---------------------------------------------------------------------------
// DogStatsD convenience methods
// ---------------------------------------------------------------------------

// Incr increments a counter.
func (c *Client) Incr(name string, tags []string) {
	if c == nil || c.Statsd == nil {
		return
	}
	_ = c.Statsd.Incr(name, tags, 1)
}

// Histogram records a histogram value.
func (c *Client) Histogram(name string, value float64, tags []string) {
	if c == nil || c.Statsd == nil {
		return
	}
	_ = c.Statsd.Histogram(name, value, tags, 1)
}

// Gauge sets a gauge value.
func (c *Client) Gauge(name string, value float64, tags []string) {
	if c == nil || c.Statsd == nil {
		return
	}
	_ = c.Statsd.Gauge(name, value, tags, 1)
}

// ---------------------------------------------------------------------------
// Datadog Logs API forwarding
// ---------------------------------------------------------------------------

// ddLog is the JSON shape for the DD Logs API v2.
type ddLog struct {
	DDSource string         `json:"ddsource"`
	DDTags   string         `json:"ddtags,omitempty"`
	Hostname string         `json:"hostname,omitempty"`
	Service  string         `json:"service"`
	Status   string         `json:"status,omitempty"`
	Message  string         `json:"message"`
	Attrs    map[string]any `json:"attributes,omitempty"`
}

// TelemetryLogEntry is the shape callers pass to ForwardLog.
type TelemetryLogEntry struct {
	Source    string // "provider", "coordinator", "console", "app", "bridge"
	Severity  string // "debug", "info", "warn", "error", "fatal"
	Kind      string // "panic", "backend_crash", etc.
	Message   string
	MachineID string
	AccountID string
	RequestID string
	SessionID string
	Version   string
	Fields    map[string]any
	Stack     string
}

// ForwardLog buffers a telemetry event for async forwarding to the DD Logs API.
// No-op if DD_API_KEY is not set.
func (c *Client) ForwardLog(entry TelemetryLogEntry) {
	if c == nil || c.apiKey == "" {
		return
	}

	n := len(entry.Fields)
	if n > 10000 {
		n = 10000
	}
	attrs := make(map[string]any, n+6)
	for k, v := range entry.Fields {
		attrs[k] = v
	}
	attrs["dd.kind"] = entry.Kind
	if entry.AccountID != "" {
		attrs["account_id"] = entry.AccountID
	}
	if entry.RequestID != "" {
		attrs["request_id"] = entry.RequestID
	}
	if entry.SessionID != "" {
		attrs["session_id"] = entry.SessionID
	}
	if entry.Version != "" {
		attrs["version"] = entry.Version
	}
	if entry.Stack != "" {
		attrs["error.stack"] = entry.Stack
	}

	log := ddLog{
		DDSource: entry.Source,
		DDTags:   fmt.Sprintf("kind:%s,severity:%s", entry.Kind, entry.Severity),
		Hostname: entry.MachineID,
		Service:  "d-inference-coordinator",
		Status:   mapSeverityToStatus(entry.Severity),
		Message:  entry.Message,
		Attrs:    attrs,
	}

	c.logMu.Lock()
	c.logBuf = append(c.logBuf, log)
	shouldFlush := len(c.logBuf) >= 100
	c.logMu.Unlock()

	if shouldFlush {
		go c.flushLogs()
	}

	// Fatal events also emit a DD Event for monitors.
	if entry.Severity == "fatal" {
		go c.emitDDEvent(entry)
	}
}

func mapSeverityToStatus(sev string) string {
	switch sev {
	case "debug":
		return "debug"
	case "info":
		return "info"
	case "warn":
		return "warning"
	case "error":
		return "error"
	case "fatal":
		return "critical"
	default:
		return "info"
	}
}

func (c *Client) logFlushLoop() {
	defer c.logFlushWg.Done()
	for {
		select {
		case <-c.logTicker.C:
			c.flushLogs()
		case <-c.logDone:
			return
		}
	}
}

func (c *Client) flushLogs() {
	c.logMu.Lock()
	if len(c.logBuf) == 0 {
		c.logMu.Unlock()
		return
	}
	batch := c.logBuf
	c.logBuf = make([]ddLog, 0, 100)
	c.logMu.Unlock()

	body, err := json.Marshal(batch)
	if err != nil {
		c.logger.Warn("datadog: failed to marshal log batch", "error", err)
		return
	}

	req, err := http.NewRequest(http.MethodPost, c.logsURL, bytes.NewReader(body))
	if err != nil {
		c.logger.Warn("datadog: failed to create log request", "error", err)
		return
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("DD-API-KEY", c.apiKey)

	resp, err := c.httpClient.Do(req)
	if err != nil {
		c.logger.Warn("datadog: logs API request failed", "error", err, "batch_size", len(batch))
		return
	}
	_, _ = io.ReadAll(resp.Body)
	resp.Body.Close()

	if resp.StatusCode >= 400 {
		c.logger.Warn("datadog: logs API returned error", "status", resp.StatusCode, "batch_size", len(batch))
	}
}

// emitDDEvent sends a Datadog Event for fatal telemetry entries so monitors
// can trigger alerts.
func (c *Client) emitDDEvent(entry TelemetryLogEntry) {
	if c.apiKey == "" {
		return
	}
	event := map[string]any{
		"title":      fmt.Sprintf("[d-inference] Fatal: %s", truncate(entry.Message, 100)),
		"text":       entry.Message,
		"alert_type": "error",
		"source":     "d-inference",
		"tags":       []string{"source:" + entry.Source, "kind:" + entry.Kind, "env:" + envOr("DD_ENV", "production")},
	}
	if entry.Stack != "" {
		event["text"] = entry.Message + "\n\n```\n" + entry.Stack + "\n```"
	}

	body, err := json.Marshal(event)
	if err != nil {
		return
	}

	req, err := http.NewRequest(http.MethodPost, c.eventsURL, bytes.NewReader(body))
	if err != nil {
		return
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("DD-API-KEY", c.apiKey)

	resp, err := c.httpClient.Do(req)
	if err != nil {
		c.logger.Warn("datadog: events API request failed", "error", err)
		return
	}
	_, _ = io.ReadAll(resp.Body)
	resp.Body.Close()
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}
