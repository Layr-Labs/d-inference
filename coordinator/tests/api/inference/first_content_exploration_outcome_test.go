package inference_test

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/identitygate"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func explorationPending(provider *registry.Provider, id string, explored bool) *registry.PendingRequest {
	pr := &registry.PendingRequest{
		RequestID: id, ProviderID: provider.ID, Model: "test-model",
		ChunkCh:    make(chan registry.ProviderChunk, 1),
		CompleteCh: make(chan protocol.UsageInfo, 1),
		ErrorCh:    make(chan protocol.InferenceErrorMessage, 1),
	}
	pr.SetFirstContentExplored(explored)
	return pr
}

// Exercise both the provider-ingress sanitizer and the consumer-side policy.
func deliverExploredError(t *testing.T, srv *serverFixture, provider *registry.Provider, id string, explored bool, msg protocol.InferenceErrorMessage) *registry.PendingRequest {
	t.Helper()
	pr := explorationPending(provider, id, explored)
	provider.AddPending(pr)
	msg.Type, msg.RequestID = protocol.TypeInferenceError, id
	srv.HandleInferenceError(provider.ID, provider, &msg)
	em, ok := <-pr.ErrorCh
	if !ok {
		t.Fatalf("ErrorCh closed without a terminal for %s", id)
	}
	srv.health.RecordError(provider.ID, pr, em.StatusCode, em.Error, em.ErrorReason, em.TerminalCause, em.CoordinatorCause)
	return pr
}

func TestFirstContentExplorationOutcomeClassification(t *testing.T) {
	cases := []struct {
		name   string
		msg    protocol.InferenceErrorMessage
		counts bool
	}{
		{"deadline_refusal", protocol.InferenceErrorMessage{
			StatusCode: 503, ErrorReason: failure.ErrorReasonDeadlineUnreachable, FailureCode: protocol.FailureCodeCapacity}, true},
		{"genuine_fault", protocol.InferenceErrorMessage{
			StatusCode: 500, FailureCode: protocol.FailureCodeGenerationFailure}, true},
		{"capacity_shed", protocol.InferenceErrorMessage{
			StatusCode: 503, FailureCode: protocol.FailureCodeCapacity}, false},
		{"admission_timeout", protocol.InferenceErrorMessage{
			StatusCode: 500, TerminalCause: failure.TerminalCauseAdmissionTimeout, FailureCode: protocol.FailureCodeGenerationFailure}, false},
		{"safety_deadline", protocol.InferenceErrorMessage{
			StatusCode: 500, TerminalCause: failure.TerminalCauseSafetyDeadline, FailureCode: protocol.FailureCodeGenerationFailure}, false},
		{"backpressure_timeout", protocol.InferenceErrorMessage{
			StatusCode: 500, TerminalCause: failure.TerminalCauseBackpressureTimeout, FailureCode: protocol.FailureCodeGenerationFailure}, false},
		{"cancelled", protocol.InferenceErrorMessage{
			StatusCode: 500, TerminalCause: failure.TerminalCauseCancelled, FailureCode: protocol.FailureCodeGenerationFailure}, false},
		{"deadline_with_neutral_cause", protocol.InferenceErrorMessage{
			StatusCode: 503, ErrorReason: failure.ErrorReasonDeadlineUnreachable,
			TerminalCause: failure.TerminalCauseSafetyDeadline, FailureCode: protocol.FailureCodeCapacity}, false},
		{"deadline_with_capacity_cause", protocol.InferenceErrorMessage{
			StatusCode: 503, ErrorReason: failure.ErrorReasonDeadlineUnreachable,
			TerminalCause: failure.TerminalCauseAdmissionTimeout, FailureCode: protocol.FailureCodeCapacity}, false},
		{"draining", protocol.InferenceErrorMessage{
			StatusCode: 503, ErrorReason: failure.ErrorReasonDraining, FailureCode: protocol.FailureCodeCapacity}, false},
		{"template_failure", protocol.InferenceErrorMessage{
			StatusCode: 500, ErrorReason: failure.ErrorReasonJinjaTemplate, FailureCode: protocol.FailureCodeTemplateRender}, false},
		{"tool_noncompliance", protocol.InferenceErrorMessage{
			StatusCode: 500, ErrorReason: failure.ErrorReasonToolNoncompliance, FailureCode: protocol.FailureCodeGenerationFailure}, false},
		{"media_memory", protocol.InferenceErrorMessage{
			StatusCode: 503, ErrorReason: failure.ErrorReasonMediaMemoryUnavailable, FailureCode: protocol.FailureCodeCapacity}, false},
		{"client_error", protocol.InferenceErrorMessage{
			StatusCode: 400, FailureCode: protocol.FailureCodeInvalidRequest}, false},
	}
	for _, tc := range cases {
		for _, explored := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/explored_%v", tc.name, explored), func(t *testing.T) {
				gates := identitygate.New(nil, nil)
				srv, _, provider, _ := newBreakerExemptionHarness(t, tc.name, registry.Dependencies{IdentityGates: gates})
				t.Cleanup(srv.Close)
				pr := deliverExploredError(t, srv, provider, "req-error", explored, tc.msg)
				view := gates.ViewForSession(nil, provider.ID)
				if got := view.Exploration(pr.Model, time.Now()).Suppressed; got != (explored && tc.counts) {
					t.Fatalf("exploration suppressed=%v, want %v", got, explored && tc.counts)
				}

				// Ignored outcomes must not silently clear existing backoff either.
				if !tc.counts {
					srv.registry.RecordFirstContentExplorationOutcome(provider.ID, pr.Model, false)
					deliverExploredError(t, srv, provider, "req-neutral", explored, tc.msg)
					if !view.Exploration(pr.Model, time.Now()).Suppressed {
						t.Fatal("neutral terminal cleared exploration backoff")
					}
				}
			})
		}
	}
}

