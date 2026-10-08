package promptcontract_test

import (
	"context"
	"encoding/json"
	"net/http"
	"slices"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/catalog"
	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/preload"
	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/sidecar"
)

func transportContinuityController(t *testing.T, count, capacity int, handler http.Handler) (*preload.PreloadController, []preload.VerifiedPreloadArtifact, *atomic.Int64) {
	t.Helper()
	server, socket := startUnixHTTPServer(t, handler)
	t.Cleanup(func() { _ = server.Close() })
	client := sidecar.NewClient(sidecar.ClientConfig{
		SocketPath: socket, MaxPreloadIDs: capacity, MaxResponseBytes: 4096,
		PreloadTimeout: 100 * time.Millisecond, HealthTimeout: 100 * time.Millisecond,
	})
	t.Cleanup(client.Close)
	provisioner := catalog.New()
	input := activeSetInput(count, capacity)
	statuses := make([]catalog.Status, len(input.Verified))
	for i, v := range input.Verified {
		statuses[i] = catalog.Status{ModelID: v.ModelID, ModelAggregateSHA256: v.ModelAggregateSHA256, PromptContractID: v.PromptContractID, ArtifactReady: true}
	}
	provisioner.Replace(statuses)
	clock := new(atomic.Int64)
	child := &preloadChildFixture{status: preload.ChildStatus{Running: true, Ready: true, ChildGeneration: 1}}
	controller, err := preload.New(provisioner, child, client, preload.PreloadControllerConfig{
		PolicyNow:         func() time.Duration { return time.Duration(clock.Load()) },
		FailureBackoffMin: time.Minute, FailureBackoffMax: time.Minute,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(controller.Close)
	controller.SetSelectionSource(func(v []preload.VerifiedPreloadArtifact, _ bool) ([]preload.PreloadDemandIdentity, []string) {
		return slices.Clone(v), nil
	})
	_, verified := provisioner.VerifiedPreloadArtifacts()
	for _, v := range verified[:capacity] {
		if !controller.NoteDemand(v) {
			t.Fatal("initial demand refused")
		}
	}
	return controller, verified, clock
}

func TestPreloadContinuityResponseBodyFailurePreservesIncumbents(t *testing.T) {
	for _, mode := range []string{"truncated", "timeout", "malformed", "oversized", "missing_marker"} {
		t.Run(mode, func(t *testing.T) {
			var calls atomic.Int64
			handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/ready" {
					_ = json.NewEncoder(w).Encode(sidecar.ReadinessStatus{Status: "ok", Ready: true})
					return
				}
				if r.URL.Path != "/v2/preload" {
					http.NotFound(w, r)
					return
				}
				var request struct {
					IDs []string `json:"prompt_contract_ids"`
				}
				if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
					t.Error(err)
					return
				}
				report := readinessReport(request.IDs, request.IDs[1])
				report.ContinuityVersion = 1
				if calls.Add(1) == 1 {
					_ = json.NewEncoder(w).Encode(report)
					return
				}
				switch mode {
				case "truncated", "timeout":
					w.Header().Set("Content-Length", "4096")
					_, _ = w.Write([]byte(`{"continuity_version":1`))
					w.(http.Flusher).Flush()
					if mode == "timeout" {
						<-r.Context().Done()
					} // Returning early leaves a truncated HTTP body, not a completed malformed report.
				case "malformed":
					_, _ = w.Write([]byte(`{`))
				case "oversized":
					_, _ = w.Write(make([]byte, 4097))
				case "missing_marker":
					report.ContinuityVersion = 0
					_ = json.NewEncoder(w).Encode(report)
				}
			})
			controller, verified, clock := transportContinuityController(t, 2, 2, handler)
			controller.Reconcile(context.Background())
			if !controller.ReadyFor(verified[0].PromptContractID) {
				t.Fatal("healthy incumbent was not acknowledged")
			}
			clock.Store(int64(time.Minute))
			controller.Reconcile(context.Background())
			wantRetained := mode == "truncated" || mode == "timeout"
			if got := controller.ReadyFor(verified[0].PromptContractID); got != wantRetained {
				t.Fatalf("incumbent retained=%v, want %v after %s body: %+v", got, wantRetained, mode, controller.Status())
			}
			if controller.ReadyFor(verified[1].PromptContractID) {
				t.Fatal("failed newcomer was acknowledged")
			}
		})
	}
}

