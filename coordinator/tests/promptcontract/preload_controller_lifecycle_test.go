package promptcontract_test

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/catalog"
	identity "github.com/eigeninference/d-inference/coordinator/internal/promptcontract/identity"
	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/preload"
	sidecar "github.com/eigeninference/d-inference/coordinator/internal/promptcontract/sidecar"
)

// preloadTestSidecar serves /v1/preload with an all-cold report and /metrics
// with a valid status, and counts calls to each path.
type preloadTestSidecar struct {
	preloads atomic.Int64
	metrics  atomic.Int64
	// preloadStatus, when not zero, is returned instead of a report.
	preloadStatus atomic.Int64
	// metricsStatus, when not zero, is returned instead of a metrics body.
	metricsStatus atomic.Int64
	// onPreload runs inside the preload handler before the report is written.
	onPreload func()
}

func (s *preloadTestSidecar) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch r.URL.Path {
	case "/v1/preload":
		s.preloads.Add(1)
		if s.onPreload != nil {
			s.onPreload()
		}
		if status := s.preloadStatus.Load(); status != 0 {
			w.WriteHeader(int(status))
			return
		}
		var request struct {
			PromptContractIDs []string `json:"prompt_contract_ids"`
		}
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		results := make([]sidecar.PreloadResult, len(request.PromptContractIDs))
		for index, contractID := range request.PromptContractIDs {
			results[index] = sidecar.PreloadResult{PromptContractID: contractID, Status: "cold"}
		}
		_ = json.NewEncoder(w).Encode(sidecar.PreloadReport{
			Status: "ready", Ready: true, Requested: len(results), Cold: len(results), Results: results,
		})
	case "/metrics":
		s.metrics.Add(1)
		if status := s.metricsStatus.Load(); status != 0 {
			w.WriteHeader(int(status))
			return
		}
		_, _ = w.Write([]byte(validSidecarMetricsBody))
	default:
		http.NotFound(w, r)
	}
}

// newTestPreloadController wires a controller to a real sidecar client served
// by fake, the given catalog and a running, ready child at generation 1.
func newTestPreloadController(
	t *testing.T,
	fake *preloadTestSidecar,
	provisioner preload.Catalog,
	config preload.PreloadControllerConfig,
) (*preload.PreloadController, *sidecar.Client, *preloadChildFixture) {
	t.Helper()
	server, socket := startUnixHTTPServer(t, fake)
	t.Cleanup(func() { _ = server.Close() })
	client := sidecar.NewClient(sidecar.ClientConfig{SocketPath: socket, MaxPreloadIDs: 8})
	t.Cleanup(client.Close)
	child := &preloadChildFixture{status: preload.ChildStatus{Running: true, Ready: true, ChildGeneration: 1}}
	controller, err := preload.New(provisioner, child, client, config)
	if err != nil {
		t.Fatal(err)
	}
	return controller, client, child
}

func readyCatalog(contractIDs ...string) *catalog.State {
	statuses := make([]catalog.Status, len(contractIDs))
	for index, contractID := range contractIDs {
		statuses[index] = catalog.Status{
			ModelID: fmt.Sprintf("model-%d", index), ArtifactReady: true, PromptContractID: contractID,
		}
	}
	provisioner := catalog.New()
	provisioner.Replace(statuses)
	return provisioner
}

func TestNewPreloadControllerRejectsBadInputs(t *testing.T) {
	client := sidecar.NewClient(sidecar.ClientConfig{})
	defer client.Close()
	provisioner := catalog.New()
	child := &preloadChildFixture{}
	if _, err := preload.New(nil, child, client, preload.PreloadControllerConfig{}); err != catalog.ErrInvalidConfig {
		t.Fatalf("nil catalog error = %v", err)
	}
	if _, err := preload.New(provisioner, nil, client, preload.PreloadControllerConfig{}); err != catalog.ErrInvalidConfig {
		t.Fatalf("nil child error = %v", err)
	}
	if _, err := preload.New(provisioner, child, nil, preload.PreloadControllerConfig{}); err != catalog.ErrInvalidConfig {
		t.Fatalf("nil client error = %v", err)
	}
	if _, err := preload.New(provisioner, child, client, preload.PreloadControllerConfig{
		FailureBackoffMin: time.Minute, FailureBackoffMax: time.Second,
	}); err != catalog.ErrInvalidConfig {
		t.Fatalf("inverted backoff error = %v", err)
	}
	if _, err := preload.New(provisioner, child, client, preload.PreloadControllerConfig{}); err != nil {
		t.Fatalf("zero config error = %v", err)
	}
}

