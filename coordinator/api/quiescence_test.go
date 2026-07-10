package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestQuiescenceReport_ReadyWhenEmpty(t *testing.T) {
	s := &Server{}
	report := s.quiescenceReport()
	if !report.Ready {
		t.Fatalf("empty server should be ready: %+v", report)
	}
	if report.HTTPInflight != 0 || report.CompletionInflight != 0 {
		t.Fatalf("%+v", report)
	}
}

func TestQuiescenceReport_JSONShape(t *testing.T) {
	s := &Server{}
	report := s.quiescenceReport()
	b, err := json.Marshal(report)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{
		"http_inflight", "completion_inflight", "service_reservations",
		"settlement_held", "provider_pending", "queued_requests", "draining", "ready",
	} {
		if _, ok := m[k]; !ok {
			t.Fatalf("missing key %q in %s", k, b)
		}
	}
	_ = http.StatusOK
	_ = httptest.NewRequest
}
