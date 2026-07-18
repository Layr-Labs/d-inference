package promptcontract

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestClientUsesPersistentUnixHTTPAndFailsCold(t *testing.T) {
	temp, err := os.MkdirTemp("/tmp", "prompt-client-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(temp) })
	socket := filepath.Join(temp, "sidecar.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(socket, 0o600); err != nil {
		t.Fatal(err)
	}
	var connections atomic.Int64
	server := &http.Server{
		ConnState: func(_ net.Conn, state http.ConnState) {
			if state == http.StateNew {
				connections.Add(1)
			}
		},
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path == "/health" {
				_, _ = w.Write([]byte(`{"status":"ok"}`))
				return
			}
			var request struct {
				ScopeID string `json:"scope_id"`
			}
			_ = json.NewDecoder(r.Body).Decode(&request)
			if request.ScopeID == "overloaded" {
				http.Error(w, "at capacity", http.StatusServiceUnavailable)
				return
			}
			if request.ScopeID == "slow" {
				time.Sleep(200 * time.Millisecond)
			}
			hash := strings.Repeat("a", 64)
			if request.ScopeID == "malformed" {
				hash = "not-a-hash"
			}
			if request.ScopeID == "plaintext-response" {
				_, _ = w.Write([]byte(`{
					"prompt_contract_id":"` + strings.Repeat("b", 64) + `",
					"normalized_body":{"messages":[]},
					"prompt_token_count":257,
					"block_boundaries":[{"token_count":256,"chain_hash":"` + hash + `"}],
					"last_complete_block_hash":"` + hash + `"
				}`))
				return
			}
			_ = json.NewEncoder(w).Encode(Plan{
				PromptContractID:      strings.Repeat("b", 64),
				PromptTokenCount:      257,
				BlockBoundaries:       []Boundary{{TokenCount: 256, ChainHash: hash}},
				LastCompleteBlockHash: &hash,
			})
		}),
	}
	go func() { _ = server.Serve(listener) }()
	defer server.Close()

	client := NewClient(ClientConfig{
		SocketPath: socket, RequestTimeout: 100 * time.Millisecond,
	})
	defer client.Close()
	input := PlanInput{
		PromptContractID: strings.Repeat("b", 64),
		ScopeID:          "scope",
		Endpoint:         EndpointChatCompletions,
		Body:             json.RawMessage(`{"model":"m","messages":[]}`),
	}
	for range 2 {
		plan, err := client.Plan(context.Background(), input)
		if err != nil {
			t.Fatal(err)
		}
		if !plan.Participating {
			t.Fatal("valid plan did not participate")
		}
	}
	if connections.Load() != 1 {
		t.Fatalf("client opened %d connections for two sequential plans, want 1", connections.Load())
	}

	input.ScopeID = "malformed"
	if plan := client.PlanFailCold(context.Background(), input); plan.Participating {
		t.Fatal("malformed sidecar response participated")
	}
	input.ScopeID = "plaintext-response"
	if plan := client.PlanFailCold(context.Background(), input); plan.Participating {
		t.Fatal("response containing normalized_body participated")
	}
	input.ScopeID = "slow"
	started := time.Now()
	if plan := client.PlanFailCold(context.Background(), input); plan.Participating {
		t.Fatal("timed-out sidecar response participated")
	}
	if elapsed := time.Since(started); elapsed > 300*time.Millisecond {
		t.Fatalf("deadline was not bounded: %s", elapsed)
	}
	input.ScopeID = "overloaded"
	if plan := client.PlanFailCold(context.Background(), input); plan.Participating {
		t.Fatal("overloaded sidecar participated")
	}
	if stats := client.Stats(); stats.Timeouts != 1 || stats.Overloads != 1 {
		t.Fatalf("client stats=%+v, want one timeout and one overload", stats)
	}
	if err := server.Close(); err != nil {
		t.Fatal(err)
	}
	input.ScopeID = "sidecar-down"
	if plan := client.PlanFailCold(context.Background(), input); plan.Participating {
		t.Fatal("unavailable sidecar participated")
	}
}