func TestPreloadControllerNilReceiverIsSafe(t *testing.T) {
	var controller *preload.PreloadController
	controller.Start(context.Background())
	controller.Close()
	if controller.Status() != (preload.PreloadControllerStatus{}) || controller.ReadyFor(strings.Repeat("a", 64)) {
		t.Fatal("nil controller reported state")
	}
}

func TestPreloadControllerStartRunsUntilClose(t *testing.T) {
	contractID := strings.Repeat("c", 64)
	fake := &preloadTestSidecar{}
	controller, _, _ := newTestPreloadController(t, fake, readyCatalog(contractID),
		preload.PreloadControllerConfig{PollInterval: 5 * time.Millisecond, MetricsInterval: time.Hour})

	// Close before Start has nothing to stop and must not block.
	controller.Close()
	controller.Start(context.Background())
	// A second Start is ignored; only one run loop exists.
	controller.Start(context.Background())

	deadline := time.Now().Add(5 * time.Second)
	for !controller.ReadyFor(contractID) {
		if time.Now().After(deadline) {
			t.Fatalf("controller never became ready: %+v", controller.Status())
		}
		time.Sleep(5 * time.Millisecond)
	}
	status := controller.Status()
	if status.Runs != 1 || status.Cold != 1 || status.ContractCount != 1 || status.LastError != "" {
		t.Fatalf("ready status = %+v", status)
	}

	controller.Close()
	status = controller.Status()
	if status.Ready || status.LastError != "controller stopped" || controller.ReadyFor(contractID) {
		t.Fatalf("stopped status = %+v", status)
	}
	if calls := fake.preloads.Load(); calls != 1 {
		t.Fatalf("preload calls = %d, want 1 because later ticks matched", calls)
	}
}

func TestPreloadControllerStopsWhenParentContextEnds(t *testing.T) {
	controller, _, _ := newTestPreloadController(t, &preloadTestSidecar{}, readyCatalog(),
		preload.PreloadControllerConfig{PollInterval: time.Hour})
	parent, cancel := context.WithCancel(context.Background())
	controller.Start(parent)
	cancel()
	// Close waits for the run loop, which exits on the parent cancel.
	controller.Close()
	if status := controller.Status(); status.LastError != "controller stopped" || status.Ready {
		t.Fatalf("status = %+v", status)
	}
}

func TestPreloadControllerReconcileUnavailableReasons(t *testing.T) {
	contractID := strings.Repeat("d", 64)
	failedArtifact := catalog.New()
	failedArtifact.Replace([]catalog.Status{{ModelID: "m", LastError: "boom"}})
	rejectedCatalog := catalog.New()
	if _, err := rejectedCatalog.Reconcile([]identity.Manifest{{}}, 0); !errors.Is(err, catalog.ErrInvalidConfig) {
		t.Fatalf("catalog reject error = %v", err)
	}
	tests := []struct {
		name        string
		provisioner *catalog.State
		child       preload.ChildStatus
		want        string
	}{
		{
			name:        "no catalog yet",
			provisioner: catalog.New(),
			child:       preload.ChildStatus{Running: true, ChildGeneration: 1},
			want:        "awaiting model catalog",
		},
		{
			name:        "artifact failed",
			provisioner: failedArtifact,
			child:       preload.ChildStatus{Running: true, ChildGeneration: 1},
			want:        "prompt artifact provisioning failed",
		},
		{
			name:        "catalog error",
			provisioner: rejectedCatalog,
			child:       preload.ChildStatus{Running: true, ChildGeneration: 1},
			want:        "prompt artifact provisioning failed",
		},
		{
			name:        "child not running",
			provisioner: readyCatalog(contractID),
			child:       preload.ChildStatus{Running: false, ChildGeneration: 1},
			want:        "awaiting prompt sidecar",
		},
		{
			name:        "child generation zero",
			provisioner: readyCatalog(contractID),
			child:       preload.ChildStatus{Running: true},
			want:        "awaiting prompt sidecar",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fake := &preloadTestSidecar{}
			controller, _, child := newTestPreloadController(t, fake, test.provisioner, preload.PreloadControllerConfig{})
			child.replace(test.child)
			controller.Reconcile(context.Background())
			status := controller.Status()
			if status.Ready || status.LastError != test.want || status.Failures != 0 {
				t.Fatalf("status = %+v, want unavailable %q", status, test.want)
			}
			if fake.preloads.Load() != 0 {
				t.Fatal("preload called while not eligible")
			}
		})
	}
}

