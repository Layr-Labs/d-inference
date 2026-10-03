package inference

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

type outcomeFailWriter struct {
	header http.Header
	short  bool
}

func (w *outcomeFailWriter) Header() http.Header {
	if w.header == nil {
		w.header = make(http.Header)
	}
	return w.header
}

func (w *outcomeFailWriter) WriteHeader(int) {}

func (w *outcomeFailWriter) Flush() {}

func (w *outcomeFailWriter) Write(b []byte) (int, error) {
	if w.short {
		return len(b) - 1, nil
	}
	return 0, errors.New("client transport failed")
}

func TestRequestOutcomeFailedAndShortWrites(t *testing.T) {
	for _, short := range []bool{false, true} {
		t.Run(fmt.Sprint(short), func(t *testing.T) {
			srv, st := terminalOutcomeServer(t)
			defer srv.observation.CloseProfilesAndOutcomes()
			handler := srv.observation.ObserveRequestOutcome(func(w http.ResponseWriter, r *http.Request) {
				rp := srv.observation.NewRequestProfile(r, "m", "m", false)
				ap := rp.NewAttempt("a", 0, "")
				ap.Winning.Store(true)
				ap.SetOutcome("success", "", "", "completed", "")
				observation.WriteNonStreamBody(w, rp, map[string]any{"choices": []any{map[string]any{"message": map[string]any{"content": "answer"}}}})
				ap.CompleteTerminal()
				ap.CompleteHandler()
			})
			handler(&outcomeFailWriter{short: short}, httptest.NewRequest("POST", "/v1/chat/completions", nil))
			srv.observation.CloseProfilesAndOutcomes()
			r := awaitRequestOutcomes(t, st, 1)[0]
			if r.Termination != "interrupted_response" || r.EgressCompleted || r.ContentWriteCompleted || !r.ClientWriteError {
				t.Fatalf("failed output %+v", r)
			}
		})
	}
}

func TestRequestOutcomeLateProviderCompletionPreservesDeparture(t *testing.T) {
	srv, st := terminalOutcomeServer(t)
	defer srv.observation.CloseProfilesAndOutcomes()
	var ap *registry.AttemptProfile
	ctx, cancel := context.WithCancel(context.Background())
	handler := srv.observation.ObserveRequestOutcome(func(w http.ResponseWriter, r *http.Request) {
		rp := srv.observation.NewRequestProfile(r, "m", "m", true)
		ap = rp.NewAttempt("late-a", 0, "")
		ap.Winning.Store(true)
		ap.Mark(registry.StampWriteDone)
		ap.GeneratedContentObserved.Store(true)
		ap.CompleteHandler()
		cancel()
	})
	handler(httptest.NewRecorder(), httptest.NewRequest("POST", "/v1/chat/completions", nil).WithContext(ctx))
	ap.SetOutcome("partial_success", "client_gone_after_commit_provider_completed", "", "completed", "")
	ap.CompleteTerminal()
	ap.CompleteTerminal()
	r := awaitRequestOutcomes(t, st, 1)[0]
	if r.Termination != "client_departure" || r.ProviderOutcome != "completed" || r.EgressCompleted || len(r.Attempts) != 1 {
		t.Fatalf("late completion %+v", r)
	}
}

