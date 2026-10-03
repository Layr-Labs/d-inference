package datadog

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
)

// LogsEnabled reports whether the Logs API is configured (DD_API_KEY set).
func (c *Client) LogsEnabled() bool { return c != nil && c.apiKey != "" }

// SendLog posts one log event to the Logs API now and reports whether
// Datadog accepted it. Unlike ForwardLog it does not batch, so a caller that
// must know the record was stored (the account erasure log) can retry.
// extraTags are added to the event's ddtags.
func (c *Client) SendLog(ctx context.Context, entry TelemetryLogEntry, extraTags ...string) error {
	if !c.LogsEnabled() {
		return fmt.Errorf("datadog: logs API not configured")
	}
	tags := append([]string{"kind:" + entry.Kind, "severity:" + entry.Severity}, extraTags...)
	log := ddLog{
		DDSource: entry.Source,
		DDTags:   strings.Join(tags, ","),
		Service:  "d-inference-coordinator",
		Status:   mapSeverityToStatus(entry.Severity),
		Message:  entry.Message,
		Attrs:    entry.Fields,
	}
	body, err := json.Marshal([]ddLog{log})
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.logsURL, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Dd-Api-Key", c.apiKey)
	resp, err := c.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("datadog: logs API request: %w", err)
	}
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<16))
	resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("datadog: logs API returned %d", resp.StatusCode)
	}
	return nil
}
