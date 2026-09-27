package api

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// A typed drain rejection must fence the provider before releasing its slot.
// No consumer reads ErrorCh here: the ingress-triggered queue drain must make
// the right decision without waiting for consumer-side error classification.
func TestDrainingIngressFencesQueuedDemandBeforeRelease(t *testing.T) {
	for _, reason := range []string{errorReasonDraining, errorReasonCapacityBusy} {
		t.Run(reason, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			srv, _ := testServer(t)
			ts := httptest.NewServer(srv.Handler())
			t.Cleanup(ts.Close)
			const model = "drain-ingress-model"
			fp := startFailoverProvider(t, ctx, ts, srv.registry, failoverProviderConfig{
				Name: "drain-ingress", Version: "0.9.0", DecodeTPS: 100,
				Models: []failoverModelSpec{{ID: model}}, Script: fullServeScript(model),
			})
			p := srv.registry.GetProvider(fp.registryID)
			pr := &registry.PendingRequest{
				RequestID: "rejected", ProviderID: p.ID, Model: model,
				ErrorCh: make(chan protocol.InferenceErrorMessage, 1),
				ChunkCh: make(chan registry.ProviderChunk, 1), CompleteCh: make(chan protocol.UsageInfo, 1),
			}
			p.AddPending(pr)
			waiting := &registry.QueuedRequest{
				RequestID: "waiting", Model: model, ResponseCh: make(chan *registry.Provider, 1),
				Pending: &registry.PendingRequest{
					RequestID: "waiting", Model: model, RequestedMaxTokens: 32, EstimatedPromptTokens: 32,
					ErrorCh: make(chan protocol.InferenceErrorMessage, 1),
					ChunkCh: make(chan registry.ProviderChunk, 1), CompleteCh: make(chan protocol.UsageInfo, 1),
				},
			}
			if err := srv.registry.Queue().Enqueue(waiting); err != nil {
				t.Fatal(err)
			}
			srv.handleInferenceError(p.ID, p, &protocol.InferenceErrorMessage{
				RequestID: pr.RequestID, FailureCode: protocol.FailureCodeCapacity,
				StatusCode: http.StatusServiceUnavailable, ErrorReason: reason,
			})
			if reason == errorReasonDraining {
				if !srv.registry.ProviderDraining(p.ID) {
					t.Error("drain state was deferred to the consumer")
				}
				select {
				case <-waiting.ResponseCh:
					t.Fatal("queued demand was reassigned during the drain rejection")
				default:
				}
				// Recovery can arrive before the consumer processes this terminal.
				// A delayed classification must not mark the provider draining again.
				srv.registry.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle"})
				em := <-pr.ErrorCh
				srv.noteInferenceError(p.ID, pr, em.StatusCode, em.Error, em.ErrorReason, em.TerminalCause, em.CoordinatorCause)
				if srv.registry.ProviderDraining(p.ID) {
					t.Fatal("delayed consumer classification overwrote the recovery heartbeat")
				}
			} else {
				select {
				case assigned := <-waiting.ResponseCh:
					if assigned != p {
						t.Fatal("control did not exercise the released-slot queue drain")
					}
				default:
					t.Fatal("control did not exercise the released-slot queue drain")
				}
			}
		})
	}
}
