package promptcontract_test

import (
	"context"
	"encoding/json"
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

	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/sidecar"
	production "github.com/eigeninference/d-inference/coordinator/promptcontract"
)

// Mirror Rust server.rs's per-connection semaphore: accept, close immediately
// if full, and keep a permit until the entire keep-alive connection closes.
type reviewCappedListener struct {
	net.Listener
	permits chan struct{}
}
type reviewCappedConn struct {
	net.Conn
	permits chan struct{}
	once    sync.Once
}

func (c *reviewCappedConn) Close() error {
	err := c.Conn.Close()
	c.once.Do(func() { <-c.permits })
	return err
}
func (l *reviewCappedListener) Accept() (net.Conn, error) {
	for {
		c, e := l.Listener.Accept()
		if e != nil {
			return nil, e
		}
		select {
		case l.permits <- struct{}{}:
			return &reviewCappedConn{Conn: c, permits: l.permits}, nil
		default:
			_ = c.Close()
		}
	}
}

func TestReviewControlTrafficAtConfiguredWorkerCapacity(t *testing.T) {
	dir, e := os.MkdirTemp("/tmp", "review-control-")
	if e != nil {
		t.Fatal(e)
	}
	defer os.RemoveAll(dir)
	socket := filepath.Join(dir, "sidecar.sock")
	listener, e := net.Listen("unix", socket)
	if e != nil {
		t.Fatal(e)
	}
	if e = os.Chmod(socket, 0600); e != nil {
		t.Fatal(e)
	}
	release := make(chan struct{})
	var once sync.Once
	defer once.Do(func() { close(release) })
	var entered atomic.Int32
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/health" {
			_, _ = w.Write([]byte(`{"status":"ok"}`))
			return
		}
		_, _ = io.Copy(io.Discard, r.Body)
		entered.Add(1)
		<-release
		hash := strings.Repeat("a", 64)
		_ = json.NewEncoder(w).Encode(sidecar.Plan{PromptContractID: strings.Repeat("b", 64), PromptTokenCount: 257, BlockBoundaries: []sidecar.Boundary{{TokenCount: 256, ChainHash: hash}}, LastCompleteBlockHash: &hash})
	})}
	defer server.Close()
	go func() { _ = server.Serve(&reviewCappedListener{Listener: listener, permits: make(chan struct{}, 64)}) }()
	d := newClientDependencies(t)
	config := production.SupervisorConfig{Enabled: true, SocketPath: socket, MaxConcurrency: 64, MaxConnections: 64, RequestTimeout: 5 * time.Second, HealthTimeout: 200 * time.Millisecond,
		PlanAdmissions: d.planAdmissions, Transports: d.transports}
	s := production.NewSupervisor(config)
	defer s.Close()
	if e = config.Check(); e != nil {
		t.Fatal("configuration rejected", e)
	}
	c := s.Client()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 64)
	for i := 0; i < 64; i++ {
		go func() {
			_, e := c.Plan(ctx, sidecar.PlanInput{PromptContractID: strings.Repeat("b", 64), ScopeID: "tenant", Endpoint: sidecar.EndpointChatCompletions, Body: json.RawMessage(`{"messages":[{"role":"user","content":"synthetic"}]}`)})
			done <- e
		}()
	}
	target := int32(d.pool(sidecar.PoolPlan).MaxConnsPerHost)
	deadline := time.Now().Add(2 * time.Second)
	for entered.Load() < target && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if entered.Load() != target {
		t.Errorf("fixture did not saturate transport: got=%d target=%d", entered.Load(), target)
	}
	t.Logf("configured_workers=64 server_connection_cap=64 active_plans=%d", entered.Load())
	if e = c.Health(context.Background()); e != nil {
		t.Errorf("health starved by planning connections: %v", e)
	}
	controlCtx, controlCancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer controlCancel()
	req, _ := http.NewRequestWithContext(controlCtx, http.MethodGet, "http://promptsidecar/health", nil)
	resp, e := d.httpClient(sidecar.PoolControl).Do(req)
	if e != nil {
		t.Errorf("control starved by planning connections: %v", e)
	} else {
		_, _ = io.Copy(io.Discard, resp.Body)
		_ = resp.Body.Close()
	}
	once.Do(func() { close(release) })
	for i := 0; i < 64; i++ {
		<-done
	}
}