func TestFirstContentExplorationTimeoutCountsOnlyOwnedAttempts(t *testing.T) {
	for _, explored := range []bool{false, true} {
		for _, ingress := range []string{"none", "removed", "chunk_pending", "content", "completion", "late_completion"} {
			t.Run(fmt.Sprintf("%s/explored_%v", ingress, explored), func(t *testing.T) {
				gates := identitygate.New(nil, nil)
				srv, reg, provider, _ := newBreakerExemptionHarness(t, "timeout", registry.Dependencies{IdentityGates: gates})
				t.Cleanup(srv.Close)
				pr := explorationPending(provider, "req-timeout", explored)
				pr.FirstContentDeadline = time.Now().Add(time.Minute)
				provider.AddPending(pr)
				switch ingress {
				case "removed":
					provider.RemovePending(pr.RequestID)
				case "chunk_pending", "content":
					_, receivedAt := provider.BeginPendingChunkIngress(pr.RequestID)
					if ingress == "content" {
						pr.FinishProviderChunkIngress(receivedAt, true)
					}
				case "completion":
					pr.MarkCompletionIngress(pr.FirstContentDeadline.Add(-time.Millisecond))
				case "late_completion":
					pr.MarkCompletionIngress(pr.FirstContentDeadline.Add(time.Millisecond))
				}
				wantClaimed := ingress == "none" || ingress == "late_completion"
				if got := srv.cancels.CancelDispatchForFirstContentTimeout(provider, pr); got != wantClaimed {
					t.Fatalf("timeout claimed=%v, want %v", got, wantClaimed)
				}
				if srv.cancels.CancelDispatchForFirstContentTimeout(provider, pr) {
					t.Fatal("a repeated timeout claimed the same attempt")
				}
				if got := gates.ViewForSession(nil, provider.ID).Exploration(pr.Model, time.Now()).Suppressed; got != (explored && wantClaimed) {
					t.Fatalf("exploration suppressed=%v, want %v", got, explored && wantClaimed)
				}
				assertBreakerStates(t, reg, provider, pr, false)
				if explored && wantClaimed {
					srv.health.Success(explorationPending(provider, "req-recover", true))
					if gates.ViewForSession(nil, provider.ID).Exploration(pr.Model, time.Now()).Suppressed {
						t.Fatal("one success must clear the single owned timeout, including repeated cleanup")
					}
				}
			})
		}
	}
}

