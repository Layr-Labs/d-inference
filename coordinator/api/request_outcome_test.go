package api

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestRequestOutcomeClassificationAndMappings(t *testing.T) {
	now := time.Now()
	for _, tc := range []struct {
		name       string
		r          store.RequestOutcomeRecord
		want, code string
	}{
		{"recovered deadline", store.RequestOutcomeRecord{HTTPStatus: 200, ProviderOutcome: "completed", EgressCompleted: true}, "completed", ""},
		{"departure after provider completion", store.RequestOutcomeRecord{HTTPStatus: 200, ProviderOutcome: "completed", EgressCompleted: true, ClientDeparted: true}, "client_departure", ""},
		{"precontent cancellation with planned429", store.RequestOutcomeRecord{HTTPStatus: 429, ClientDeparted: true, RawStage: "dispatch", RawReason: "first_chunk_timeout"}, "client_departure", ""},
		{"nonstream failure before body", store.RequestOutcomeRecord{HTTPStatus: 502, ProviderContentObserved: true, ProviderOutcome: "error"}, "rejected", "ext_unknown"},
		{"stream incomplete", store.RequestOutcomeRecord{HTTPStatus: 200, ProviderContentObserved: true, ContentWriteCompleted: true}, "interrupted_response", ""},
		{"write failure", store.RequestOutcomeRecord{HTTPStatus: 200, ProviderOutcome: "completed", ClientWriteError: true}, "interrupted_response", ""},
		{"zero token complete", store.RequestOutcomeRecord{HTTPStatus: 200, ProviderOutcome: "completed", EgressCompleted: true}, "completed", ""},
		{"preamble only", store.RequestOutcomeRecord{HTTPStatus: 200, EgressCompleted: true}, "unknown", ""},
		{"final timeout", store.RequestOutcomeRecord{HTTPStatus: 429, RawStage: "dispatch", RawReason: "first_chunk_timeout"}, "rejected", "ext_first_content_timeout"},
		{"deadline exhaustion", store.RequestOutcomeRecord{HTTPStatus: 429, RawStage: "dispatch", RawReason: "deadline_unreachable"}, "rejected", "ext_coordinator_exhausted"},
		{"typed provider timeout", store.RequestOutcomeRecord{HTTPStatus: 504, RawStage: "dispatch", RawReason: "dispatch_exhausted"}, "rejected", "ext_legacy:dispatch_exhausted"},
		{"queue timeout", store.RequestOutcomeRecord{HTTPStatus: 429, RawStage: "queue", RawReason: "queue_timeout"}, "rejected", "ext_legacy:queue_timeout"},
		{"conflicting evidence", store.RequestOutcomeRecord{HTTPStatus: 200, EgressCompleted: true, ProviderOutcome: "completed", EvidenceConflict: true}, "unknown", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tc.r.HandlerFinishedAt = &now
			classifyRequestOutcome(&tc.r)
			if tc.r.Termination != tc.want || tc.r.NormalizedCode != tc.code {
				t.Fatalf("got %+v", tc.r)
			}
		})
	}
	if got := normalizedAttemptOutcome("deadline_unreachable"); got != "int_provider_deadline_rejected" {
		t.Fatal(got)
	}
}

func TestGeneratedContentEvidenceExcludesPreambleAndTerminals(t *testing.T) {
	for _, s := range []string{`data: [DONE]`, `data: {broken`, roleOnlyChunkSSE("m"), `data: {"choices":[{"delta":{},"finish_reason":"stop"}]}`, `data: {"type":"response.created","response":{}}`, `data: {"error":{"message":"secret"}}`, `data: {"choices":[],"usage":{"completion_tokens":0}}`} {
		if generatedContentSSE([]byte(s)) {
			t.Errorf("false content: %s", s)
		}
	}
	for _, s := range []string{contentChunkSSE("m", "a"), `data: {"type":"response.output_text.delta","delta":"a"}`, `data: {"type":"content_block_delta","delta":{"text":"a"}}`} {
		if !generatedContentSSE([]byte(s)) {
			t.Errorf("missed content %s", s)
		}
	}
}

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
func (w *outcomeFailWriter) Flush()          {}
func (w *outcomeFailWriter) Write(b []byte) (int, error) {
	if w.short {
		return len(b) - 1, nil
	}
	return 0, errors.New("client transport failed")
}

func TestRequestOutcomeFailedAndShortWrites(t *testing.T) {
	for _, short := range []bool{false, true} {
		t.Run(fmt.Sprint(short), func(t *testing.T) {
			st := store.NewMemory(store.Config{})
			srv := &Server{store: st}
			srv.requestOutcomes = newRequestOutcomeSink(srv, 16)
			defer srv.requestOutcomes.close()
			handler := srv.observeRequestOutcome(func(w http.ResponseWriter, r *http.Request) {
				rp := srv.newRequestProfile(r, "m", "m", false)
				ap := rp.NewAttempt("a", 0, "")
				ap.Winning.Store(true)
				ap.SetOutcome("success", "", "", "completed", "")
				writeNonStreamBody(w, rp, map[string]any{"choices": []any{map[string]any{"message": map[string]any{"content": "answer"}}}})
				ap.CompleteTerminal()
				ap.CompleteHandler()
			})
			handler(&outcomeFailWriter{short: short}, httptest.NewRequest("POST", "/v1/chat/completions", nil))
			r := awaitRequestOutcomes(t, st, 1)[0]
			if r.Termination != "interrupted_response" || r.EgressCompleted || r.ContentWriteCompleted || !r.ClientWriteError {
				t.Fatalf("failed output %+v", r)
			}
		})
	}
}

