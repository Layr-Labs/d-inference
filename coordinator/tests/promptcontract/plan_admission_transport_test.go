package promptcontract_test

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/sidecar"
)

func admissionFixtureInput() sidecar.PlanInput {
	return sidecar.PlanInput{PromptContractID: strings.Repeat("b", 64), ScopeID: "tenant-a", Endpoint: sidecar.EndpointChatCompletions, Body: json.RawMessage(`{"messages":[{"role":"user","content":"synthetic"}]}`)}
}

func admissionFixturePlan() sidecar.Plan {
	hash := strings.Repeat("a", 64)
	return sidecar.Plan{Participating: true, PromptContractID: strings.Repeat("b", 64), PromptTokenCount: 257,
		BlockBoundaries: []sidecar.Boundary{{TokenCount: 256, ChainHash: hash}}, LastCompleteBlockHash: &hash}
}

// admissionClient is a standalone client with the dependencies it constructed.
type admissionClient struct {
	*sidecar.Client
	dependencies *clientDependencies
}

func admissionTestClient(t *testing.T, workers int, handler http.HandlerFunc) *admissionClient {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "planner-admission-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	socket := filepath.Join(dir, "planner.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(socket, 0o600); err != nil {
		t.Fatal(err)
	}
	server := &http.Server{Handler: handler}
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(func() { _ = server.Close() })
	d := newClientDependencies(t)
	client := sidecar.NewClient(sidecar.ClientConfig{SocketPath: socket, MaxConcurrency: workers,
		PlanAdmissions: d.planAdmissions, Transports: d.transports})
	t.Cleanup(client.Close)
	return &admissionClient{Client: client, dependencies: d}
}

func waitForPendingPlans(t *testing.T, c *admissionClient, n int) {
	t.Helper()
	admission := c.dependencies.planAdmission()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		got := admission.PendingPlans()
		if got == n {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("pending plans did not reach %d", n)
}

func TestPlannerBurstWaitsForWorkersWithoutBlockingHealth(t *testing.T) {
	var refused atomic.Int32
	workers := make(chan struct{}, 4)
	release := make(chan struct{})
	var once sync.Once
	defer once.Do(func() { close(release) })
	c := admissionTestClient(t, 4, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/health" {
			_, _ = w.Write([]byte(`{"status":"ok"}`))
			return
		}
		_, _ = io.Copy(io.Discard, r.Body)
		select {
		case workers <- struct{}{}:
		default:
			refused.Add(1)
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		<-release
		// Like the Rust planner, release CPU capacity before sending the result.
		<-workers
		_ = json.NewEncoder(w).Encode(admissionFixturePlan())
	})
	errors := make(chan error, 40)
	plans := make(chan sidecar.Plan, 40)
	for i := range 40 {
		go func() {
			input := admissionFixtureInput()
			if i%2 == 1 {
				input.ScopeID = "tenant-b"
			}
			plan, err := c.Plan(context.Background(), input)
			plans <- plan
			errors <- err
		}()
	}
	waitForPendingPlans(t, c, 40)
	if err := c.Health(context.Background()); err != nil {
		t.Fatal(err)
	}
	response, err := c.dependencies.httpClient(sidecar.PoolControl).Get("http://promptsidecar/health")
	if err != nil {
		t.Fatal(err)
	}
	_ = response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatal("control traffic blocked")
	}
	once.Do(func() { close(release) })
	for range 40 {
		if err := <-errors; err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(<-plans, admissionFixturePlan()) {
			t.Fatal("plan changed")
		}
	}
	if refused.Load() != 0 {
		t.Fatalf("sidecar refused %d requests", refused.Load())
	}
	waitForPendingPlans(t, c, 0)
	if c.Stats().Overloads != 0 || c.Stats().Timeouts != 0 {
		t.Fatal(c.Stats())
	}
}

func TestQueuedPlanCancellationNeverReachesSidecar(t *testing.T) {
	var calls atomic.Int32
	release := make(chan struct{})
	var once sync.Once
	defer once.Do(func() { close(release) })
	c := admissionTestClient(t, 1, func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		calls.Add(1)
		<-release
		_ = json.NewEncoder(w).Encode(admissionFixturePlan())
	})
	first := make(chan error, 1)
	go func() { _, err := c.Plan(context.Background(), admissionFixtureInput()); first <- err }()
	waitForPendingPlans(t, c, 1)
	ctx, cancel := context.WithCancel(context.Background())
	queued := make(chan error, 1)
	go func() { _, err := c.Plan(ctx, admissionFixtureInput()); queued <- err }()
	waitForPendingPlans(t, c, 2)
	cancel()
	if <-queued == nil {
		t.Fatal("cancelled waiter succeeded")
	}
	expiring, stop := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer stop()
	if p := c.PlanFailCold(expiring, admissionFixtureInput()); p.Participating {
		t.Fatal("expired waiter participated")
	}
	once.Do(func() { close(release) })
	if err := <-first; err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 1 {
		t.Fatalf("queued cancellation forwarded: calls=%d", calls.Load())
	}
	if _, err := c.Plan(context.Background(), admissionFixtureInput()); err != nil {
		t.Fatal(err)
	}
	waitForPendingPlans(t, c, 0)
	if calls.Load() != 2 || c.Stats().Timeouts != 1 {
		t.Fatal("recovery/accounting changed")
	}
}

func TestCancelledActivePlannerWorkStillFailsColdUntilBackendDrains(t *testing.T) {
	permit := make(chan struct{}, 1)
	entered, release, drained := make(chan struct{}), make(chan struct{}), make(chan struct{})
	var calls atomic.Int32
	var once sync.Once
	defer once.Do(func() { close(release) })
	c := admissionTestClient(t, 1, func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		select {
		case permit <- struct{}{}:
		default:
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		if calls.Add(1) == 1 {
			close(entered)
			<-release // blocking CPU work can outlive the cancelled HTTP request
			<-permit
			close(drained)
		} else {
			<-permit
		}
		_ = json.NewEncoder(w).Encode(admissionFixturePlan())
	})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	first := make(chan error, 1)
	go func() { _, err := c.Plan(ctx, admissionFixtureInput()); first <- err }()
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("worker did not start")
	}
	cancel()
	if <-first == nil {
		t.Fatal("cancelled active call succeeded")
	}
	if p := c.PlanFailCold(context.Background(), admissionFixtureInput()); p.Participating {
		t.Fatal("busy backend participated")
	}
	once.Do(func() { close(release) })
	<-drained
	if p, err := c.Plan(context.Background(), admissionFixtureInput()); err != nil || !p.Participating {
		t.Fatalf("post-drain recovery: %v", err)
	}
	waitForPendingPlans(t, c, 0)
	if c.Stats().Overloads != 1 {
		t.Fatal(c.Stats())
	}
}
