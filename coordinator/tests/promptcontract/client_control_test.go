package promptcontract_test

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	sidecar "github.com/eigeninference/d-inference/coordinator/internal/promptcontract/sidecar"
)

func TestClientControlPlaneUsesIndependentHealthPool(t *testing.T) {
	planStarted := make(chan struct{})
	server, socket := startUnixHTTPServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/health":
			_ = json.NewEncoder(w).Encode(sidecar.ReadinessStatus{Status: "ok", Ready: true})
		case "/v1/plan":
			close(planStarted)
			time.Sleep(200 * time.Millisecond)
			http.Error(w, "late", http.StatusServiceUnavailable)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	client := sidecar.NewClient(sidecar.ClientConfig{
		SocketPath: socket, RequestTimeout: 500 * time.Millisecond, HealthTimeout: 50 * time.Millisecond,
	})
	defer client.Close()
	planDone := make(chan struct{})
	go func() {
		defer close(planDone)
		_, _ = client.Plan(context.Background(), sidecar.PlanInput{
			PromptContractID: strings.Repeat("a", 64), ScopeID: "scope",
			Endpoint: sidecar.EndpointChatCompletions, Body: json.RawMessage(`{"messages":[]}`),
		})
	}()
	select {
	case <-planStarted:
	case <-time.After(time.Second):
		t.Fatal("plan request did not start")
	}
	started := time.Now()
	if err := client.Health(context.Background()); err != nil {
		t.Fatal(err)
	}
	if elapsed := time.Since(started); elapsed >= 100*time.Millisecond {
		t.Fatalf("health was blocked behind plan traffic: %s", elapsed)
	}
	<-planDone
}

func TestClientPreloadValidatesOrderedReportAndCachesMetrics(t *testing.T) {
	contractID := strings.Repeat("b", 64)
	server, socket := startUnixHTTPServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/preload" {
			http.NotFound(w, r)
			return
		}
		var request struct {
			PromptContractIDs []string `json:"prompt_contract_ids"`
		}
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Error(err)
		}
		_ = json.NewEncoder(w).Encode(sidecar.PreloadReport{
			Status: "ready", Ready: true, Requested: 1, Cold: 1,
			Results: []sidecar.PreloadResult{{PromptContractID: request.PromptContractIDs[0], Status: "cold"}},
			Metrics: sidecar.SidecarMetrics{
				Plans:         sidecar.SidecarPlanMetrics{Succeeded: 7},
				ContractLoads: sidecar.SidecarContractMetrics{Cold: 1},
				Preloads:      sidecar.SidecarPreloadMetrics{Runs: 1, Contracts: 1},
			},
		})
	}))
	defer server.Close()
	client := sidecar.NewClient(sidecar.ClientConfig{SocketPath: socket, MaxPreloadIDs: 1})
	defer client.Close()

	report, err := client.Preload(context.Background(), []string{contractID})
	if err != nil {
		t.Fatal(err)
	}
	if !report.Ready || report.Cold != 1 || report.Results[0].PromptContractID != contractID {
		t.Fatalf("report=%+v", report)
	}
	metrics := client.SidecarMetrics()
	if metrics.Plans.Succeeded != 7 || metrics.ContractLoads.Cold != 1 || metrics.Preloads.Runs != 1 {
		t.Fatalf("cached metrics=%+v", metrics)
	}
	if _, err := client.Preload(context.Background(), []string{contractID, contractID}); !errors.Is(err, sidecar.ErrPreloadRejected) {
		t.Fatalf("duplicate preload error=%v", err)
	}
}

func startUnixHTTPServer(t *testing.T, handler http.Handler) (*http.Server, string) {
	t.Helper()
	directory, err := os.MkdirTemp("/tmp", "prompt-control-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(directory) })
	socket := filepath.Join(directory, "sidecar.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(socket, 0o600); err != nil {
		t.Fatal(err)
	}
	server := &http.Server{Handler: handler}
	go func() { _ = server.Serve(listener) }()
	return server, socket
}
