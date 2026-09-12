package api

import (
	"bytes"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/google/uuid"
)

func TestRequestOutcomeFinalizesAfterRecoveryWrite(t *testing.T) {
	for _, endpoint := range outcomeEndpoints {
		for _, committed := range []bool{false, true} {
			for _, mode := range []string{"full", "short", "error", "full with error"} {
				t.Run(fmt.Sprintf("%s/committed=%t/%s", endpoint, committed, mode), func(t *testing.T) {
					srv, st := terminalOutcomeServer(t)
					srv.mux = http.NewServeMux()
					var coordID, publicID string
					srv.mux.HandleFunc("POST "+endpoint, func(w http.ResponseWriter, r *http.Request) {
						coordID, publicID = coordRequestIDFromContext(r.Context()), requestIDFromContext(r.Context())
						if committed {
							w.Header().Set("Content-Type", "application/json")
							w.WriteHeader(http.StatusOK)
							w.(http.Flusher).Flush()
						}
						panic("scripted panic")
					})
					w := &terminalOutcomeWriter{header: make(http.Header), mode: mode}
					req := httptest.NewRequest("POST", endpoint, strings.NewReader(`{"stream":true}`))
					req.Header.Set("X-Request-ID", "public-id")
					srv.Handler().ServeHTTP(w, req)
					row := awaitRequestOutcomes(t, st, 1)[0]
					wantStatus, wantTermination := http.StatusInternalServerError, "rejected"
					if committed {
						wantStatus, wantTermination = http.StatusOK, "interrupted_response"
					}
					if mode != "full" {
						wantTermination = "interrupted_response"
					}
					if row.HTTPStatus != wantStatus || row.Termination != wantTermination || row.RawStage != "handler" || row.RawReason != "handler_panic" {
						t.Fatalf("recovery result missing: %+v", row)
					}
					accepted := mode == "full"
					terminal := "unknown"
					if accepted {
						terminal = "error"
					}
					if row.ResponseTerminal != terminal || row.EgressCompleted != accepted || row.ClientWriteError == accepted || row.Stream != nil {
						t.Fatalf("recovery write result missing or request parsed prematurely: %+v", row)
					}
					if _, err := uuid.Parse(coordID); err != nil || row.CoordRequestID != coordID || publicID != "public-id" || w.Header().Get("X-Request-ID") != publicID {
						t.Fatalf("accounting/logging identity changed: %q / %q / %+v", coordID, publicID, row)
					}
					if accepted && !strings.Contains(w.body.String(), `"message":"internal server error"`) {
						t.Fatal("recovery envelope changed")
					}
				})
			}
		}
	}
}

func TestRequestOutcomeRecoveryPreservesAbortHandler(t *testing.T) {
	srv, st := terminalOutcomeServer(t)
	srv.mux = http.NewServeMux()
	srv.mux.HandleFunc("POST /v1/chat/completions", func(http.ResponseWriter, *http.Request) { panic(http.ErrAbortHandler) })
	w := httptest.NewRecorder()
	func() {
		defer func() {
			got, ok := recover().(error)
			if !ok || !errors.Is(got, http.ErrAbortHandler) {
				t.Fatalf("abort sentinel was swallowed: %v", got)
			}
		}()
		srv.Handler().ServeHTTP(w, httptest.NewRequest("POST", "/v1/chat/completions", nil))
		t.Fatal("abort handler returned normally")
	}()
	row := awaitRequestOutcomes(t, st, 1)[0]
	if row.HTTPStatus != 0 || row.ResponseTerminal != "unknown" || row.EgressCompleted || row.RawReason != "handler_aborted" || w.Body.Len() != 0 {
		t.Fatalf("abort fabricated recovery response: %+v", row)
	}
}

