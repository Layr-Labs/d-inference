package promptcontract

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// preloadTestSidecar serves /v1/preload with an all-warm report and /metrics
// with a valid status, and counts calls to each path.
type preloadTestSidecar struct {
	preloads atomic.Int64
	metrics  atomic.Int64
	// preloadStatus, when not zero, is returned instead of a report.
	preloadStatus int
	// metricsStatus, when not zero, is returned instead of a metrics body.
	metricsStatus int
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
		if s.preloadStatus != 0 {
			w.WriteHeader(s.preloadStatus)
			return
		}
		var request struct {
			PromptContractIDs []string `json:"prompt_contract_ids"`
		}
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		results := make([]PreloadResult, len(request.PromptContractIDs))
		for index, contractID := range request.PromptContractIDs {
			results[index] = PreloadResult{PromptContractID: contractID, Status: "cold"}
		}
		_ = json.NewEncoder(w).Encode(PreloadReport{
			Status: "ready", Ready: true, Requested: len(results), Cold: len(results), Results: results,
		})
	case "/metrics":
		s.metrics.Add(1)
		if s.metricsStatus != 0 {
			w.WriteHeader(s.metricsStatus)
			return
		}
		_, _ = w.Write([]byte(validSidecarMetricsBody))
	default:
		http.NotFound(w, r)
	}
}

func newTestPreloadController(
	t *testing.T,
	sidecar *preloadTestSidecar,
	statuses map[string]ProvisionStatus,
	config PreloadControllerConfig,
) (*PreloadController, *Provisioner, *Supervisor) {
	t.Helper()
	server, socket := startUnixHTTPServer(t, sidecar)
	t.Cleanup(func() { _ = server.Close() })
	client := NewClient(ClientConfig{SocketPath: socket, MaxPreloadIDs: 8})
	t.Cleanup(client.Close)
	provisioner := &Provisioner{generation: 1, statuses: statuses}
	supervisor := &Supervisor{client: client, status: SupervisorStatus{
		Enabled: true, Running: true, Ready: true, ChildGeneration: 1,
	}}
	controller, err := NewPreloadController(provisioner, supervisor, config)
	if err != nil {
		t.Fatal(err)
	}
	return controller, provisioner, supervisor
}

func TestNewPreloadControllerRejectsBadInputs(t *testing.T) {
	client := NewClient(ClientConfig{})
	defer client.Close()
	provisioner := &Provisioner{}
	supervisor := &Supervisor{client: client}
	if _, err := NewPreloadController(nil, supervisor, PreloadControllerConfig{}); err != ErrInvalidConfig {
		t.Fatalf("nil provisioner error = %v", err)
	}
	if _, err := NewPreloadController(provisioner, &Supervisor{}, PreloadControllerConfig{}); err != ErrInvalidConfig {
		t.Fatalf("supervisor without client error = %v", err)
	}
	if _, err := NewPreloadController(provisioner, supervisor, PreloadControllerConfig{
		FailureBackoffMin: time.Minute, FailureBackoffMax: time.Second,
	}); err != ErrInvalidConfig {
		t.Fatalf("inverted backoff error = %v", err)
	}
	controller, err := NewPreloadController(provisioner, supervisor, PreloadControllerConfig{})
	if err != nil {
		t.Fatal(err)
	}
	want := PreloadControllerConfig{
		PollInterval:      defaultPreloadPollInterval,
		MetricsInterval:   defaultMetricsPollInterval,
		FailureBackoffMin: defaultFailureBackoffMin,
		FailureBackoffMax: defaultFailureBackoffMax,
	}
	if controller.config != want {
		t.Fatalf("defaults = %+v, want %+v", controller.config, want)
	}
}

func TestPreloadControllerNilReceiverIsSafe(t *testing.T) {
	var controller *PreloadController
	controller.Start(context.Background())
	controller.Close()
	if controller.Status() != (PreloadControllerStatus{}) || controller.ReadyFor(strings.Repeat("a", 64)) {
		t.Fatal("nil controller reported state")
	}
}

func TestPreloadControllerStartRunsUntilClose(t *testing.T) {
	contractID := strings.Repeat("c", 64)
	sidecar := &preloadTestSidecar{}
	controller, _, _ := newTestPreloadController(t, sidecar, map[string]ProvisionStatus{
		"model": {ArtifactReady: true, PromptContractID: contractID},
	}, PreloadControllerConfig{PollInterval: 5 * time.Millisecond, MetricsInterval: time.Hour})

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
	if calls := sidecar.preloads.Load(); calls != 1 {
		t.Fatalf("preload calls = %d, want 1 because later ticks matched", calls)
	}
}