func TestRequestOutcomeLateProviderCompletionPreservesDeparture(t *testing.T) {
	st := store.NewMemory(store.Config{})
	srv := &Server{store: st}
	srv.requestOutcomes = newRequestOutcomeSink(srv, 16)
	defer srv.requestOutcomes.close()
	var ap *registry.AttemptProfile
	ctx, cancel := context.WithCancel(context.Background())
	handler := srv.observeRequestOutcome(func(w http.ResponseWriter, r *http.Request) {
		rp := srv.newRequestProfile(r, "m", "m", true)
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
				st := store.NewMemory(store.Config{})
				srv := &Server{store: st}
				srv.requestOutcomes = newRequestOutcomeSink(srv, 16)
				defer srv.requestOutcomes.close()
				coord, err := e2e.DeriveCoordinatorKey(senderTestMnemonic)
				if err != nil {
					t.Fatal(err)
				}
				srv.SetCoordinatorKey(coord)
				encrypted, _, _ := sealRequest(t, []byte(`{"model":"m"}`), coord.PublicKey, coord.KID)
				handler := srv.observeRequestOutcome(srv.sealedTransport(func(w http.ResponseWriter, r *http.Request) {
					rp := srv.newRequestProfile(r, "m", "m", stream)
					ap := rp.NewAttempt("sealed-attempt", 0, "")
					ap.Winning.Store(true)
					ap.SetOutcome("success", "", "", "completed", "")
					if stream {
						w.Header().Set("Content-Type", "text/event-stream")
						w.WriteHeader(200)
						frame := []byte(contentChunkSSE("m", "answer"))
						n, err := w.Write(frame)
						markContentWrite(w, true, n, len(frame), err)
						newRelayStamps(rp).done()
					} else {
						writeNonStreamBody(w, rp, map[string]any{"choices": []any{map[string]any{"message": map[string]any{"content": "answer"}}}})
					}
					ap.CompleteTerminal()
					ap.CompleteHandler()
				}))
				req := httptest.NewRequest("POST", "/v1/chat/completions", bytes.NewReader(encrypted))
				req.Header.Set("Content-Type", SealedContentType)
				handler(&outcomeFailWriter{short: short}, req)
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
			st := store.NewMemory(store.Config{})
			srv := &Server{store: st}
			srv.requestOutcomes = newRequestOutcomeSink(srv, 16)
			defer srv.requestOutcomes.close()
			write := func(w http.ResponseWriter, r *http.Request) {
				rp := srv.newRequestProfile(r, "m", "m", true)
				ap := rp.NewAttempt("two-write-attempt", 0, "")
				ap.Winning.Store(true)
				ap.SetOutcome("success", "", "", "completed", "")
				w.Header().Set("Content-Type", "text/event-stream")
				w.WriteHeader(200)
				frame := []byte(contentChunkSSE("m", "answer"))
				n, err := w.Write(frame)
				markContentWrite(w, true, n, len(frame), err)
				w.Write([]byte("data: [DONE]\n\n"))
				newRelayStamps(rp).done()
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
				write = srv.sealedTransport(write)
			}
			srv.observeRequestOutcome(write)(&outcomeFailAfterFirstWriter{}, req)
			r := awaitRequestOutcomes(t, st, 1)[0]
			if !r.ContentWriteCompleted || !r.ClientWriteError || r.EgressCompleted || r.Termination != "interrupted_response" {
				t.Fatalf("earlier content evidence lost: %+v", r)
			}
		})
	}
}

func TestRequestOutcomeQueueAndMissingTerminal(t *testing.T) {
	for _, kind := range []string{"queue_full", "queue_deadline", "terminal_grace"} {
		t.Run(kind, func(t *testing.T) {
			srv := newTestServerForDispatch(t)
			defer srv.Close()
			size := 1
			if kind == "queue_full" {
				size = 0
			}
			srv.registry.SetQueue(registry.NewRequestQueue(size, time.Second))
			srv.observeRequestOutcome(func(w http.ResponseWriter, r *http.Request) {
				rp := srv.newRequestProfile(r, "queued-model", "queued-model", false)
				if kind == "terminal_grace" {
					o := requestOutcomeFromContext(r.Context())
					rp = registry.NewRequestProfile(time.Now(), o.record.CoordRequestID, func(rp *registry.RequestProfile, ap *registry.AttemptProfile) { o.attemptFinalized(rp, ap) }, 5*time.Millisecond)
					o.mu.Lock()
					o.profile = rp
					o.mu.Unlock()
					ap := rp.NewAttempt("no-terminal", 0, "")
					ap.Mark(registry.StampWriteSubmitted)
					ap.Mark(registry.StampWriteDone)
					ap.CompleteHandler()
					return
				}
				d := queueDispatchState(srv, "queued-model", rp, r, 50*time.Millisecond)
				d.w = w
				d.run()
			})(httptest.NewRecorder(), httptest.NewRequest("POST", "/v1/completions", nil))
			r := awaitRequestOutcomes(t, srv.store, 1)[0]
			for _, a := range r.Attempts {
				if a.WriteCompleted && kind != "terminal_grace" {
					t.Fatalf("queue falsely dispatched %+v", r)
				}
			}
			if kind == "terminal_grace" {
				if r.Termination != "unknown" || r.EgressCompleted || r.Attempts[0].ProviderOutcome != "no_terminal" {
					t.Fatalf("grace fabricated result %+v", r)
				}
			} else {
				if r.Termination != "rejected" || r.RawReason != kind || r.NormalizedCode == "ext_first_content_timeout" {
					t.Fatalf("queue conflated with first-content timeout %+v", r)
				}
			}
		})
	}
}
