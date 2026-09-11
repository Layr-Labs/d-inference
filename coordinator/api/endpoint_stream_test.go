package api

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// These policies intentionally differ. Sharing the relay must not make an
// unbilled Messages/Completions close look successful, nor change the legacy
// Responses fallback after settlement consumed the reservation.
func TestEndpointStreamMissingCompletion(t *testing.T) {
	for _, variant := range []string{"responses", "completions", "messages"} {
		for _, reservation := range []string{"none", "outstanding", "settled"} {
			t.Run(variant+"/"+reservation, func(t *testing.T) {
				s := newRelayBenchServer()
				t.Cleanup(s.Close)
				pr := newPrefilledBurstRequest(1, variant)
				<-pr.CompleteCh // leave a closed channel without completion usage
				pr.ConsumerKey = "completion-policy-account"
				if reservation != "none" {
					pr.ReservedMicroUSD = 100
				}
				if reservation == "settled" {
					if claimed, err := pr.FinalizeReservation(nil); err != nil || !claimed {
						t.Fatalf("settle reservation: claimed=%v err=%v", claimed, err)
					}
				}
				w := httptest.NewRecorder()
				r := httptest.NewRequest(http.MethodPost, "/v1/"+variant, nil)
				s.handleStreamingResponseWithFirstChunkAndError(w, r, pr, nil, nil)
				body := w.Body.String()
				wantError := variant != "responses" || reservation == "outstanding"
				if got := strings.Contains(body, "provider ended without completion"); got != wantError {
					t.Fatalf("incomplete error=%v, want %v: %s", got, wantError, body)
				}
				if wantError {
					for _, terminal := range []string{"response.completed", "message_stop", "[DONE]"} {
						if strings.Contains(body, terminal) {
							t.Fatalf("incomplete stream emitted %q: %s", terminal, body)
						}
					}
				} else if !strings.Contains(body, "response.completed") {
					t.Fatalf("settled Responses fallback lost its terminal: %s", body)
				}
				wantRefund := int64(0)
				if reservation == "outstanding" {
					wantRefund = pr.ReservedMicroUSD
				}
				if balance := s.store.GetBalance(pr.ConsumerKey); balance != wantRefund {
					t.Fatalf("refund=%d, want %d", balance, wantRefund)
				}
				if s.refundReservedBalance(pr, "duplicate-terminal") {
					t.Fatal("stream terminal left an outstanding reservation")
				}
			})
		}
	}
}

func TestEndpointStreamInitialErrorPreservesDispatchChunks(t *testing.T) {
	for _, variant := range []string{"responses", "completions", "messages"} {
		t.Run(variant, func(t *testing.T) {
			s := newRelayBenchServer()
			t.Cleanup(s.Close)
			pr := newPrefilledBurstRequest(0, variant)
			pr.ReservedMicroUSD = 123
			pr.ConsumerKey = "initial-error-account"
			w := httptest.NewRecorder()
			s.handleStreamingResponseWithFirstChunkAndError(w,
				httptest.NewRequest(http.MethodPost, "/v1/"+variant, nil), pr,
				[]string{"", chatContentChunk("dispatch-content")},
				&protocol.InferenceErrorMessage{Error: "engine failed", StatusCode: 500})
			body := w.Body.String()
			content := strings.Index(body, "dispatch-content")
			errorEvent := strings.LastIndex(body, `"error"`)
			if content < 0 || errorEvent <= content || !w.Flushed {
				t.Fatalf("dispatch content must be flushed before initial error: %s", body)
			}
			for _, terminal := range []string{"response.completed", "message_stop", "[DONE]"} {
				if strings.Contains(body, terminal) {
					t.Fatalf("initial provider error emitted success %q: %s", terminal, body)
				}
			}
			if got := s.store.GetBalance(pr.ConsumerKey); got != 123 {
				t.Fatalf("initial error refund=%d, want 123", got)
			}
		})
	}
}

func TestEndpointCompletionClientCancellationPolicy(t *testing.T) {
	for _, policy := range []streamCompletionPolicy{requireCompletionMessage, settledReservationCompletes} {
		s := newRelayBenchServer()
		t.Cleanup(s.Close)
		pr := &registry.PendingRequest{CompleteCh: make(chan protocol.UsageInfo)}
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		emitter := &recordingEndpointEmitter{}
		done := make(chan struct{})
		go func() {
			defer close(done)
			s.finishEndpointStream(ctx, pr, emitter, policy)
		}()
		if policy == requireCompletionMessage {
			select {
			case <-done:
			case <-time.After(time.Second):
				t.Fatal("explicit-completion endpoint did not stop on client cancellation")
			}
			if emitter.finished {
				t.Fatal("client cancellation emitted a success terminal")
			}
		} else {
			select {
			case pr.CompleteCh <- protocol.UsageInfo{CompletionTokens: 7}:
			case <-done:
				t.Fatal("Responses stopped its completion wait on client cancellation")
			case <-time.After(time.Second):
				t.Fatal("Responses stopped reading completion usage")
			}
			<-done
			if !emitter.finished || emitter.usage.CompletionTokens != 7 {
				t.Fatalf("Responses lost authoritative usage: %+v", emitter)
			}
		}
	}
}

type recordingEndpointEmitter struct {
	finished bool
	usage    protocol.UsageInfo
}

func (*recordingEndpointEmitter) start()                        {}
func (*recordingEndpointEmitter) handleChunk(string)            {}
func (*recordingEndpointEmitter) emitError(string, string)      {}
func (e *recordingEndpointEmitter) finish(u protocol.UsageInfo) { e.finished, e.usage = true, u }
