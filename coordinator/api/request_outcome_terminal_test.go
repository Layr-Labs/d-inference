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
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type terminalOutcomeWriter struct {
	header         http.Header
	body           strings.Builder
	mode           string
	failAt, writes int
}

func (w *terminalOutcomeWriter) Header() http.Header { return w.header }
func (w *terminalOutcomeWriter) WriteHeader(int)     {}
func (w *terminalOutcomeWriter) Flush()              {}
func (w *terminalOutcomeWriter) Write(p []byte) (int, error) {
	w.writes++
	if w.failAt > 0 && w.writes != w.failAt {
		return w.body.Write(p)
	}
	switch w.mode {
	case "short":
		return w.body.Write(p[:len(p)-1])
	case "error":
		return 0, errors.New("consumer disconnected")
	case "full with error":
		n, _ := w.body.Write(p)
		return n, errors.New("consumer disconnected")
	default:
		return w.body.Write(p)
	}
}

func terminalOutcomeServer(t *testing.T) (*Server, *store.MemoryStore) {
	t.Helper()
	st := store.NewMemory(store.Config{})
	srv := &Server{store: st, logger: quietLogger()}
	srv.requestOutcomes = newRequestOutcomeSink(srv, 16)
	t.Cleanup(srv.requestOutcomes.close)
	return srv, st
}

func terminalOutcomePending(srv *Server, r *http.Request, provider string) *registry.PendingRequest {
	rp := srv.newRequestProfile(r, "m", "m", true)
	ap := rp.NewAttempt("terminal-attempt", 0, "")
	ap.Winning.Store(true)
	status := "success"
	if provider == "error" {
		status = "error"
	}
	ap.SetOutcome(status, "", "", provider, "")
	return &registry.PendingRequest{RequestID: ap.RequestID, ConsumerEndpoint: r.URL.Path, Model: "m", Profile: ap}
}

func emitOutcomeTerminalError(endpoint string, w http.ResponseWriter, pr *registry.PendingRequest) {
	flusher := w.(http.Flusher)
	switch endpoint {
	case "/v1/chat/completions":
		(&Server{}).writeChatStreamTerminalError(w, flusher, pr, "provider_error", "failed")
	case "/v1/responses":
		newResponsesStreamEmitter(w, flusher, pr, "response-id", 1).emitError("provider_error", "failed")
	default:
		emitter, _ := newEndpointStreamEmitter(w, flusher, pr)
		emitter.emitError("provider_error", "failed")
	}
}

func TestRequestOutcomeStreamTerminalRequiresAcceptedWrite(t *testing.T) {
	for _, endpoint := range outcomeEndpoints {
		for _, mode := range []string{"full", "short", "error", "full with error"} {
			for _, sealed := range []bool{false, true} {
				for _, provider := range []string{"error", "completed"} {
					t.Run(fmt.Sprintf("%s/%s/sealed=%t/provider=%s", endpoint, mode, sealed, provider), func(t *testing.T) {
						srv, st := terminalOutcomeServer(t)
						handler := func(w http.ResponseWriter, r *http.Request) {
							pr := terminalOutcomePending(srv, r, provider)
							defer pr.Profile.CompleteHandler()
							defer pr.Profile.CompleteTerminal()
							w.Header().Set("Content-Type", "text/event-stream")
							emitOutcomeTerminalError(endpoint, w, pr)
						}
						req := httptest.NewRequest("POST", endpoint, nil)
						if sealed {
							coord, err := e2e.DeriveCoordinatorKey(senderTestMnemonic)
							if err != nil {
								t.Fatal(err)
							}
							srv.SetCoordinatorKey(coord)
							encrypted, _, _ := sealRequest(t, []byte(`{"model":"m"}`), coord.PublicKey, coord.KID)
							req = httptest.NewRequest("POST", endpoint, bytes.NewReader(encrypted))
							req.Header.Set("Content-Type", SealedContentType)
							handler = srv.sealedTransport(handler)
						}
						w := &terminalOutcomeWriter{header: make(http.Header), mode: mode}
						srv.observeRequestOutcome(handler)(w, req)
						row := awaitRequestOutcomes(t, st, 1)[0]
						accepted := mode == "full"
						wantTerminal := "unknown"
						if accepted {
							wantTerminal = "error"
						}
						if row.ResponseTerminal != wantTerminal || row.EgressCompleted != accepted || row.ClientWriteError == accepted {
							t.Fatalf("terminal write evidence: %+v", row)
						}
						if row.Termination != "interrupted_response" || row.ProviderOutcome != provider || row.ContentWriteCompleted {
							t.Fatalf("error counted as completion/content: %+v", row)
						}
						if accepted && !sealed && (!strings.Contains(w.body.String(), `"message":"failed"`) || strings.Contains(w.body.String(), "[DONE]")) {
							t.Fatalf("error envelope changed: %s", w.body.String())
						}
					})
				}
			}
		}
	}
}