func TestPreloadControllerStopsWhenParentContextEnds(t *testing.T) {
	sidecar := &preloadTestSidecar{}
	controller, _, _ := newTestPreloadController(t, sidecar, map[string]ProvisionStatus{},
		PreloadControllerConfig{PollInterval: time.Hour})
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
	tests := []struct {
		name       string
		generation uint64
		statuses   map[string]ProvisionStatus
		catalogErr string
		child      SupervisorStatus
		want       string
	}{
		{
			name:       "no catalog yet",
			generation: 0,
			child:      SupervisorStatus{Running: true, ChildGeneration: 1},
			want:       "awaiting model catalog",
		},
		{
			name:       "artifact failed",
			generation: 1,
			statuses:   map[string]ProvisionStatus{"m": {LastError: "boom"}},
			child:      SupervisorStatus{Running: true, ChildGeneration: 1},
			want:       "prompt artifact provisioning failed",
		},
		{
			name:       "catalog error",
			generation: 1,
			catalogErr: "bad catalog",
			child:      SupervisorStatus{Running: true, ChildGeneration: 1},
			want:       "prompt artifact provisioning failed",
		},
		{
			name:       "child not running",
			generation: 1,
			statuses:   map[string]ProvisionStatus{"m": {ArtifactReady: true, PromptContractID: contractID}},
			child:      SupervisorStatus{Running: false, ChildGeneration: 1},
			want:       "awaiting prompt sidecar",
		},
		{
			name:       "child generation zero",
			generation: 1,
			statuses:   map[string]ProvisionStatus{"m": {ArtifactReady: true, PromptContractID: contractID}},
			child:      SupervisorStatus{Running: true},
			want:       "awaiting prompt sidecar",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			sidecar := &preloadTestSidecar{}
			controller, provisioner, supervisor := newTestPreloadController(t, sidecar, test.statuses, PreloadControllerConfig{})
			provisioner.generation = test.generation
			provisioner.catalogError = test.catalogErr
			supervisor.status = test.child
			controller.reconcile(context.Background())
			status := controller.Status()
			if status.Ready || status.LastError != test.want || status.Failures != 0 {
				t.Fatalf("status = %+v, want unavailable %q", status, test.want)
			}
			if sidecar.preloads.Load() != 0 {
				t.Fatal("preload called while not eligible")
			}
		})
	}
}

func TestPreloadControllerEmptyCatalogIsReadyAndRefreshesMetrics(t *testing.T) {
	sidecar := &preloadTestSidecar{}
	controller, _, _ := newTestPreloadController(t, sidecar, map[string]ProvisionStatus{},
		PreloadControllerConfig{MetricsInterval: time.Nanosecond})

	controller.reconcile(context.Background())
	status := controller.Status()
	if !status.Ready || status.ContractCount != 0 || status.Runs != 0 || status.CatalogGeneration != 1 {
		t.Fatalf("empty catalog status = %+v", status)
	}
	if sidecar.preloads.Load() != 0 {
		t.Fatal("empty catalog sent a preload")
	}
	if sidecar.metrics.Load() != 1 {
		t.Fatalf("metrics calls = %d, want 1", sidecar.metrics.Load())
	}
	// A later matching pass refreshes metrics again because the interval is due.
	controller.reconcile(context.Background())
	if sidecar.metrics.Load() != 2 {
		t.Fatalf("metrics calls = %d, want 2", sidecar.metrics.Load())
	}
	if controller.client.SidecarMetrics().Preloads.Runs != 3 {
		t.Fatal("metrics refresh did not update the client cache")
	}
}

func TestPreloadControllerRefreshMetricsRespectsInterval(t *testing.T) {
	sidecar := &preloadTestSidecar{metricsStatus: http.StatusInternalServerError}
	controller, _, _ := newTestPreloadController(t, sidecar, map[string]ProvisionStatus{},
		PreloadControllerConfig{MetricsInterval: time.Hour})

	// Not due: the last refresh time is now.
	controller.metricsAt = time.Now()
	controller.refreshMetrics(context.Background())
	if sidecar.metrics.Load() != 0 {
		t.Fatal("refresh ran before the interval")
	}

	// Due, but the sidecar fails: the refresh time must stay old so the next
	// pass tries again.
	old := time.Now().Add(-2 * time.Hour)
	controller.metricsAt = old
	controller.refreshMetrics(context.Background())
	if sidecar.metrics.Load() != 1 || !controller.metricsAt.Equal(old) {
		t.Fatalf("failed refresh: calls=%d metricsAt changed=%v", sidecar.metrics.Load(), !controller.metricsAt.Equal(old))
	}

	sidecar.metricsStatus = 0
	controller.refreshMetrics(context.Background())
	if sidecar.metrics.Load() != 2 || !controller.metricsAt.After(old) {
		t.Fatal("successful refresh did not move the refresh time")
	}
}

