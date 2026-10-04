package promptcontract

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
)

func TestValidatePreloadReport(t *testing.T) {
	a := strings.Repeat("a", 64)
	b := strings.Repeat("b", 64)
	requested := []string{a, b}
	valid := PreloadReport{
		Status: "degraded", Ready: false, Requested: 2, Warm: 1, Failed: 1,
		Results: []PreloadResult{{PromptContractID: a, Status: "warm"}, {PromptContractID: b, Status: "failed"}},
	}
	if err := validatePreloadReport(requested, valid); err != nil {
		t.Fatalf("valid degraded report rejected: %v", err)
	}
	tests := []struct {
		name   string
		mutate func(*PreloadReport)
	}{
		{"unknown status", func(r *PreloadReport) { r.Status = "done" }},
		{"requested count mismatch", func(r *PreloadReport) { r.Requested = 3 }},
		{"result count mismatch", func(r *PreloadReport) { r.Results = r.Results[:1] }},
		{"negative warm", func(r *PreloadReport) { r.Warm, r.Cold = -1, 2 }},
		{"totals do not add up", func(r *PreloadReport) { r.Warm = 2 }},
		{"ready with failures", func(r *PreloadReport) { r.Ready = true }},
		{"results out of order", func(r *PreloadReport) { r.Results[0], r.Results[1] = r.Results[1], r.Results[0] }},
		{"unknown result status", func(r *PreloadReport) { r.Results[0].Status = "hot" }},
		{"counts disagree with results", func(r *PreloadReport) { r.Warm, r.Cold = 0, 1 }},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			report := valid
			report.Results = append([]PreloadResult(nil), valid.Results...)
			test.mutate(&report)
			if err := validatePreloadReport(requested, report); !errors.Is(err, ErrPreloadRejected) {
				t.Fatalf("error = %v, want ErrPreloadRejected", err)
			}
		})
	}
}

func TestClientPreloadRejectsBadContractListsWithoutCallingSidecar(t *testing.T) {
	var calls atomic.Int64
	server, socket := startUnixHTTPServer(t, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls.Add(1)
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer server.Close()
	client := NewClient(ClientConfig{SocketPath: socket, MaxPreloadIDs: 2})
	defer client.Close()
	a := strings.Repeat("a", 64)
	tests := map[string][]string{
		"empty":     nil,
		"too many":  {a, strings.Repeat("b", 64), strings.Repeat("c", 64)},
		"bad hash":  {"not-a-hash"},
		"duplicate": {a, a},
	}
	for name, ids := range tests {
		if _, err := client.Preload(context.Background(), ids); !errors.Is(err, ErrPreloadRejected) {
			t.Fatalf("%s: error = %v, want ErrPreloadRejected", name, err)
		}
	}
	var nilClient *Client
	if _, err := nilClient.Preload(context.Background(), []string{a}); !errors.Is(err, ErrPreloadRejected) {
		t.Fatalf("nil client error = %v", err)
	}
	if calls.Load() != 0 {
		t.Fatalf("sidecar called %d times for rejected input", calls.Load())
	}
}
