package datadog

// Datadog Logs API forwarding, plus the Events API call fatal entries make. This
// leg does not go through the agent; the package doc says why.

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"strings"
)

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

	attrs := make(map[string]any, 16)
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
		DDTags:   c.logTags(entry),
		Hostname: entry.MachineID,
		Service:  c.service,
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

// logTags builds the ddtags string for a forwarded log. env and service are
// mandatory: the dashboards scope every log query by them (the template
// variables expand to `env:<x> service:<y>`), and unlike an agent — which tags
// the log stream it collects itself — nothing downstream adds them to a log the
// coordinator POSTs itself, so a log without them matches no widget.
// kind and severity are per-entry and omitted when empty rather
// than sent as a valueless `kind:` tag.
func (c *Client) logTags(entry TelemetryLogEntry) string {
	tags := make([]string, 0, 4)
	if c.env != "" {
		tags = append(tags, "env:"+c.env)
	}
	if c.service != "" {
		tags = append(tags, "service:"+c.service)
	}
	if entry.Kind != "" {
		tags = append(tags, "kind:"+entry.Kind)
	}
	if entry.Severity != "" {
		tags = append(tags, "severity:"+entry.Severity)
	}
	return strings.Join(tags, ",")
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
		c.warn("datadog: failed to marshal log batch", "error", err)
		return
	}

	req, err := http.NewRequest(http.MethodPost, c.logsURL, bytes.NewReader(body))
	if err != nil {
		c.warn("datadog: failed to create log request", "error", err)
		return
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Dd-Api-Key", c.apiKey)

	resp, err := c.httpClient.Do(req)
	if err != nil {
		c.warn("datadog: logs API request failed", "error", err, "batch_size", len(batch))
		return
	}
	// The status alone does not say why: 403 is a bad key, 413 an oversized
	// batch, 400 a malformed payload, and the intake puts the reason in the
	// body — which was being read and discarded.
	respBody, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode >= 400 {
		c.warn("datadog: logs API returned error",
			"status", resp.StatusCode, "batch_size", len(batch),
			"body", truncate(string(respBody), 200))
	}
}

// emitDDEvent sends a Datadog Event for fatal telemetry entries so monitors
// can trigger alerts.
func (c *Client) emitDDEvent(entry TelemetryLogEntry) {
	if c.apiKey == "" {
		return
	}
	event := map[string]any{
		"title":      "[d-inference] Fatal: " + truncate(entry.Message, 100),
		"text":       entry.Message,
		"alert_type": "error",
		"source":     "d-inference",
		// c.env/c.service, not a fresh DD_ENV read: the event must carry the
		// same pair as the metrics and logs of the client that emitted it,
		// whether or not the Config came from the environment. A monitor that
		// scopes by service needs the tag as much as a dashboard does.
		"tags": []string{
			"source:" + entry.Source, "kind:" + entry.Kind,
			"env:" + c.env, "service:" + c.service,
		},
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
	req.Header.Set("Dd-Api-Key", c.apiKey)

	resp, err := c.httpClient.Do(req)
	if err != nil {
		c.warn("datadog: events API request failed", "error", err)
		return
	}
	respBody, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode >= 400 {
		c.warn("datadog: events API returned error",
			"status", resp.StatusCode, "body", truncate(string(respBody), 200))
	}
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}