func TestRequestOutcomeErrorTerminalPreservesEarlierWriteFailure(t *testing.T) {
	for _, mode := range []string{"short", "error", "full with error"} {
		t.Run(mode, func(t *testing.T) {
			srv, st := terminalOutcomeServer(t)
			w := &terminalOutcomeWriter{header: make(http.Header), mode: mode, failAt: 1}
			srv.observeRequestOutcome(func(w http.ResponseWriter, r *http.Request) {
				pr := terminalOutcomePending(srv, r, "error")
				defer pr.Profile.CompleteHandler()
				defer pr.Profile.CompleteTerminal()
				pr.MetadataDetails = true
				snapshotChatCompletionMetadata(pr, committedProviderInfo{ProviderID: "provider-id"})
				emitOutcomeTerminalError(r.URL.Path, w, pr)
			})(w, httptest.NewRequest("POST", "/v1/chat/completions", nil))
			row := awaitRequestOutcomes(t, st, 1)[0]
			if w.writes != 2 || row.ResponseTerminal != "error" || !row.ClientWriteError || row.EgressCompleted || row.ContentWriteCompleted || row.Termination != "interrupted_response" {
				t.Fatalf("accepted error erased preceding failed metadata write: %+v", row)
			}
		})
	}
}

func TestRequestOutcomeNativeResponseTerminalConflicts(t *testing.T) {
	for _, order := range [][]string{{"completed", "failed"}, {"failed", "completed"}, {"completed", "incomplete"}, {"completed", "completed"}} {
		for _, grouping := range []string{"separate_flushes", "coalesced_frames", "single_frame_group"} {
			for _, preamble := range []bool{false, true} {
				t.Run(fmt.Sprintf("%s/%s/preamble=%t", strings.Join(order, "_"), grouping, preamble), func(t *testing.T) {
					srv, st := terminalOutcomeServer(t)
					w := httptest.NewRecorder()
					srv.observeRequestOutcome(func(w http.ResponseWriter, r *http.Request) {
						pr := terminalOutcomePending(srv, r, "completed")
						defer pr.Profile.CompleteHandler()
						defer pr.Profile.CompleteTerminal()
						relay := newChatStreamRelay(pr, w, w.(http.Flusher), newRelayStamps(pr.Profile.Parent()))
						if preamble {
							relay.handleChunk(`data: {"type":"response.created"}`)
						}
						var frames []string
						for _, status := range order {
							frames = append(frames, fmt.Sprintf("event: response.%s\ndata: {\"type\":\"response.%s\",\"response\":{\"status\":\"%s\"}}", status, status, status))
						}
						if grouping == "single_frame_group" {
							relay.handleChunk(strings.Join(frames, "\n\n"))
						} else {
							for _, frame := range frames {
								relay.handleChunk(frame)
								if grouping == "separate_flushes" {
									relay.flush()
								}
							}
						}
						relay.flush()
					})(w, httptest.NewRequest("POST", "/v1/chat/completions", nil))
					row := awaitRequestOutcomes(t, st, 1)[0]
					conflict := order[0] != order[1]
					first := order[0]
					if first == "failed" {
						first = "error"
					}
					if row.EvidenceConflict != conflict || row.ResponseTerminal != first || !row.EgressCompleted {
						t.Fatalf("terminal evidence changed with grouping: %+v", row)
					}
					if conflict && row.Termination != "unknown" || !conflict && row.Termination != "completed" {
						t.Fatalf("incorrect terminal classification: %+v", row)
					}
					for _, status := range order {
						if !strings.Contains(w.Body.String(), `"type":"response.`+status+`"`) {
							t.Fatal("terminal wire bytes changed")
						}
					}
				})
			}
		}
	}
}

func TestRequestOutcomeUnknownBodiesDoNotConfirmCompletion(t *testing.T) {
	for _, body := range []string{
		`{"choices":null}`, `{"choices":42}`, `{"choices":{}}`, `{"choices":"text"}`,
		`{"choices":[]}`, `{"choices":[null]}`, `{"choices":[{}]}`,
		`{"choices":[{"text":null}]}`, `{"choices":[{"message":null}]}`,
		`{"choices":[{"message":42}]}`, `{"object":"response","status":"future_status"}`,
		`{"object":"response"}`, `{}`, `not JSON`,
	} {
		t.Run(body, func(t *testing.T) {
			srv, st := terminalOutcomeServer(t)
			srv.observeRequestOutcome(func(w http.ResponseWriter, r *http.Request) {
				pr := terminalOutcomePending(srv, r, "completed")
				defer pr.Profile.CompleteHandler()
				defer pr.Profile.CompleteTerminal()
				w.Header().Set("Content-Type", "application/json")
				w.Write([]byte(body))
			})(httptest.NewRecorder(), httptest.NewRequest("POST", "/v1/chat/completions", nil))
			row := awaitRequestOutcomes(t, st, 1)[0]
			if row.ResponseTerminal != "unknown" || row.EgressCompleted || row.Termination != "unknown" {
				t.Fatalf("unknown body confirmed completion: %+v", row)
			}
		})
	}
}