func TestPreloadControllerConflictIsNotAFailure(t *testing.T) {
	contractID := strings.Repeat("e", 64)
	sidecar := &preloadTestSidecar{preloadStatus: http.StatusConflict}
	controller, _, _ := newTestPreloadController(t, sidecar, map[string]ProvisionStatus{
		"model": {ArtifactReady: true, PromptContractID: contractID},
	}, PreloadControllerConfig{})

	controller.reconcile(context.Background())
	status := controller.Status()
	if status.Ready || status.Failures != 0 || status.LastError != "sidecar preload already in progress" {
		t.Fatalf("conflict status = %+v", status)
	}
	// No backoff is armed, so the next pass asks again.
	controller.reconcile(context.Background())
	if sidecar.preloads.Load() != 2 {
		t.Fatalf("preload calls = %d, want 2", sidecar.preloads.Load())
	}
}

func TestPreloadControllerHTTPErrorIsAFailure(t *testing.T) {
	contractID := strings.Repeat("f", 64)
	sidecar := &preloadTestSidecar{preloadStatus: http.StatusInternalServerError}
	controller, _, _ := newTestPreloadController(t, sidecar, map[string]ProvisionStatus{
		"model": {ArtifactReady: true, PromptContractID: contractID},
	}, PreloadControllerConfig{FailureBackoffMin: time.Hour, FailureBackoffMax: time.Hour})

	controller.reconcile(context.Background())
	status := controller.Status()
	if status.Ready || status.Failures != 1 || !strings.Contains(status.LastError, "HTTP 500") {
		t.Fatalf("failure status = %+v", status)
	}
	controller.reconcile(context.Background())
	if sidecar.preloads.Load() != 1 {
		t.Fatal("failure retried inside the backoff window")
	}
}

func TestPreloadControllerDiscardsPreloadFromChangedGeneration(t *testing.T) {
	contractID := strings.Repeat("0", 64)
	sidecar := &preloadTestSidecar{}
	controller, _, supervisor := newTestPreloadController(t, sidecar, map[string]ProvisionStatus{
		"model": {ArtifactReady: true, PromptContractID: contractID},
	}, PreloadControllerConfig{})
	// The child restarts while the preload request is in flight.
	sidecar.onPreload = func() {
		supervisor.mu.Lock()
		supervisor.status.ChildGeneration = 2
		supervisor.mu.Unlock()
	}

	controller.reconcile(context.Background())
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
	controller := &PreloadController{contracts: map[string]struct{}{contractA: {}}}
	controller.status = PreloadControllerStatus{Ready: true, CatalogGeneration: 3, ChildGeneration: 4}
	child := SupervisorStatus{ChildGeneration: 4}

	if !controller.matches(ProvisionSnapshot{Generation: 3, ContractIDs: []string{contractA}}, child) {
		t.Fatal("same set did not match")
	}
	if controller.matches(ProvisionSnapshot{Generation: 3, ContractIDs: []string{contractB}}, child) {
		t.Fatal("different contract with same size matched")
	}
	if controller.matches(ProvisionSnapshot{Generation: 3, ContractIDs: []string{contractA, contractB}}, child) {
		t.Fatal("larger set matched")
	}
	if controller.matches(ProvisionSnapshot{Generation: 2, ContractIDs: []string{contractA}}, child) {
		t.Fatal("old catalog generation matched")
	}
	if controller.matches(ProvisionSnapshot{Generation: 3, ContractIDs: []string{contractA}}, SupervisorStatus{ChildGeneration: 5}) {
		t.Fatal("new child generation matched")
	}
}

func TestBoundedStatusErrorAndConflictDetection(t *testing.T) {
	if got := boundedStatusError("  spaced  "); got != "spaced" {
		t.Fatalf("trimmed = %q", got)
	}
	long := strings.Repeat("x", maxPreloadStatusErrorBytes+10)
	if got := boundedStatusError(long); len(got) != maxPreloadStatusErrorBytes {
		t.Fatalf("bounded length = %d", len(got))
	}
	if !isPreloadConflict(fmt.Errorf("%w: HTTP 409", ErrPreloadRejected)) {
		t.Fatal("409 preload rejection not a conflict")
	}
	if isPreloadConflict(fmt.Errorf("%w: HTTP 500", ErrPreloadRejected)) {
		t.Fatal("500 preload rejection treated as conflict")
	}
	if isPreloadConflict(fmt.Errorf("%w: HTTP 409", ErrSidecarUnavailable)) {
		t.Fatal("non preload error treated as conflict")
	}
}
