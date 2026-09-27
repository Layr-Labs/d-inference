package promptcontract

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestPlanningConnectionBudget(t *testing.T) {
	for _, tc := range []struct{ workers, connections, slots int }{
		{0, 0, 4}, {4, 64, 4}, {64, 64, 60}, {64, 5, 1},
		{128, 68, 64}, {128, 128, 64}, {4, 4, 0}, {4, 1, 0},
	} {
		t.Run(fmt.Sprintf("%d_workers_%d_connections", tc.workers, tc.connections), func(t *testing.T) {
			s := NewSupervisor(SupervisorConfig{Enabled: true, MaxConcurrency: tc.workers, MaxConnections: tc.connections})
			defer s.Close()
			c := s.Client()
			if got := cap(c.planAdmission.active); got != tc.slots {
				t.Fatalf("planning slots=%d want=%d", got, tc.slots)
			}
			if c.planTransport.MaxConnsPerHost != max(1, tc.slots) {
				t.Fatal("transport and admission budgets disagree")
			}
			if tc.slots == 0 {
				if !errors.Is(s.config.Check(), ErrInvalidConfig) {
					t.Fatal("unsafe total accepted")
				}
				if _, err := c.planAdmission.acquire(context.Background(), 1); !errors.Is(err, ErrSidecarUnavailable) {
					t.Fatal("invalid standalone budget must fail closed without dialing or waiting")
				}
				if c.planAdmission.pending != 0 || c.planAdmission.bytes != 0 {
					t.Fatal("disabled admission retained input")
				}
			} else {
				if err := s.config.Check(); err != nil {
					t.Fatal(err)
				}
				if c.planTransport.MaxConnsPerHost+c.healthTransport.MaxConnsPerHost+c.controlTransport.MaxConnsPerHost > s.config.MaxConnections {
					t.Fatal("HTTP pools exceed Rust's lifetime connection budget")
				}
			}
			if tc.workers > 0 && s.config.MaxConcurrency != tc.workers {
				t.Fatal("worker capacity changed")
			}
			if tc.connections > 0 && s.config.MaxConnections != tc.connections {
				t.Fatal("server connection limit changed")
			}
		})
	}
}

func TestControlReconnectsDuringPlanningSaturation(t *testing.T) {
	for _, connections := range []int{5, 8, 64} {
		t.Run(fmt.Sprint(connections), func(t *testing.T) {
			dir, err := os.MkdirTemp("/tmp", "plan-control-")
			if err != nil {
				t.Fatal(err)
			}
			defer os.RemoveAll(dir)
			path := filepath.Join(dir, "sidecar.sock")
			listener, err := net.Listen("unix", path)
			if err != nil {
				t.Fatal(err)
			}
			if err := os.Chmod(path, 0600); err != nil {
				t.Fatal(err)
			}
			permits := make(chan struct{}, connections)
			release := make(chan struct{})
			var once sync.Once
			var entered atomic.Int32
			server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/health" || r.URL.Path == "/control-probe" {
					_, _ = w.Write([]byte(`{"status":"ok"}`))
					return
				}
				_, _ = io.Copy(io.Discard, r.Body)
				entered.Add(1)
				<-release
				hash := strings.Repeat("a", 64)
				_ = json.NewEncoder(w).Encode(Plan{PromptContractID: strings.Repeat("b", 64), PromptTokenCount: 257,
					BlockBoundaries: []Boundary{{TokenCount: 256, ChainHash: hash}}, LastCompleteBlockHash: &hash})
			})}
			defer server.Close()
			defer once.Do(func() { close(release) })
			go func() { _ = server.Serve(&reviewCappedListener{Listener: listener, permits: permits}) }()
			s := NewSupervisor(SupervisorConfig{Enabled: true, SocketPath: path, MaxConcurrency: 64,
				MaxConnections: connections, RequestTimeout: 10 * time.Second, HealthTimeout: time.Second})
			defer s.Close()
			if err := s.config.Check(); err != nil {
				t.Fatal(err)
			}
			c := s.Client()
			slots := cap(c.planAdmission.active)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			done := make(chan error, slots)
			for range slots {
				go func() {
					_, err := c.Plan(ctx, PlanInput{PromptContractID: strings.Repeat("b", 64), ScopeID: "synthetic-scope",
						Endpoint: EndpointChatCompletions, Body: json.RawMessage(`{"messages":[]}`)})
					done <- err
				}()
			}
			wait := func(predicate func() bool) {
				t.Helper()
				deadline := time.Now().Add(2 * time.Second)
				for !predicate() && time.Now().Before(deadline) {
					time.Sleep(time.Millisecond)
				}
				if !predicate() {
					t.Fatal("fixture did not reach expected connection state")
				}
			}
			wait(func() bool { return entered.Load() == int32(slots) })
			for range 3 {
				if err := c.Health(ctx); err != nil {
					t.Fatalf("new/reconnected health: %v", err)
				}
				req, _ := http.NewRequestWithContext(ctx, http.MethodGet, "http://promptsidecar/control-probe", nil)
				resp, err := c.controlHTTP.Do(req)
				if err != nil {
					t.Fatalf("new/reconnected control: %v", err)
				}
				_, err = io.Copy(io.Discard, resp.Body)
				_ = resp.Body.Close()
				if err != nil || resp.StatusCode != http.StatusOK {
					t.Fatal("control response failed", err)
				}
				c.healthTransport.CloseIdleConnections()
				c.controlTransport.CloseIdleConnections()
				wait(func() bool { return len(permits) == slots })
			}
			once.Do(func() { close(release) })
			for range slots {
				if err := <-done; err != nil {
					t.Fatal(err)
				}
			}
			if c.planAdmission.pending != 0 || c.planAdmission.bytes != 0 || len(c.planAdmission.active) != 0 {
				t.Fatal("completed calls did not refund admission")
			}
		})
	}
}
