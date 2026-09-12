package api

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// A completion waiting for speculative arbitration has not removed pending
// state. Legacy profiler-off lets a subsequent error own RemovePending. Compact
// accounting must preserve that behavior, while profiling-on keeps its existing
// earlier claim arbitration. This test exercises real terminal handlers.
func TestRequestOutcomeCompactProfilePreservesTerminalArbitration(t *testing.T) {
	for _, mode := range []string{"legacy_nil", "compact", "heavy"} {
		t.Run(mode, func(t *testing.T) {
			if mode != "heavy" {
				t.Setenv(envProfiler, "off")
			}
			srv := newTestServerForDispatch(t)
			defer srv.Close()
			provider := srv.registry.Register("arbitration-provider", nil, &protocol.RegisterMessage{Type: protocol.TypeRegister, Hardware: protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64}, Models: []protocol.ModelInfo{{ID: "m", ModelType: "chat"}}, Backend: "mlx-swift"})
			srv.observeRequestOutcome(func(w http.ResponseWriter, r *http.Request) {
				var rp *registry.RequestProfile
				var ap *registry.AttemptProfile
				if mode != "legacy_nil" {
					rp = srv.newRequestProfile(r, "m", "m", false)
					ap = rp.NewAttempt("arbitration-request", 0, "")
					ap.Mark(registry.StampWriteSubmitted)
					ap.Mark(registry.StampWriteDone)
					ap.Winning.Store(true)
				}
				pr := &registry.PendingRequest{RequestID: "arbitration-request", Profile: ap, Model: "m", FirstContentDeadline: time.Now().Add(time.Minute), ChunkCh: make(chan registry.ProviderChunk, 1), CompleteCh: make(chan protocol.UsageInfo, 1), ErrorCh: make(chan protocol.InferenceErrorMessage, 1)}
				pr.EnableSpeculativeEmptyCompletionArbitration()
				provider.AddPending(pr)
				done := make(chan struct{})
				go func() {
					srv.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{Type: protocol.TypeInferenceComplete, RequestID: pr.RequestID, Usage: protocol.UsageInfo{PromptTokens: 5, CompletionTokens: 0}})
					close(done)
				}()
				<-pr.CompletionIngressSignal()
				if mode == "heavy" {
					deadline := time.Now().Add(time.Second)
					for !ap.TerminalClaimed() {
						if time.Now().After(deadline) {
							t.Fatal("completion did not claim")
						}
						time.Sleep(time.Millisecond)
					}
				}
				srv.handleInferenceError(provider.ID, provider, &protocol.InferenceErrorMessage{Type: protocol.TypeInferenceError, RequestID: pr.RequestID, StatusCode: 500})
				if mode == "heavy" {
					if provider.GetPending(pr.RequestID) == nil {
						t.Fatal("heavy profile arbitration changed")
					}
				} else {
					if provider.GetPending(pr.RequestID) != nil {
						t.Fatal("compact observer stole RemovePending arbitration from error")
					}
				}
				pr.ResolveSpeculativeEmptyCompletion(true)
				select {
				case <-done:
				case <-time.After(time.Second):
					t.Fatal("completion remained blocked")
				}
				if mode != "heavy" {
					select {
					case e := <-pr.ErrorCh:
						if e.StatusCode != 500 {
							t.Fatalf("error=%+v", e)
						}
					default:
						t.Fatal("error winner did not reach consumer")
					}
					select {
					case u, ok := <-pr.CompleteCh:
						if ok {
							t.Fatalf("discarded completion reached consumer %+v", u)
						}
					default:
					}
					if ap != nil {
						_, _, _, outcome, _ := ap.Outcome()
						if outcome != "error" {
							t.Fatalf("compact observer retained discarded completion: %s", outcome)
						}
					}
				}
				ap.CompleteHandler()
				w.WriteHeader(500)
			})(httptest.NewRecorder(), httptest.NewRequest("POST", "/v1/chat/completions", nil))
			if mode == "compact" {
				r := awaitRequestOutcomes(t, srv.store, 1)[0]
				if r.ProviderOutcome != "error" {
					t.Fatalf("compact terminal owner=%+v", r)
				}
			}
		})
	}
}

// A discarded empty completion remains an observed terminal even though legacy
// arbitration accepted no completion for that losing attempt.
func TestRequestOutcomeCompactEmptyLoserKeepsReceivedEvidence(t *testing.T) {
	for _, readerFirst := range []bool{false, true} {
		t.Run(fmt.Sprint(readerFirst), func(t *testing.T) {
			t.Setenv(envProfiler, "off")
			srv := newTestServerForDispatch(t)
			defer srv.Close()
			provider := srv.registry.Register("empty-loser-provider", nil, &protocol.RegisterMessage{Models: []protocol.ModelInfo{{ID: "m", ModelType: "chat"}}})
			srv.observeRequestOutcome(func(w http.ResponseWriter, r *http.Request) {
				rp := srv.newRequestProfile(r, "m", "m", true)
				ap := rp.NewAttempt("empty-loser", 0, "")
				ap.Mark(registry.StampWriteSubmitted)
				ap.Mark(registry.StampWriteDone)
				pr := &registry.PendingRequest{RequestID: ap.RequestID, Profile: ap, Model: "m", FirstContentDeadline: time.Now().Add(time.Minute), ChunkCh: make(chan registry.ProviderChunk, 1), CompleteCh: make(chan protocol.UsageInfo, 1), ErrorCh: make(chan protocol.InferenceErrorMessage, 1)}
				pr.EnableSpeculativeEmptyCompletionArbitration()
				provider.AddPending(pr)
				done := make(chan struct{})
				go func() {
					srv.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{Type: protocol.TypeInferenceComplete, RequestID: pr.RequestID})
					close(done)
				}()
				<-pr.CompletionIngressSignal()
				funnel := func() { (&dispatchState{s: srv}).markSpeculativeLoser(pr); ap.CompleteHandler() }
				release := func() {
					pr.ResolveSpeculativeEmptyCompletion(false)
					provider.RemovePending(pr.RequestID)
					select {
					case <-done:
					case <-time.After(time.Second):
						t.Fatal("loser remained blocked")
					}
				}
				if readerFirst {
					release()
					funnel()
				} else {
					funnel()
					release()
				}
				w.WriteHeader(503)
			})(httptest.NewRecorder(), httptest.NewRequest("POST", "/v1/chat/completions", nil))
			r := awaitRequestOutcomes(t, srv.store, 1)[0]
			if len(r.Attempts) != 1 || !r.Attempts[0].ProviderCompleteObserved || r.Attempts[0].ProviderOutcome != "unknown" || r.Attempts[0].Winning || r.ProviderOutcome != "no_terminal" {
				t.Fatalf("discarded terminal evidence=%+v", r)
			}
		})
	}
}
