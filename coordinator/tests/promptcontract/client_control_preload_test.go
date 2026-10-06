package promptcontract_test

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"

	sidecar "github.com/eigeninference/d-inference/coordinator/internal/promptcontract/sidecar"
)

func TestClientPreloadValidatesReport(t *testing.T) {
	a := strings.Repeat("a", 64)
	b := strings.Repeat("b", 64)
	requested := []string{a, b}
	valid := sidecar.PreloadReport{
		Status: "degraded", Ready: false, Requested: 2, Warm: 1, Failed: 1,
		Results: []sidecar.PreloadResult{{PromptContractID: a, Status: "warm"}, {PromptContractID: b, Status: "failed"}},
	}
	preload := func(t *testing.T, report sidecar.PreloadReport) (sidecar.PreloadReport, error) {
		t.Helper()
		server, socket := startUnixHTTPServer(t, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			_ = json.NewEncoder(w).Encode(report)
		}))
		defer server.Close()
		client := sidecar.NewClient(sidecar.ClientConfig{SocketPath: socket})
		defer client.Close()
		return client.Preload(context.Background(), requested)
	}

	got, err := preload(t, valid)
	if err != nil {
		t.Fatalf("valid degraded report rejected: %v", err)
	}
	if !reflect.DeepEqual(got.Results, valid.Results) || got.Status != "degraded" || got.Ready {
		t.Fatalf("report = %+v", got)
	}
	tests := []struct {
		name   string
		mutate func(*sidecar.PreloadReport)
	}{
		{"unknown status", func(r *sidecar.PreloadReport) { r.Status = "done" }},
		{"requested count mismatch", func(r *sidecar.PreloadReport) { r.Requested = 3 }},
		{"result count mismatch", func(r *sidecar.PreloadReport) { r.Results = r.Results[:1] }},
		{"negative warm", func(r *sidecar.PreloadReport) { r.Warm, r.Cold = -1, 2 }},
		{"totals do not add up", func(r *sidecar.PreloadReport) { r.Warm = 2 }},
		{"ready with failures", func(r *sidecar.PreloadReport) { r.Ready = true }},
		{"results out of order", func(r *sidecar.PreloadReport) { r.Results[0], r.Results[1] = r.Results[1], r.Results[0] }},
		{"unknown result status", func(r *sidecar.PreloadReport) { r.Results[0].Status = "hot" }},
		{"counts disagree with results", func(r *sidecar.PreloadReport) { r.Warm, r.Cold = 0, 1 }},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			report := valid
			report.Results = append([]sidecar.PreloadResult(nil), valid.Results...)
			test.mutate(&report)
			got, err := preload(t, report)
			if !errors.Is(err, sidecar.ErrPreloadRejected) {
				t.Fatalf("error = %v, want ErrPreloadRejected", err)
			}
			if !reflect.DeepEqual(got, sidecar.PreloadReport{}) {
				t.Fatalf("report = %+v, want zero value on error", got)
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
	client := sidecar.NewClient(sidecar.ClientConfig{SocketPath: socket, MaxPreloadIDs: 2})
	defer client.Close()
	a := strings.Repeat("a", 64)
	tests := map[string][]string{
		"empty":     nil,
		"too many":  {a, strings.Repeat("b", 64), strings.Repeat("c", 64)},
		"bad hash":  {"not-a-hash"},
		"duplicate": {a, a},
	}
	for name, ids := range tests {
		if _, err := client.Preload(context.Background(), ids); !errors.Is(err, sidecar.ErrPreloadRejected) {
			t.Fatalf("%s: error = %v, want ErrPreloadRejected", name, err)
		}
	}
	var nilClient *sidecar.Client
	if _, err := nilClient.Preload(context.Background(), []string{a}); !errors.Is(err, sidecar.ErrPreloadRejected) {
		t.Fatalf("nil client error = %v", err)
	}
	if calls.Load() != 0 {
		t.Fatalf("sidecar called %d times for rejected input", calls.Load())
	}
}