func TestRequestOutcomeSealedWriteFailure(t *testing.T) {
	for _, stream := range []bool{false, true} {
		for _, short := range []bool{false, true} {
			t.Run(fmt.Sprintf("stream=%t/short=%t", stream, short), func(t *testing.T) {
				srv, st := terminalOutcomeServer(t)
				defer srv.observation.CloseProfilesAndOutcomes()
				coord, err := e2e.DeriveCoordinatorKey(senderTestMnemonic)
				if err != nil {
					t.Fatal(err)
				}
				srv.SetCoordinatorKey(coord)
				encrypted, _, _ := sealRequest(t, []byte(`{"model":"m"}`), coord.PublicKey, coord.KID)
				handler := srv.observation.ObserveRequestOutcome(srv.SealedTransport(func(w http.ResponseWriter, r *http.Request) {
					rp := srv.observation.NewRequestProfile(r, "m", "m", stream)
					ap := rp.NewAttempt("sealed-attempt", 0, "")
					ap.Winning.Store(true)
					ap.SetOutcome("success", "", "", "completed", "")
					if stream {
						w.Header().Set("Content-Type", "text/event-stream")
						w.WriteHeader(200)
						frame := []byte(contentChunkSSE("m", "answer"))
						n, err := w.Write(frame)
						observation.MarkContentWrite(w, true, n, len(frame), err)
						observation.NewRelayStamps(rp).Done()
					} else {
						observation.WriteNonStreamBody(w, rp, map[string]any{"choices": []any{map[string]any{"message": map[string]any{"content": "answer"}}}})
					}
					ap.CompleteTerminal()
					ap.CompleteHandler()
				}))
				req := httptest.NewRequest("POST", "/v1/chat/completions", bytes.NewReader(encrypted))
				req.Header.Set("Content-Type", SealedContentType)
				handler(&outcomeFailWriter{short: short}, req)
				srv.observation.CloseProfilesAndOutcomes()
				r := awaitRequestOutcomes(t, st, 1)[0]
				if r.Termination != "interrupted_response" || r.EgressCompleted || r.ContentWriteCompleted || !r.ClientWriteError {
					t.Fatalf("sealed outer write failure %+v", r)
				}
			})
		}
	}
}

type outcomeFailAfterFirstWriter struct {
	outcomeFailWriter
	writes int
}

func (w *outcomeFailAfterFirstWriter) Write(b []byte) (int, error) {
	w.writes++
	if w.writes == 1 {
		return len(b), nil
	}
	return 0, errors.New("second write failed")
}

func TestRequestOutcomeContentSuccessSurvivesLaterWriteFailure(t *testing.T) {
	for _, sealed := range []bool{false, true} {
		t.Run(fmt.Sprint(sealed), func(t *testing.T) {
			srv, st := terminalOutcomeServer(t)
			defer srv.observation.CloseProfilesAndOutcomes()
			write := func(w http.ResponseWriter, r *http.Request) {
				rp := srv.observation.NewRequestProfile(r, "m", "m", true)
				ap := rp.NewAttempt("two-write-attempt", 0, "")
				ap.Winning.Store(true)
				ap.SetOutcome("success", "", "", "completed", "")
				w.Header().Set("Content-Type", "text/event-stream")
				w.WriteHeader(200)
				frame := []byte(contentChunkSSE("m", "answer"))
				n, err := w.Write(frame)
				observation.MarkContentWrite(w, true, n, len(frame), err)
				w.Write([]byte("data: [DONE]\n\n"))
				observation.NewRelayStamps(rp).Done()
				ap.CompleteTerminal()
				ap.CompleteHandler()
			}
			req := httptest.NewRequest("POST", "/v1/chat/completions", nil)
			if sealed {
				coord, err := e2e.DeriveCoordinatorKey(senderTestMnemonic)
				if err != nil {
					t.Fatal(err)
				}
				srv.SetCoordinatorKey(coord)
				encrypted, _, _ := sealRequest(t, []byte(`{"model":"m"}`), coord.PublicKey, coord.KID)
				req = httptest.NewRequest("POST", "/v1/chat/completions", bytes.NewReader(encrypted))
				req.Header.Set("Content-Type", SealedContentType)
				write = srv.SealedTransport(write)
			}
			srv.observation.ObserveRequestOutcome(write)(&outcomeFailAfterFirstWriter{}, req)
			srv.observation.CloseProfilesAndOutcomes()
			r := awaitRequestOutcomes(t, st, 1)[0]
			if !r.ContentWriteCompleted || !r.ClientWriteError || r.EgressCompleted || r.Termination != "interrupted_response" {
				t.Fatalf("earlier content evidence lost: %+v", r)
			}
		})
	}
}