func TestFirstContentExplorationDeadlineAndShortTimeoutStayHealthNeutral(t *testing.T) {
	for _, outcome := range []string{"deadline_refusal", "first_content_timeout"} {
		t.Run(outcome, func(t *testing.T) {
			gates := identitygate.New(nil, nil)
			srv, reg, provider, _ := newBreakerExemptionHarness(t, outcome, registry.Dependencies{IdentityGates: gates})
			t.Cleanup(srv.Close)
			var pr *registry.PendingRequest
			for i := range breakerStrikeRounds {
				id := fmt.Sprintf("req-neutral-%d", i)
				if outcome == "deadline_refusal" {
					pr = deliverExploredError(t, srv, provider, id, true, protocol.InferenceErrorMessage{
						StatusCode: 503, ErrorReason: failure.ErrorReasonDeadlineUnreachable, FailureCode: protocol.FailureCodeCapacity,
					})
				} else {
					pr = explorationPending(provider, id, true)
					provider.AddPending(pr)
					timeout := srv.NewWaitTimeout(attempt.TimeoutConfig{Provider: provider, Pending: pr, Model: pr.Model, RequestID: id})
					if !timeout.Run(context.Background(), attempt.FirstContentTimeout, time.Second).Claimed {
						t.Fatal("timeout did not claim the pending attempt")
					}
				}
			}
			if !gates.ViewForSession(nil, provider.ID).Exploration(pr.Model, time.Now()).Suppressed {
				t.Fatal("explored failures did not back exploration off")
			}
			assertBreakerStates(t, reg, provider, pr, false)
			if reg.CapacityCooldownActive(provider.ID, pr.Model) {
				t.Fatal("deadline/short timeout must not strike capacity cooldown")
			}
			provider.Mu().Lock()
			failed := provider.Reputation.FailedJobs
			provider.Mu().Unlock()
			if failed != 0 {
				t.Fatalf("health-neutral outcome recorded %d reputation failures", failed)
			}
		})
	}
}

func TestFirstContentExplorationAttributableStallCountsOnce(t *testing.T) {
	gates := identitygate.New(nil, nil)
	srv, _, provider, _ := newBreakerExemptionHarness(t, "stall", registry.Dependencies{IdentityGates: gates})
	t.Cleanup(srv.Close)
	pr := explorationPending(provider, "req-stall", true)
	provider.AddPending(pr)
	timeout := srv.NewWaitTimeout(attempt.TimeoutConfig{Provider: provider, Pending: pr, Model: pr.Model, RequestID: pr.RequestID})
	// A long attributable stall also feeds the existing health fault policy.
	// That second feed must not count this exploration failure a second time.
	if !timeout.Run(context.Background(), attempt.FirstContentTimeout, firstcontent.PreambleContentTimeout).Claimed {
		t.Fatal("timeout did not claim the pending attempt")
	}
	view := gates.ViewForSession(nil, provider.ID)
	if !view.Exploration(pr.Model, time.Now()).Suppressed {
		t.Fatal("timeout did not suppress exploration")
	}
	srv.health.Success(explorationPending(provider, "req-recover", true))
	if view.Exploration(pr.Model, time.Now()).Suppressed {
		t.Fatal("one success did not clear one stall; timeout and fault were counted twice")
	}
}

func TestFirstContentExplorationDeliveredSuccessRecovers(t *testing.T) {
	for _, explored := range []bool{false, true} {
		for _, failures := range []int{1, 2} {
			t.Run(fmt.Sprintf("failures_%d/explored_%v", failures, explored), func(t *testing.T) {
				gates := identitygate.New(nil, nil)
				srv, reg, provider, _ := newBreakerExemptionHarness(t, "success", registry.Dependencies{IdentityGates: gates})
				t.Cleanup(srv.Close)
				pr := explorationPending(provider, "req-success", explored)
				for range failures {
					reg.RecordFirstContentExplorationOutcome(provider.ID, pr.Model, false)
				}
				view := gates.ViewForSession(nil, provider.ID)
				if !view.Exploration(pr.Model, time.Now()).Suppressed {
					t.Fatal("setup: failure did not suppress exploration")
				}
				close(pr.ChunkCh)
				pr.CompleteCh <- protocol.UsageInfo{CompletionTokens: 1}
				rr := httptest.NewRecorder()
				srv.NewRelay().NonStream(rr, httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil), pr,
					[]string{`data: {"choices":[{"delta":{"content":"ok"}}]}`}, nil)
				if rr.Code != http.StatusOK || !strings.Contains(rr.Body.String(), `"content":"ok"`) {
					t.Fatalf("success not delivered: status=%d body=%s", rr.Code, rr.Body.String())
				}
				wantSuppressed := !explored || failures > 1
				if got := view.Exploration(pr.Model, time.Now()).Suppressed; got != wantSuppressed {
					t.Fatalf("exploration suppressed=%v, want %v after delivery", got, wantSuppressed)
				}
				srv.health.Success(pr)
				if got := view.Exploration(pr.Model, time.Now()).Suppressed; got != wantSuppressed {
					t.Fatal("duplicate success changed exploration backoff")
				}
			})
		}
	}
}