func TestRequestOutcomeTerminalAndContentSurviveLaterFailedWrite(t *testing.T) {
	for _, mode := range []string{"short", "error", "full with error"} {
		t.Run(mode, func(t *testing.T) {
			srv, st := terminalOutcomeServer(t)
			w := &terminalOutcomeWriter{header: make(http.Header), mode: mode, failAt: 2}
			srv.observeRequestOutcome(func(w http.ResponseWriter, r *http.Request) {
				pr := terminalOutcomePending(srv, r, "completed")
				defer pr.Profile.CompleteHandler()
				defer pr.Profile.CompleteTerminal()
				relay := newChatStreamRelay(pr, w, w.(http.Flusher), newRelayStamps(pr.Profile.Parent()))
				relay.handleChunk("data: {\"type\":\"response.output_text.delta\",\"delta\":\"answer\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}")
				relay.flush()
				emitOutcomeTerminalError(r.URL.Path, w, pr)
			})(w, httptest.NewRequest("POST", "/v1/chat/completions", nil))
			row := awaitRequestOutcomes(t, st, 1)[0]
			if row.ResponseTerminal != "completed" || !row.ContentWriteCompleted || !row.ClientWriteError || row.EgressCompleted || row.EvidenceConflict || row.Termination != "interrupted_response" {
				t.Fatalf("failed later terminal changed earlier accepted evidence: %+v", row)
			}
		})
	}
}

func TestRequestOutcomeSSETerminalsParseCompleteEventData(t *testing.T) {
	for _, tc := range []struct{ name, frame, want string }{
		{"multiline", "event: response.completed\ndata: {\"type\":\"response.completed\",\ndata: \"response\":{\"status\":\"completed\"}}", "completed"},
		{"invalid suffix", "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\ndata: garbage", "unknown"},
		{"empty data field", "data: {\"type\":\"response.completed\",\ndata\ndata: \"response\":{\"status\":\"completed\"}}", "completed"},
		{"crlf and bom", "\uFEFFdata: {\"type\":\"response.completed\",\r\ndata: \"response\":{\"status\":\"completed\"}}", "completed"},
	} {
		for _, sealed := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/sealed=%t", tc.name, sealed), func(t *testing.T) {
				srv, st := terminalOutcomeServer(t)
				handler := func(w http.ResponseWriter, r *http.Request) {
					pr := terminalOutcomePending(srv, r, "completed")
					defer pr.Profile.CompleteHandler()
					defer pr.Profile.CompleteTerminal()
					w.Header().Set("Content-Type", "text/event-stream")
					relay := newChatStreamRelay(pr, w, w.(http.Flusher), newRelayStamps(pr.Profile.Parent()))
					relay.writeFrame(tc.frame)
					relay.flush()
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
				srv.observeRequestOutcome(handler)(httptest.NewRecorder(), req)
				row := awaitRequestOutcomes(t, st, 1)[0]
				if row.ResponseTerminal != tc.want || row.EgressCompleted != (tc.want == "completed") {
					t.Fatalf("SSE event parsed differently from client: %+v", row)
				}
			})
		}
	}
}

func TestRequestOutcomeFullBodyTerminalConflict(t *testing.T) {
	srv, st := terminalOutcomeServer(t)
	srv.observeRequestOutcome(func(w http.ResponseWriter, r *http.Request) {
		pr := terminalOutcomePending(srv, r, "completed")
		defer pr.Profile.CompleteHandler()
		defer pr.Profile.CompleteTerminal()
		writeNonStreamBody(w, pr.Profile.Parent(), map[string]any{"object": "response", "status": "completed", "error": map[string]any{"code": "server_error"}})
	})(httptest.NewRecorder(), httptest.NewRequest("POST", "/v1/responses", nil))
	row := awaitRequestOutcomes(t, st, 1)[0]
	if !row.EvidenceConflict || row.ResponseTerminal != "error" || !row.EgressCompleted || row.Termination != "unknown" {
		t.Fatalf("full body contradiction dropped: %+v", row)
	}
}

func TestRequestOutcomeNativeFailureWithoutSnapshotIsNotFulfilled(t *testing.T) {
	for _, status := range []string{"failed", "incomplete"} {
		t.Run(status, func(t *testing.T) {
			srv, st := terminalOutcomeServer(t)
			srv.observeRequestOutcome(func(w http.ResponseWriter, r *http.Request) {
				pr := terminalOutcomePending(srv, r, "completed")
				defer pr.Profile.CompleteHandler()
				defer pr.Profile.CompleteTerminal()
				relay := newChatStreamRelay(pr, w, w.(http.Flusher), newRelayStamps(pr.Profile.Parent()))
				// A legacy failure event must still conflict with a later DONE,
				// including when both fit in one consumer write.
				relay.writeFrame(fmt.Sprintf(`data: {"type":"response.%s"}`, status))
				relay.writeFrame("data: [DONE]")
				relay.flush()
			})(httptest.NewRecorder(), httptest.NewRequest("POST", "/v1/chat/completions", nil))
			row := awaitRequestOutcomes(t, st, 1)[0]
			first := status
			if first == "failed" {
				first = "error"
			}
			if row.ResponseTerminal != first || !row.EvidenceConflict || !row.EgressCompleted || row.Termination != "unknown" {
				t.Fatalf("failure without snapshot was fulfilled: %+v", row)
			}
		})
	}
}
