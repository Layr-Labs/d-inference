package datadog_test

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/datadog"
)

// intakeLog is the Logs API v2 event shape the client posts.
type intakeLog struct {
	DDTags string         `json:"ddtags"`
	Attrs  map[string]any `json:"attributes"`
}

func TestSendLogPostsOneEventWithTags(t *testing.T) {
	var got []intakeLog
	var path string
	status := http.StatusAccepted
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Dd-Api-Key") != "k" {
			t.Errorf("api key header = %q", r.Header.Get("Dd-Api-Key"))
		}
		path = r.URL.Path
		b, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(b, &got)
		w.WriteHeader(status)
	}))
	defer srv.Close()
	c := newTestClient(t, production.Config{APIKey: "k", HTTPClient: intakeClient(t, srv)})

	if !c.LogsEnabled() {
		t.Fatal("a client with an API key must report logs enabled")
	}
	err := c.SendLog(context.Background(), production.TelemetryLogEntry{Source: "coordinator", Severity: "info", Kind: "erasure_log", Message: "account erased", Fields: map[string]any{"request_id": "r1"}}, "erasure_log:true")
	if err != nil {
		t.Fatal(err)
	}
	if path != "/api/v2/logs" || len(got) != 1 || got[0].DDTags != "kind:erasure_log,severity:info,erasure_log:true" || got[0].Attrs["request_id"] != "r1" {
		t.Fatalf("posted %s = %+v", path, got)
	}
	status = http.StatusForbidden
	if err := c.SendLog(context.Background(), production.TelemetryLogEntry{Kind: "erasure_log"}); err == nil {
		t.Fatal("a 403 from the Logs API must be an error")
	}
	var unset *production.Client
	if unset.LogsEnabled() || unset.SendLog(context.Background(), production.TelemetryLogEntry{}) == nil {
		t.Fatal("a nil client must report logs disabled")
	}
	if keyless := newTestClient(t, production.Config{}); keyless.LogsEnabled() {
		t.Fatal("a client without an API key must report logs disabled")
	}
}
