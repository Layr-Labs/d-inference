package datadog

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestSendLogPostsOneEventWithTags(t *testing.T) {
	var got []ddLog
	status := http.StatusAccepted
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Dd-Api-Key") != "k" {
			t.Errorf("api key header = %q", r.Header.Get("Dd-Api-Key"))
		}
		b, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(b, &got)
		w.WriteHeader(status)
	}))
	defer srv.Close()
	c := &Client{apiKey: "k", logsURL: srv.URL, httpClient: &http.Client{Timeout: time.Second}, logger: slog.Default()}

	err := c.SendLog(context.Background(), TelemetryLogEntry{Source: "coordinator", Severity: "info", Kind: "erasure_log", Message: "account erased", Fields: map[string]any{"request_id": "r1"}}, "erasure_log:true")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].DDTags != "kind:erasure_log,severity:info,erasure_log:true" || got[0].Attrs["request_id"] != "r1" {
		t.Fatalf("posted = %+v", got)
	}
	status = http.StatusForbidden
	if err := c.SendLog(context.Background(), TelemetryLogEntry{Kind: "erasure_log"}); err == nil {
		t.Fatal("a 403 from the Logs API must be an error")
	}
	var unset *Client
	if unset.LogsEnabled() || unset.SendLog(context.Background(), TelemetryLogEntry{}) == nil {
		t.Fatal("a nil client must report logs disabled")
	}
}
