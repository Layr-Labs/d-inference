package inference_test

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
)

type privacyPlanObservation struct {
	Contract string          `json:"prompt_contract_id"`
	Scope    string          `json:"scope_id"`
	Endpoint string          `json:"endpoint"`
	Body     json.RawMessage `json:"body"`
}

// Observe the synthetic request without transforming it. Real Rust still owns
// parsing, rendering, tokenization, counters and the returned plan.
type privacyPlanProxy struct {
	mu           sync.Mutex
	observations []privacyPlanObservation
	client       *promptcontract.Client
	server       *http.Server
	done         chan error
}

func newPrivacyPlanProxy(t *testing.T, upstream *http.Client) *privacyPlanProxy {
	t.Helper()
	parent := os.Getenv("DARKBLOOM_PLANNING_TEST_UDS_PARENT")
	resolved, err := filepath.EvalSymlinks(parent)
	info, statErr := os.Lstat(parent)
	if err != nil || statErr != nil || !filepath.IsAbs(parent) || resolved != parent ||
		!info.IsDir() || info.Mode().Perm()&0o077 != 0 {
		t.Fatal("requires the allocated canonical private UDS parent")
	}
	root, err := os.MkdirTemp(parent, "cp-joint-")
	if err != nil {
		t.Fatal(err)
	}
	p := &privacyPlanProxy{done: make(chan error, 1)}
	t.Cleanup(func() {
		if p.client != nil {
			p.client.Close()
		}
		if p.server != nil {
			_ = p.server.Close()
			select {
			case <-p.done:
			case <-time.After(3 * time.Second):
				t.Error("planning observation proxy did not join")
			}
		}
		if err := os.RemoveAll(root); err != nil {
			t.Errorf("owned planning observation cleanup: %v", err)
		}
	})
	socket := filepath.Join(root, "p.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(socket, 0o600); err != nil {
		_ = listener.Close()
		t.Fatal(err)
	}
	p.server = &http.Server{ReadHeaderTimeout: time.Second, Handler: http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodPost || request.URL.Path != "/v1/plan" {
			http.NotFound(w, request)
			return
		}
		wire, err := io.ReadAll(http.MaxBytesReader(w, request.Body, promptcontract.DefaultMaxRequestBytes))
		if err != nil {
			http.Error(w, "bounded observation read", http.StatusRequestEntityTooLarge)
			return
		}
		var observation privacyPlanObservation
		if json.Unmarshal(wire, &observation) != nil {
			http.Error(w, "invalid observation envelope", http.StatusBadRequest)
			return
		}
		observation.Body = append(json.RawMessage(nil), observation.Body...)
		p.mu.Lock()
		if len(p.observations) >= 128 {
			p.mu.Unlock()
			http.Error(w, "observation bound exceeded", http.StatusServiceUnavailable)
			return
		}
		p.observations = append(p.observations, observation)
		p.mu.Unlock()
		forward, err := http.NewRequestWithContext(request.Context(), http.MethodPost, "http://promptsidecar/v1/plan", bytes.NewReader(wire))
		if err != nil {
			http.Error(w, "observation forward request", http.StatusBadGateway)
			return
		}
		forward.Header.Set("Content-Type", "application/json")
		response, err := upstream.Do(forward)
		if err != nil {
			http.Error(w, "real planner transport failed", http.StatusBadGateway)
			return
		}
		defer response.Body.Close()
		body, err := io.ReadAll(io.LimitReader(response.Body, promptcontract.DefaultMaxResponseBytes+1))
		if err != nil || len(body) > promptcontract.DefaultMaxResponseBytes {
			http.Error(w, "bounded planner response", http.StatusBadGateway)
			return
		}
		w.Header().Set("Content-Type", response.Header.Get("Content-Type"))
		w.WriteHeader(response.StatusCode)
		_, _ = w.Write(body)
	})}
	go func() { p.done <- p.server.Serve(listener) }()
	p.client = promptcontract.NewClient(promptcontract.ClientConfig{SocketPath: socket,
		MaxConcurrency: 1, MaxConnections: 8, RequestTimeout: 2 * time.Second})
	return p
}

func (p *privacyPlanProxy) count() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return len(p.observations)
}

func (p *privacyPlanProxy) since(t *testing.T, before int) []privacyPlanObservation {
	t.Helper()
	p.mu.Lock()
	defer p.mu.Unlock()
	if before < 0 || before > len(p.observations) {
		t.Fatal("invalid observation cursor")
	}
	return append([]privacyPlanObservation(nil), p.observations[before:]...)
}

func privacyPlanRequestContext(parent context.Context) (context.Context, context.CancelFunc) {
	return context.WithTimeout(parent, 5*time.Second)
}