func TestPreloadControllerEmptyCatalogIsReadyWithoutPreload(t *testing.T) {
	fake := &preloadTestSidecar{}
	controller, _, _ := newTestPreloadController(t, fake, readyCatalog(),
		preload.PreloadControllerConfig{MetricsInterval: time.Hour})

	controller.Reconcile(context.Background())
	status := controller.Status()
	if !status.Ready || status.ContractCount != 0 || status.Runs != 0 || status.CatalogGeneration != 1 {
		t.Fatalf("empty catalog status = %+v", status)
	}
	controller.Reconcile(context.Background())
	if fake.preloads.Load() != 0 {
		t.Fatal("empty catalog sent a preload")
	}
	// Becoming ready counts as a fresh refresh, so a long interval is not due.
	if fake.metrics.Load() != 0 {
		t.Fatalf("metrics calls = %d before the interval", fake.metrics.Load())
	}
}

func TestPreloadControllerRefreshMetricsRespectsInterval(t *testing.T) {
	const interval = 250 * time.Millisecond
	fake := &preloadTestSidecar{}
	fake.metricsStatus.Store(http.StatusInternalServerError)
	controller, client, _ := newTestPreloadController(t, fake, readyCatalog(),
		preload.PreloadControllerConfig{MetricsInterval: interval})

	// Becoming ready records the refresh time no later than readyAt.
	controller.Reconcile(context.Background())
	readyAt := time.Now()
	baseline := fake.metrics.Load()
	// time.Sleep waits at least interval, so every pass below is due.
	time.Sleep(interval)

	// A failed refresh keeps the old time, so each later pass tries again.
	controller.Reconcile(context.Background())
	controller.Reconcile(context.Background())
	if calls := fake.metrics.Load() - baseline; calls != 2 {
		t.Fatalf("failed refreshes = %d, want 2 (ready at %v)", calls, readyAt)
	}

	// A successful refresh updates the client cache and the refresh time.
	fake.metricsStatus.Store(0)
	succeededFrom := time.Now()
	controller.Reconcile(context.Background())
	if calls := fake.metrics.Load() - baseline; calls != 3 {
		t.Fatalf("refresh calls = %d, want 3", calls)
	}
	if client.SidecarMetrics().Preloads.Runs != 3 {
		t.Fatal("metrics refresh did not update the client cache")
	}
	controller.Reconcile(context.Background())
	// The pass after a success is due only if a full interval has passed.
	if time.Since(succeededFrom) < interval {
		if calls := fake.metrics.Load() - baseline; calls != 3 {
			t.Fatalf("refresh calls = %d after a fresh success, want 3", calls)
		}
	}
}

func TestPreloadControllerConflictIsNotAFailure(t *testing.T) {
	fake := &preloadTestSidecar{}
	fake.preloadStatus.Store(http.StatusConflict)
	controller, _, _ := newTestPreloadController(t, fake, readyCatalog(strings.Repeat("e", 64)),
		preload.PreloadControllerConfig{})

	controller.Reconcile(context.Background())
	status := controller.Status()
	if status.Ready || status.Failures != 0 || status.LastError != "sidecar preload already in progress" {
		t.Fatalf("conflict status = %+v", status)
	}
	// No backoff is armed, so the next pass asks again.
	controller.Reconcile(context.Background())
	if fake.preloads.Load() != 2 {
		t.Fatalf("preload calls = %d, want 2", fake.preloads.Load())
	}
}

func TestPreloadControllerHTTPErrorIsAFailure(t *testing.T) {
	fake := &preloadTestSidecar{}
	fake.preloadStatus.Store(http.StatusInternalServerError)
	controller, _, _ := newTestPreloadController(t, fake, readyCatalog(strings.Repeat("f", 64)),
		preload.PreloadControllerConfig{FailureBackoffMin: time.Hour, FailureBackoffMax: time.Hour})

	controller.Reconcile(context.Background())
	status := controller.Status()
	if status.Ready || status.Failures != 1 || !strings.Contains(status.LastError, "HTTP 500") {
		t.Fatalf("failure status = %+v", status)
	}
	controller.Reconcile(context.Background())
	if fake.preloads.Load() != 1 {
		t.Fatal("failure retried inside the backoff window")
	}
}

