package promptcontract_test

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/catalog"
	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/preload"
	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/sidecar"
)

type readinessControllerFixture struct {
	t           *testing.T
	controller  *preload.PreloadController
	client      preload.Client
	provisioner *catalog.State
	supervisor  *preloadChildFixture
	// activeSet is the controller's actual selection policy. The controller
	// serializes it; read it only between controller calls.
	activeSet *preload.PreloadActiveSet
	// policyClock, once set, replaces the injected policy clock's default of
	// time since construction.
	policyClock  atomic.Pointer[func() time.Duration]
	generation   uint64
	preloads     atomic.Int64
	readyCalls   atomic.Int64
	metricsCalls atomic.Int64
	ready        atomic.Bool
	readyStatus  atomic.Int64
}

// wrap optionally interposes on the controller's actual client, the same
// injected preload.Client production passes; it never fabricates a response.
func newReadinessControllerFixture(t *testing.T, respond func(context.Context, int64, []string) sidecar.PreloadReport, wrap ...func(preload.Client) preload.Client) *readinessControllerFixture {
	t.Helper()
	f := &readinessControllerFixture{t: t}
	f.ready.Store(true)
	f.readyStatus.Store(http.StatusOK)
	server, socket := startUnixHTTPServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/ready":
			f.readyCalls.Add(1)
			w.WriteHeader(int(f.readyStatus.Load()))
			_ = json.NewEncoder(w).Encode(sidecar.ReadinessStatus{Status: "ok", Ready: f.ready.Load()})
		case "/metrics":
			f.metricsCalls.Add(1)
			http.NotFound(w, r)
		case "/v1/preload":
			var request struct {
				IDs []string `json:"prompt_contract_ids"`
			}
			if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
				t.Error(err)
				return
			}
			_ = json.NewEncoder(w).Encode(respond(r.Context(), f.preloads.Add(1), request.IDs))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(func() { _ = server.Close() })
	client := sidecar.NewClient(sidecar.ClientConfig{SocketPath: socket, MaxPreloadIDs: 8})
	t.Cleanup(client.Close)
	var controlled preload.Client = client
	for _, interpose := range wrap {
		controlled = interpose(controlled)
	}
	f.provisioner = catalog.New()
	f.supervisor = &preloadChildFixture{status: preload.ChildStatus{Running: true, Ready: true, ChildGeneration: 1}}
	var err error
	f.client = controlled
	origin := time.Now()
	f.controller, err = preload.New(f.provisioner, f.supervisor, controlled, preload.PreloadControllerConfig{
		FailureBackoffMin: time.Hour, FailureBackoffMax: 2 * time.Hour,
		PolicyNow: func() time.Duration {
			if clock := f.policyClock.Load(); clock != nil {
				return (*clock)()
			}
			return time.Since(origin)
		},
		ActiveSets: func() *preload.PreloadActiveSet {
			f.activeSet = preload.NewPreloadActiveSet()
			return f.activeSet
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(f.controller.Close)
	return f
}

func readinessReport(ids []string, failedID string) sidecar.PreloadReport {
	r := sidecar.PreloadReport{Status: "ready", Ready: true, Requested: len(ids)}
	for _, id := range ids {
		status := "warm"
		if id == failedID {
			status = "failed"
			r.Failed++
			r.Ready = false
			r.Status = "degraded"
		} else {
			r.Warm++
		}
		r.Results = append(r.Results, sidecar.PreloadResult{PromptContractID: id, Status: status})
	}
	return r
}

var errReadinessArtifactWithdrawn = errors.New("synthetic artifact withdrawn")

func readinessModel(id string) string { return "model-" + id }

// provision starts one catalog generation whose members are all still
// provisioning, as Provisioner.Reconcile publishes a new catalog.
func (f *readinessControllerFixture) provision(ids ...string) {
	statuses := make([]catalog.Status, len(ids))
	for i, id := range ids {
		// Exact tuple snapshots require a verified aggregate too. This is only
		// synthetic setup; no readiness, generation or transport assertion changes.
		statuses[i] = catalog.Status{ModelID: readinessModel(id), PromptContractID: id,
			ModelAggregateSHA256: strings.Repeat("e", 64)}
	}
	f.generation = f.provisioner.Replace(statuses)
}

// verified makes exactly ids the verified set of the current catalog
// generation through per-model provisioning results; the generation does not
// change. Without a provisioned catalog it starts one whose members are ids.
func (f *readinessControllerFixture) verified(ids ...string) {
	f.t.Helper()
	if f.generation == 0 {
		f.provision(ids...)
	}
	want := make(map[string]bool, len(ids))
	for _, id := range ids {
		if _, exists := f.provisioner.Status(readinessModel(id)); !exists {
			f.t.Fatalf("contract %s is not a member of catalog generation %d", id, f.generation)
		}
		want[id] = true
	}
	for _, status := range f.provisioner.Statuses() {
		if want[status.PromptContractID] {
			f.provisioner.Record(f.generation, status.ModelID, "", nil, nil)
		} else if status.ArtifactReady {
			f.provisioner.Record(f.generation, status.ModelID, "", nil, errReadinessArtifactWithdrawn)
		}
	}
}

func TestPreloadPartialPublicationRequiresFreshReady(t *testing.T) {
	a, b := strings.Repeat("a", 64), strings.Repeat("b", 64)
	for _, status := range []int{http.StatusOK, http.StatusServiceUnavailable, http.StatusInternalServerError} {
		t.Run(fmt.Sprint(status), func(t *testing.T) {
			f := newReadinessControllerFixture(t, func(_ context.Context, _ int64, ids []string) sidecar.PreloadReport { return readinessReport(ids, b) })
			f.verified(a, b)
			f.readyStatus.Store(int64(status))
			f.ready.Store(status == http.StatusOK)
			f.controller.Reconcile(context.Background())
			if f.readyCalls.Load() != 1 || f.controller.ReadyFor(a) != (status == http.StatusOK) || f.controller.ReadyFor(b) {
				t.Fatalf("cached supervisor readiness substituted for fresh child confirmation: %+v", f.controller.Status())
			}
			got := f.controller.Status()
			if got.Failures != 1 || got.Runs != 0 || (got.Warm == 1) != (status == http.StatusOK) || got.LastError == "" {
				t.Fatalf("partial/error accounting changed population: %+v", got)
			}
			f.controller.Reconcile(context.Background())
			if f.preloads.Load() != 1 || f.readyCalls.Load() != 1 {
				t.Fatal("unchanged failed set did not back off")
			}
		})
	}
}

func TestPreloadFailedMemberBackoffDoesNotIssueExtraControlIO(t *testing.T) {
	a := strings.Repeat("a", 64)
	f := newReadinessControllerFixture(t, func(_ context.Context, _ int64, ids []string) sidecar.PreloadReport {
		return readinessReport(ids, a)
	})
	f.verified(a)
	f.controller.Reconcile(context.Background())
	f.controller.Reconcile(context.Background())
	if f.preloads.Load() != 1 || f.readyCalls.Load() != 0 || f.metricsCalls.Load() != 0 {
		t.Fatal("backoff issued extra preload/readiness/metrics IO")
	}
	if got := f.controller.Status(); got.Ready || got.Failures != 1 || got.Runs != 0 {
		t.Fatalf("backoff changed failure/readiness accounting: %+v", got)
	}
}

func TestPreloadVerifiedSetGrowthBypassesOldBackoff(t *testing.T) {
	a, b, c := strings.Repeat("a", 64), strings.Repeat("b", 64), strings.Repeat("c", 64)
	f := newReadinessControllerFixture(t, func(_ context.Context, _ int64, ids []string) sidecar.PreloadReport { return readinessReport(ids, b) })
	f.provision(a, b, c)
	f.verified(a, b)
	f.controller.Reconcile(context.Background())
	if !f.controller.ReadyFor(a) {
		t.Fatal("initial partial set unavailable")
	}
	f.verified(a, b, c) // Same catalog generation, new verified membership.
	if f.controller.ReadyFor(a) || f.controller.ReadyFor(c) {
		t.Fatal("changed verified set reused old acknowledgement before polling")
	}
	f.controller.Reconcile(context.Background())
	if f.preloads.Load() != 2 || !f.controller.ReadyFor(a) || !f.controller.ReadyFor(c) || f.controller.ReadyFor(b) {
		t.Fatal("old-set retry delay suppressed current verified members")
	}
	got := f.controller.Status()
	if got.Failures != 2 || got.Warm != 3 || got.Runs != 0 || got.ContractCount != 2 {
		t.Fatalf("applied partial accounting: %+v", got)
	}
}

// The original b8eba688 controller-capacity oracle remains the old-source
// control. Overflow selection intentionally no longer submits all nine IDs;
// Client's direct pre-HTTP nine-ID rejection below remains unchanged.
func TestPreloadOverflowSelectionAndEmptySetsCloseBeforePolling(t *testing.T) {
	a := strings.Repeat("a", 64)
	f := newReadinessControllerFixture(t, func(_ context.Context, _ int64, ids []string) sidecar.PreloadReport { return readinessReport(ids, "") })
	ids := []string{a}
	for i := 0; i < 8; i++ {
		ids = append(ids, fmt.Sprintf("%064x", i+1))
	}
	f.provision(ids...)
	f.verified(a)
	f.controller.Reconcile(context.Background())
	f.verified(ids...)
	if f.controller.ReadyFor(a) {
		t.Fatal("oversized same-generation catalog remained usable")
	}
	f.controller.Reconcile(context.Background())
	if f.preloads.Load() != 1 || f.controller.Status().Failures != 0 || f.controller.Status().LastError != "capacity_deferred" {
		t.Fatal("no eligible overflow demand must stay closed without a fake failed runtime load")
	}
	if _, err := f.client.Preload(context.Background(), ids); err == nil || f.preloads.Load() != 1 {
		t.Fatal("direct over-capacity request bypassed the unchanged Client/pre-HTTP guard")
	}
	f.verified()
	f.controller.Reconcile(context.Background())
	if f.controller.ReadyFor(a) || f.controller.Status().Ready || f.preloads.Load() != 1 {
		t.Fatal("empty Go set opened routing or sent empty Rust preload")
	}
}

func TestPreloadInFlightIdentityAndCloseFencePublication(t *testing.T) {
	a, b := strings.Repeat("a", 64), strings.Repeat("b", 64)
	for _, kind := range []string{"verified_growth", "child_restart", "close", "cancel"} {
		t.Run(kind, func(t *testing.T) {
			entered, release := make(chan struct{}, 1), make(chan struct{})
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			f := newReadinessControllerFixture(t, func(ctx context.Context, _ int64, ids []string) sidecar.PreloadReport {
				entered <- struct{}{}
				select {
				case <-release:
				case <-ctx.Done():
				}
				return readinessReport(ids, "")
			})
			f.provision(a, b)
			f.verified(a)
			done := make(chan struct{})
			go func() { defer close(done); f.controller.Reconcile(ctx) }()
			select {
			case <-entered:
			case <-time.After(time.Second):
				t.Fatal("preload never entered real transport")
			}
			switch kind {
			case "verified_growth":
				f.verified(a, b)
			case "child_restart":
				f.supervisor.replace(preload.ChildStatus{Running: true, Ready: true, ChildGeneration: 2})
			case "close":
				f.controller.Close()
			case "cancel":
				cancel()
			}
			close(release)
			select {
			case <-done:
			case <-time.After(time.Second):
				t.Fatal("owned preload did not drain")
			}
			if f.controller.ReadyFor(a) || f.controller.Status().Ready || f.controller.Status().Warm != 0 || f.controller.Status().Runs != 0 {
				t.Fatalf("stale completion was published: %+v", f.controller.Status())
			}
		})
	}
}
