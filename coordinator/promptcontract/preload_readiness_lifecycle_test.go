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

type readinessControllerFixture struct {
	controller   *PreloadController
	provisioner  *Provisioner
	supervisor   *Supervisor
	preloads     atomic.Int64
	readyCalls   atomic.Int64
	metricsCalls atomic.Int64
	ready        atomic.Bool
	readyStatus  atomic.Int64
}

func newReadinessControllerFixture(t *testing.T, respond func(context.Context, int64, []string) PreloadReport) *readinessControllerFixture {
	t.Helper()
	f := &readinessControllerFixture{}
	f.ready.Store(true)
	f.readyStatus.Store(http.StatusOK)
	server, socket := startUnixHTTPServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/ready":
			f.readyCalls.Add(1)
			w.WriteHeader(int(f.readyStatus.Load()))
			_ = json.NewEncoder(w).Encode(ReadinessStatus{Status: "ok", Ready: f.ready.Load()})
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
	client := NewClient(ClientConfig{SocketPath: socket, MaxPreloadIDs: 8})
	t.Cleanup(client.Close)
	f.provisioner = &Provisioner{generation: 1, statuses: map[string]ProvisionStatus{}}
	f.supervisor = &Supervisor{client: client, status: SupervisorStatus{Enabled: true, Running: true, Ready: true, ChildGeneration: 1}}
	var err error
	f.controller, err = NewPreloadController(f.provisioner, f.supervisor, PreloadControllerConfig{
		FailureBackoffMin: time.Hour, FailureBackoffMax: 2 * time.Hour,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(f.controller.Close)
	return f
}

func readinessReport(ids []string, failedID string) PreloadReport {
	r := PreloadReport{Status: "ready", Ready: true, Requested: len(ids)}
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
		r.Results = append(r.Results, PreloadResult{PromptContractID: id, Status: status})
	}
	return r
}

func (f *readinessControllerFixture) verified(ids ...string) {
	f.provisioner.mu.Lock()
	f.provisioner.statuses = make(map[string]ProvisionStatus, len(ids))
	for i, id := range ids {
		f.provisioner.statuses[fmt.Sprint(i)] = ProvisionStatus{PromptContractID: id, ArtifactReady: true}
	}
	f.provisioner.mu.Unlock()
}

func TestPreloadPartialPublicationRequiresFreshReady(t *testing.T) {
	a, b := strings.Repeat("a", 64), strings.Repeat("b", 64)
	for _, status := range []int{http.StatusOK, http.StatusServiceUnavailable, http.StatusInternalServerError} {
		t.Run(fmt.Sprint(status), func(t *testing.T) {
			f := newReadinessControllerFixture(t, func(_ context.Context, _ int64, ids []string) PreloadReport { return readinessReport(ids, b) })
			f.verified(a, b)
			f.readyStatus.Store(int64(status))
			f.ready.Store(status == http.StatusOK)
			f.controller.reconcile(context.Background())
			if f.readyCalls.Load() != 1 || f.controller.ReadyFor(a) != (status == http.StatusOK) || f.controller.ReadyFor(b) {
				t.Fatalf("cached supervisor readiness substituted for fresh child confirmation: %+v", f.controller.Status())
			}
			got := f.controller.Status()
			if got.Failures != 1 || got.Runs != 0 || (got.Warm == 1) != (status == http.StatusOK) || got.LastError == "" {
				t.Fatalf("partial/error accounting changed population: %+v", got)
			}
			f.controller.reconcile(context.Background())
			if f.preloads.Load() != 1 || f.readyCalls.Load() != 1 {
				t.Fatal("unchanged failed set did not back off")
			}
		})
	}
}

func TestPreloadFailedMemberBackoffDoesNotIssueExtraControlIO(t *testing.T) {
	a := strings.Repeat("a", 64)
	f := newReadinessControllerFixture(t, func(_ context.Context, _ int64, ids []string) PreloadReport {
		return readinessReport(ids, a)
	})
	f.verified(a)
	f.controller.reconcile(context.Background())
	f.controller.reconcile(context.Background())
	if f.preloads.Load() != 1 || f.readyCalls.Load() != 0 || f.metricsCalls.Load() != 0 {
		t.Fatal("backoff issued extra preload/readiness/metrics IO")
	}
	if got := f.controller.Status(); got.Ready || got.Failures != 1 || got.Runs != 0 {
		t.Fatalf("backoff changed failure/readiness accounting: %+v", got)
	}
}

func TestPreloadVerifiedSetGrowthBypassesOldBackoff(t *testing.T) {
	a, b, c := strings.Repeat("a", 64), strings.Repeat("b", 64), strings.Repeat("c", 64)
	f := newReadinessControllerFixture(t, func(_ context.Context, _ int64, ids []string) PreloadReport { return readinessReport(ids, b) })
	f.verified(a, b)
	f.controller.reconcile(context.Background())
	if !f.controller.ReadyFor(a) {
		t.Fatal("initial partial set unavailable")
	}
	f.verified(a, b, c) // Same catalog generation, new verified membership.
	if f.controller.ReadyFor(a) || f.controller.ReadyFor(c) {
		t.Fatal("changed verified set reused old acknowledgement before polling")
	}
	f.controller.reconcile(context.Background())
	if f.preloads.Load() != 2 || !f.controller.ReadyFor(a) || !f.controller.ReadyFor(c) || f.controller.ReadyFor(b) {
		t.Fatal("old-set retry delay suppressed current verified members")
	}
	got := f.controller.Status()
	if got.Failures != 2 || got.Warm != 3 || got.Runs != 0 || got.ContractCount != 2 {
		t.Fatalf("applied partial accounting: %+v", got)
	}
}

func TestPreloadOversizedAndEmptySetsCloseBeforePolling(t *testing.T) {
	a := strings.Repeat("a", 64)
	f := newReadinessControllerFixture(t, func(_ context.Context, _ int64, ids []string) PreloadReport { return readinessReport(ids, "") })
	f.verified(a)
	f.controller.reconcile(context.Background())
	ids := []string{a}
	for i := 0; i < 8; i++ {
		ids = append(ids, fmt.Sprintf("%064x", i+1))
	}
	f.verified(ids...)
	if f.controller.ReadyFor(a) {
		t.Fatal("oversized same-generation catalog remained usable")
	}
	f.controller.reconcile(context.Background())
	if f.preloads.Load() != 1 || f.controller.Status().Failures != 1 {
		t.Fatal("capacity refusal bypassed old client/pre-HTTP contract")
	}
	f.verified()
	f.controller.reconcile(context.Background())
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
			f := newReadinessControllerFixture(t, func(ctx context.Context, _ int64, ids []string) PreloadReport {
				entered <- struct{}{}
				select {
				case <-release:
				case <-ctx.Done():
				}
				return readinessReport(ids, "")
			})
			f.verified(a)
			done := make(chan struct{})
			go func() { defer close(done); f.controller.reconcile(ctx) }()
			select {
			case <-entered:
			case <-time.After(time.Second):
				t.Fatal("preload never entered real transport")
			}
			switch kind {
			case "verified_growth":
				f.verified(a, b)
			case "child_restart":
				f.supervisor.mu.Lock()
				f.supervisor.status.ChildGeneration++
				f.supervisor.mu.Unlock()
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