func TestPreloadControllerUnavailable409IsAFailure(t *testing.T) {
	// Only a preload rejection with HTTP 409 is a conflict. Other errors that
	// carry the same text still arm the failure backoff.
	client := &preloadClientFixture{err: fmt.Errorf("%w: HTTP 409", sidecar.ErrSidecarUnavailable)}
	child := &preloadChildFixture{status: preload.ChildStatus{Running: true, Ready: true, ChildGeneration: 1}}
	controller, err := preload.New(readyCatalog(strings.Repeat("9", 64)), child, client,
		preload.PreloadControllerConfig{FailureBackoffMin: time.Hour, FailureBackoffMax: time.Hour})
	if err != nil {
		t.Fatal(err)
	}
	controller.Reconcile(context.Background())
	controller.Reconcile(context.Background())
	status := controller.Status()
	if status.Ready || status.Failures != 1 || status.LastError == "sidecar preload already in progress" {
		t.Fatalf("status = %+v, want one failure", status)
	}
	if calls := client.preloads.Load(); calls != 1 {
		t.Fatalf("preload calls = %d, want 1 inside the backoff window", calls)
	}
}

func TestPreloadControllerDiscardsPreloadFromChangedGeneration(t *testing.T) {
	contractID := strings.Repeat("0", 64)
	fake := &preloadTestSidecar{}
	controller, _, child := newTestPreloadController(t, fake, readyCatalog(contractID), preload.PreloadControllerConfig{})
	// The child restarts while the preload request is in flight.
	fake.onPreload = func() {
		child.replace(preload.ChildStatus{Running: true, Ready: true, ChildGeneration: 2})
	}

	controller.Reconcile(context.Background())
	status := controller.Status()
	if status.Ready || status.LastError != "preload generation changed" || status.Runs != 0 || status.Failures != 0 {
		t.Fatalf("status = %+v", status)
	}
	if controller.ReadyFor(contractID) {
		t.Fatal("stale preload opened routing")
	}
}

func TestPreloadControllerMatchesRequiresSameContractSet(t *testing.T) {
	contractA := strings.Repeat("a", 64)
	contractB := strings.Repeat("b", 64)
	fake := &preloadTestSidecar{}
	// The catalog keeps one generation while its contract set changes, so only
	// the set comparison can tell the passes apart.
	provisioner := &preloadCatalogFixture{snapshot: catalog.Snapshot{Generation: 3, ContractIDs: []string{contractA}}}
	controller, _, _ := newTestPreloadController(t, fake, provisioner,
		preload.PreloadControllerConfig{MetricsInterval: time.Hour})

	controller.Reconcile(context.Background())
	controller.Reconcile(context.Background())
	if calls := fake.preloads.Load(); calls != 1 {
		t.Fatalf("same set preload calls = %d, want 1", calls)
	}
	provisioner.replace(catalog.Snapshot{Generation: 3, ContractIDs: []string{contractB}})
	controller.Reconcile(context.Background())
	if calls := fake.preloads.Load(); calls != 2 || !controller.ReadyFor(contractB) || controller.ReadyFor(contractA) {
		t.Fatalf("different contract of the same size: calls=%d status=%+v", calls, controller.Status())
	}
	provisioner.replace(catalog.Snapshot{Generation: 3, ContractIDs: []string{contractA, contractB}})
	controller.Reconcile(context.Background())
	if calls := fake.preloads.Load(); calls != 3 || controller.Status().ContractCount != 2 {
		t.Fatalf("larger set: calls=%d status=%+v", calls, controller.Status())
	}
}

type preloadCatalogFixture struct {
	mu       sync.RWMutex
	snapshot catalog.Snapshot
}

func (f *preloadCatalogFixture) Snapshot() catalog.Snapshot {
	f.mu.RLock()
	defer f.mu.RUnlock()
	snapshot := f.snapshot
	snapshot.ContractIDs = append([]string(nil), f.snapshot.ContractIDs...)
	return snapshot
}

func (f *preloadCatalogFixture) replace(snapshot catalog.Snapshot) {
	f.mu.Lock()
	f.snapshot = snapshot
	f.mu.Unlock()
}

type preloadClientFixture struct {
	preloads atomic.Int64
	err      error
}

func (f *preloadClientFixture) Preload(context.Context, []string) (sidecar.PreloadReport, error) {
	f.preloads.Add(1)
	return sidecar.PreloadReport{}, f.err
}

func (f *preloadClientFixture) Metrics(context.Context) (sidecar.SidecarStatus, error) {
	return sidecar.SidecarStatus{}, f.err
}
