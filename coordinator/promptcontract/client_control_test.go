package promptcontract

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
)

func TestClientControlPlaneUsesIndependentHealthPool(t *testing.T) {
	planStarted := make(chan struct{})
	releasePlan := make(chan struct{})
	server, socket := startUnixHTTPServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/health":
			_ = json.NewEncoder(w).Encode(ReadinessStatus{Status: "ok", Ready: true})
		case "/v1/plan":
			close(planStarted)
			<-releasePlan
			http.Error(w, "late", http.StatusServiceUnavailable)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	client := NewClient(ClientConfig{
		SocketPath: socket, RequestTimeout: 500 * time.Millisecond, HealthTimeout: 50 * time.Millisecond,
	})
	defer client.Close()
	planDone := make(chan struct{})
	go func() {
		defer close(planDone)
		_, _ = client.Plan(context.Background(), PlanInput{
			PromptContractID: strings.Repeat("a", 64), ScopeID: "scope",
			Endpoint: EndpointChatCompletions, Body: json.RawMessage(`{"messages":[]}`),
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
	elapsed := time.Since(started)
	close(releasePlan)
	if elapsed >= 100*time.Millisecond {
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
		_ = json.NewEncoder(w).Encode(PreloadReport{
			Status: "ready", Ready: true, Requested: 1, Cold: 1,
			Results: []PreloadResult{{PromptContractID: request.PromptContractIDs[0], Status: "cold"}},
			Metrics: SidecarMetrics{
				Plans:         SidecarPlanMetrics{Succeeded: 7},
				ContractLoads: SidecarContractMetrics{Cold: 1},
				Preloads:      SidecarPreloadMetrics{Runs: 1, Contracts: 1},
			},
		})
	}))
	defer server.Close()
	client := NewClient(ClientConfig{SocketPath: socket, MaxPreloadIDs: 1})
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
	if _, err := client.Preload(context.Background(), []string{contractID, contractID}); !errors.Is(err, ErrPreloadRejected) {
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
