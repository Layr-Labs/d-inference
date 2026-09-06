package api

import (
	"errors"
	"net/http"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

type accountingErrorWriter struct {
	header http.Header
	body   strings.Builder
	mode   string
	failAt int
	writes int
}

func (w *accountingErrorWriter) Header() http.Header { return w.header }
func (w *accountingErrorWriter) WriteHeader(int)     {}
func (w *accountingErrorWriter) Flush()              {}
func (w *accountingErrorWriter) Write(p []byte) (int, error) {
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

func TestAccountingStreamErrorTerminalRequiresAcceptedWrite(t *testing.T) {
	for _, endpoint := range []string{"/v1/chat/completions", "/v1/responses", "/v1/completions", "/v1/messages"} {
		for _, mode := range []string{"full", "short", "error", "full with error"} {
			for _, priorContent := range []bool{false, true} {
				name := endpoint + "/" + mode
				if priorContent {
					name += "/after-content"
				}
				t.Run(name, func(t *testing.T) {
					tracker, pr := contentAccountingRequest(endpoint)
					pr.Accounting.Observe("committed", "", 0)
					pr.Accounting.Observe("provider_error", "", 500)
					if priorContent {
						pr.Accounting.Observe("content", "", 0)
						tracker.ContentWritten()
					}
					w := &accountingErrorWriter{header: make(http.Header), mode: mode}
					emitAccountingTestError(endpoint, w, pr)
					tracker.Finish(http.StatusOK, false, false)
					row := tracker.Snapshot()
					accepted := mode == "full"
					wantTerminal := "unknown"
					if accepted {
						wantTerminal = "error"
					}
					if row.ResponseTerminal != wantTerminal || row.ResponseEgressCompleted != accepted || row.ClientWriteError == accepted {
						t.Fatalf("terminal write evidence: %+v", row)
					}
					if row.Termination != "interrupted" || row.ProviderOutcome != "error" || row.ContentEgressObserved != priorContent || row.ResponseProgress == "completion_confirmed" {
						t.Fatalf("error envelope changed fulfillment/content evidence: %+v", row)
					}
					if accepted && (!strings.Contains(w.body.String(), `"message":"failed"`) || strings.Contains(w.body.String(), "[DONE]")) {
						t.Fatalf("error envelope changed: %s", w.body.String())
					}
				})
			}
		}
	}
}

func TestAccountingChatErrorRetainsEarlierMetadataWriteFailure(t *testing.T) {
	for _, mode := range []string{"short", "error", "full with error"} {
		t.Run(mode, func(t *testing.T) {
			tracker, pr := contentAccountingRequest("/v1/chat/completions")
			pr.MetadataDetails = true
			snapshotChatCompletionMetadata(pr, committedProviderInfo{ProviderID: "provider-id"})
			pr.Accounting.Observe("committed", "", 0)
			pr.Accounting.Observe("provider_error", "", 500)
			w := &accountingErrorWriter{header: make(http.Header), mode: mode, failAt: 1}
			emitAccountingTestError(pr.ConsumerEndpoint, w, pr)
			tracker.Finish(http.StatusOK, false, false)
			row := tracker.Snapshot()
			if w.writes != 2 || row.ResponseTerminal != "error" || !row.ClientWriteError || row.ResponseEgressCompleted || row.ContentEgressObserved || row.Termination != "interrupted" {
				t.Fatalf("accepted terminal erased earlier metadata write failure: writes=%d record=%+v", w.writes, row)
			}
		})
	}
}

func TestAccountingStreamErrorDoesNotFulfillCompletedProvider(t *testing.T) {
	for _, endpoint := range []string{"/v1/chat/completions", "/v1/responses", "/v1/completions", "/v1/messages"} {
		t.Run(endpoint, func(t *testing.T) {
			tracker, pr := contentAccountingRequest(endpoint)
			pr.Accounting.Observe("committed", "", 0)
			pr.Accounting.Observe("provider_complete", "", 0)
			w := &accountingErrorWriter{header: make(http.Header)}
			emitAccountingTestError(endpoint, w, pr)
			tracker.Finish(http.StatusOK, false, false)
			row := tracker.Snapshot()
			if row.ResponseTerminal != "error" || !row.ResponseEgressCompleted || row.Termination == "completed" || row.ResponseProgress == "completion_confirmed" {
				t.Fatalf("accepted error envelope counted as fulfilled response: %+v", row)
			}
		})
	}
}

func emitAccountingTestError(endpoint string, w *accountingErrorWriter, pr *registry.PendingRequest) {
	switch endpoint {
	case "/v1/chat/completions":
		(&Server{}).writeChatStreamTerminalError(w, w, pr, "provider_error", "failed")
	case "/v1/responses":
		newResponsesStreamEmitter(w, w, pr, "response-id", 1).emitError("provider_error", "failed")
	default:
		newGenericEndpointStreamEmitter(w, w, pr).emitError("provider_error", "failed")
	}
}