func TestPreloadContinuityReadinessTimeoutPreservesSuccessfulIncumbent(t *testing.T) {
	input := activeSetInput(3, 2)
	failedID := input.Verified[2].PromptContractID
	var calls atomic.Int64
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/ready" {
			<-r.Context().Done()
			return
		}
		if r.URL.Path != "/v2/preload" {
			http.NotFound(w, r)
			return
		}
		var request struct {
			IDs []string `json:"prompt_contract_ids"`
		}
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Error(err)
			return
		}
		failed := ""
		if calls.Add(1) == 2 {
			failed = failedID
		}
		report := readinessReport(request.IDs, failed)
		report.ContinuityVersion = 1
		_ = json.NewEncoder(w).Encode(report)
	})
	controller, verified, clock := transportContinuityController(t, 3, 2, handler)
	controller.Reconcile(context.Background())
	if controller.Status().ContractCount != 2 || !controller.NoteDemand(verified[2]) {
		t.Fatalf("setup failed: %+v", controller.Status())
	}
	clock.Store(int64(30 * time.Second))
	controller.Reconcile(context.Background())
	if !controller.ReadyFor(verified[1].PromptContractID) || controller.ReadyFor(failedID) {
		t.Fatalf("partial report lost incumbent or acknowledged newcomer: %+v", controller.Status())
	}
	clock.Store(int64(time.Minute))
	controller.Reconcile(context.Background())
	if !controller.ReadyFor(verified[1].PromptContractID) {
		t.Fatalf("readiness timeout made healthy incumbent the next eviction victim: %+v", controller.Status())
	}
}

func TestPreloadContinuityReadyFailureRetainsOnlyReportedIncumbents(t *testing.T) {
	for _, mode := range []string{"timeout", "body_timeout", "truncated", "malformed", "oversized", "not_ready"} {
		t.Run(mode, func(t *testing.T) {
			input := activeSetInput(4, 3)
			failedID := input.Verified[2].PromptContractID
			var calls atomic.Int64
			handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/ready" {
					switch mode {
					case "timeout":
						<-r.Context().Done()
					case "body_timeout", "truncated":
						w.Header().Set("Content-Length", "4096")
						_, _ = w.Write([]byte(`{"ready":`))
						w.(http.Flusher).Flush()
						if mode == "body_timeout" {
							<-r.Context().Done()
						}
					case "malformed":
						_, _ = w.Write([]byte(`{`))
					case "oversized":
						_, _ = w.Write(make([]byte, 4097))
					case "not_ready":
						w.WriteHeader(http.StatusServiceUnavailable)
						_ = json.NewEncoder(w).Encode(sidecar.ReadinessStatus{Status: "degraded", Ready: false})
					}
					return
				}
				if r.URL.Path != "/v2/preload" {
					http.NotFound(w, r)
					return
				}
				var request struct {
					IDs []string `json:"prompt_contract_ids"`
				}
				if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
					t.Error(err)
					return
				}
				failed := ""
				if calls.Add(1) > 1 {
					failed = failedID
				}
				report := readinessReport(request.IDs, failed)
				report.ContinuityVersion = 1
				_ = json.NewEncoder(w).Encode(report)
			})
			controller, verified, clock := transportContinuityController(t, 4, 3, handler)
			controller.Reconcile(context.Background())
			if controller.Status().ContractCount != 3 || !controller.NoteDemand(verified[3]) {
				t.Fatalf("setup failed: %+v", controller.Status())
			}
			clock.Store(int64(30 * time.Second))
			controller.Reconcile(context.Background())
			wantRetained := mode == "timeout" || mode == "body_timeout" || mode == "truncated"
			if got := controller.ReadyFor(verified[1].PromptContractID); got != wantRetained {
				t.Errorf("incumbent retained=%v after %s readiness failure", got, mode)
			}
			for _, index := range []int{0, 2, 3} {
				if controller.ReadyFor(verified[index].PromptContractID) {
					t.Errorf("evicted, failed, or unconfirmed member %d retained after %s", index, mode)
				}
			}
		})
	}
}