func TestRequestOutcomePopulationUsesMatchedEscapedRoute(t *testing.T) {
	srv, st := terminalOutcomeServer(t)
	srv.mux = http.NewServeMux()
	srv.mux.HandleFunc("POST /v1/messages", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 400, errorResponse("invalid_request_error", "scripted rejection"))
	})
	for _, path := range []string{"/v1%2Fmessages", "/v1/messages/missing"} {
		w := httptest.NewRecorder()
		srv.Handler().ServeHTTP(w, httptest.NewRequest("POST", path, nil))
		if w.Code != 404 || srv.requestOutcomes.received.Load() != 0 {
			t.Fatalf("unmatched path counted: %s status=%d", path, w.Code)
		}
	}
	for i, path := range []string{"/v1/messages", "/v1/%6dessages"} {
		w := httptest.NewRecorder()
		srv.Handler().ServeHTTP(w, httptest.NewRequest("POST", path, nil))
		if w.Code != 400 {
			t.Fatalf("matched path behavior changed: %s status=%d", path, w.Code)
		}
		rows := awaitRequestOutcomes(t, st, i+1)
		if rows[i].Endpoint != "/v1/messages" {
			t.Fatalf("matched path not normalized: %+v", rows[i])
		}
	}
}

func TestRequestOutcomeRecoveryAfterRejectedHeader(t *testing.T) {
	srv, st := terminalOutcomeServer(t)
	srv.mux = http.NewServeMux()
	srv.mux.HandleFunc("POST /v1/chat/completions", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(9999) })
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, httptest.NewRequest("POST", "/v1/chat/completions", nil))
	row := awaitRequestOutcomes(t, st, 1)[0]
	if w.Code != 500 || row.HTTPStatus != 500 || row.ResponseTerminal != "error" || row.Termination != "rejected" {
		t.Fatalf("rejected header replaced actual recovery result: status=%d %+v", w.Code, row)
	}
}

func TestRequestOutcomeRecoveryDoesNotInventSSETerminal(t *testing.T) {
	for _, sealed := range []bool{false, true} {
		for _, content := range []bool{false, true} {
			t.Run(fmt.Sprintf("sealed=%t/content=%t", sealed, content), func(t *testing.T) {
				srv, st := terminalOutcomeServer(t)
				srv.mux = http.NewServeMux()
				handler := func(w http.ResponseWriter, r *http.Request) {
					pr := terminalOutcomePending(srv, r, "completed")
					defer pr.Profile.CompleteHandler()
					defer pr.Profile.CompleteTerminal()
					w.Header().Set("Content-Type", "text/event-stream")
					w.WriteHeader(200)
					if content {
						frame := []byte(contentChunkSSE("m", "answer"))
						n, err := w.Write(frame)
						markContentWrite(w, true, n, len(frame), err)
					}
					w.(http.Flusher).Flush()
					panic("panic after content")
				}
				req := httptest.NewRequest("POST", "/v1/chat/completions", nil)
				if sealed {
					coord, err := e2e.DeriveCoordinatorKey(senderTestMnemonic)
					if err != nil {
						t.Fatal(err)
					}
					srv.SetCoordinatorKey(coord)
					encrypted, _, _ := sealRequest(t, []byte(`{"model":"m"}`), coord.PublicKey, coord.KID)
					req = httptest.NewRequest("POST", req.URL.Path, bytes.NewReader(encrypted))
					req.Header.Set("Content-Type", SealedContentType)
					handler = srv.sealedTransport(handler)
				}
				srv.mux.HandleFunc("POST /v1/chat/completions", handler)
				w := httptest.NewRecorder()
				srv.Handler().ServeHTTP(w, req)
				row := awaitRequestOutcomes(t, st, 1)[0]
				if w.Result().Header.Get("Content-Type") != "text/event-stream" || row.HTTPStatus != 200 || row.ResponseTerminal != "unknown" || row.EgressCompleted || row.ContentWriteCompleted != content || row.Termination != "interrupted_response" || row.RawReason != "handler_panic" {
					t.Fatalf("raw recovery JSON was counted as an SSE terminal: %+v", row)
				}
				// Recovery's existing bytes are intentionally preserved; they do not
				// contain SSE data framing and are not a terminal event on this stream.
				if !strings.Contains(w.Body.String(), `"message":"internal server error"`) {
					t.Fatal("recovery response changed")
				}
			})
		}
	}
}
