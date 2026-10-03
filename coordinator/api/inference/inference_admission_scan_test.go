package inference

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// The planner stands in for a stalled prompt-contract sidecar. Another fleet
// scan must be able to take every permit while primary or fallback planning is
// blocked; after planning, admission must acquire a permit again before walking.
func TestPreflightPlanningReleasesRoutingScanPermit(t *testing.T) {
	for _, stage := range []string{"primary", "capacity_fallback", "ttft_fallback", "fallback_body"} {
		for _, outcome := range []string{"resume", "saturated", "cancelled"} {
			t.Run(stage+"/"+outcome, func(t *testing.T) {
				srv, st := testServer(t)
				srv.SetRoutingConcurrency(2)
				const desired, previous, public = "planning-desired", "planning-previous", "planning-alias"
				srv.registry.SetModelCatalog([]registry.CatalogEntry{{ID: desired, SizeGB: 1, MinRAMGB: 24}, {ID: previous, SizeGB: 1, MinRAMGB: 24}})
				srv.registry.SetModelAliases(map[string]registry.AliasTarget{public: {Desired: desired, Previous: previous}})
				desiredProvider := registerBuildsProvider(srv, "desired", desired)
				registerBuildsProvider(srv, "previous", previous)
				if stage == "ttft_fallback" {
					srv.ttftHardReject = true
					reportMeasuredFirstContentEvidence(t, srv.registry, desiredProvider.ID, desired, 10, 100)
					reportMeasuredFirstContentEvidence(t, srv.registry, "previous", previous, 1000, 1000)
				} else if stage != "primary" {
					desiredProvider.Mu().Lock()
					desiredProvider.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 4096
					desiredProvider.BackendCapacity.Slots[0].ActiveTokenBudgetUsed = 4096
					desiredProvider.Mu().Unlock()
				}

				ctx, cancel := context.WithCancel(context.Background())
				defer cancel()
				entered, unblock, finished := make(chan struct{}), make(chan struct{}), make(chan struct{})
				var releaseOnce sync.Once
				release := func() { releaseOnce.Do(func() { close(unblock) }) }
				defer release()
				block := func() { close(entered); <-unblock }
				var refunds atomic.Int32
				w := httptest.NewRecorder()
				r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil).WithContext(ctx)
				parsed := map[string]any{"model": desired}
				p := inferenceAdmissionParams{
					model: desired, publicModel: public, estimatedPromptTokens: 100, requestedMaxTokens: 64,
					deadline: 5 * time.Second, receivedAt: time.Now(), refundReservation: func() { refunds.Add(1) },
					cachePlanForModel: func(model string) registry.CachePlan {
						if (stage == "primary" && model == desired) || ((stage == "capacity_fallback" || stage == "ttft_fallback") && model == previous) {
							block()
						}
						return registry.CachePlan{}
					},
				}
				if stage == "fallback_body" {
					p.onModelFallback = func(string) bool { block(); return true }
				}
				var finalModel string
				var handled bool
				go func() {
					defer close(finished)
					finalModel, handled = srv.runInferenceAdmission(w, r, parsed, p)
				}()
				select {
				case <-entered:
				case <-finished:
					t.Fatalf("admission completed without reaching %s planner: status=%d body=%s", stage, w.Code, w.Body.String())
				case <-time.After(3 * time.Second):
					t.Fatal("planner never started")
				}
				// Taking both permits proves the blocked planner owns neither.
				for i := 0; i < cap(srv.routingScanSem); i++ {
					select {
					case srv.routingScanSem <- struct{}{}:
					default:
						release()
						<-finished
						t.Fatal("external planning occupied a CPU scan permit")
					}
				}
				if outcome == "cancelled" {
					cancel()
				}
				release()
				if outcome == "resume" {
					select {
					case <-finished:
						t.Fatal("admission scanned without reacquiring a permit")
					case <-time.After(20 * time.Millisecond):
					}
					for i := 0; i < cap(srv.routingScanSem); i++ {
						<-srv.routingScanSem
					}
				}
				select {
				case <-finished:
				case <-time.After(3 * time.Second):
					t.Fatal("admission failed to settle after planner returned")
				}
				if outcome != "resume" {
					if len(srv.routingScanSem) != cap(srv.routingScanSem) {
						t.Fatal("failed admission released a permit it did not own")
					}
					for i := 0; i < cap(srv.routingScanSem); i++ {
						<-srv.routingScanSem
					}
				}
				if len(srv.routingScanSem) != 0 {
					t.Fatal("admission leaked a scan permit")
				}
				switch outcome {
				case "resume":
					wantModel := previous
					if stage == "primary" {
						wantModel = desired
					}
					if handled || refunds.Load() != 0 || finalModel != wantModel {
						t.Fatalf("resumed admission: handled=%v refunds=%d model=%s status=%d body=%s", handled, refunds.Load(), finalModel, w.Code, w.Body.String())
					}
				case "saturated":
					if !handled || refunds.Load() != 1 || w.Code != http.StatusTooManyRequests || !strings.Contains(w.Body.String(), "routing capacity") {
						t.Fatalf("saturated admission: handled=%v refunds=%d status=%d body=%s", handled, refunds.Load(), w.Code, w.Body.String())
					}
				case "cancelled":
					if !handled || refunds.Load() != 1 || w.Body.Len() != 0 || len(st.RejectionRecordsSince(time.Time{})) != 0 {
						t.Fatalf("cancelled admission: handled=%v refunds=%d status=%d body=%s", handled, refunds.Load(), w.Code, w.Body.String())
					}
				}
			})
		}
	}
}

func TestPreflightScanWaitDoesNotRenewExpiredBudget(t *testing.T) {
	if got := preflightScanWait(time.Nanosecond); got != time.Nanosecond {
		t.Fatalf("expired budget wait=%v, want one nanosecond", got)
	}
}
