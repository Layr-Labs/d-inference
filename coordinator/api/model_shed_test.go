package api

import (
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"
)

func modelShedRequest() *http.Request {
	return httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`{}`))
}

func waitForRejectionCount(t *testing.T, srv *Server, want int) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if got := len(srv.store.RejectionRecordsSince(time.Time{})); got >= want {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("rejection records = %d, want >= %d", len(srv.store.RejectionRecordsSince(time.Time{})), want)
}

func TestModelShedRejectsRequestedAlias(t *testing.T) {
	srv, st := testServer(t)
	srv.SetRejectModels(map[string]bool{"gemma-4-26b": true})
	w := httptest.NewRecorder()

	if !srv.shedIfModelRejected(w, modelShedRequest(), map[string]any{"temperature": 0.2}, selfRoutePolicy{}, "gemma-4-26b", "gemma-4-26b-qat-4bit", true, 1200, 256, false, true) {
		t.Fatal("shedIfModelRejected = false, want true")
	}
	if w.Code != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429", w.Code)
	}
	if w.Header().Get("Retry-After") == "" {
		t.Fatal("Retry-After header missing")
	}
	if !strings.Contains(w.Body.String(), "rate_limit_exceeded") {
		t.Fatalf("body = %s, want rate_limit_exceeded", w.Body.String())
	}
	waitForRejectionCount(t, srv, 1)
	recs := st.RejectionRecordsSince(time.Time{})
	if got := recs[0].ReasonCode; got != "model_shed" {
		t.Fatalf("ReasonCode = %q, want model_shed", got)
	}
	if got := recs[0].RequestedModel; got != "gemma-4-26b" {
		t.Fatalf("RequestedModel = %q", got)
	}
	if got := recs[0].ResolvedModel; got != "gemma-4-26b-qat-4bit" {
		t.Fatalf("ResolvedModel = %q", got)
	}
	if !recs[0].Stream || !recs[0].HasTools || recs[0].RetryAfterMs <= 0 {
		t.Fatalf("record fields = %+v", recs[0])
	}
	// An operator-shed model stays out of rotation for at least 30 s (the
	// former 30 s fallback was dead code and a shed model answered 2 s, so the
	// aggregator re-fired the whole model every 2 s); jitter may add up to 50%.
	header, err := strconv.Atoi(w.Header().Get("Retry-After"))
	if err != nil || header < modelShedRetryAfterFloorSeconds || header > modelShedRetryAfterFloorSeconds*3/2 {
		t.Fatalf("model shed Retry-After = %q, want within [%d, %d]", w.Header().Get("Retry-After"), modelShedRetryAfterFloorSeconds, modelShedRetryAfterFloorSeconds*3/2)
	}
	if recs[0].RetryAfterMs != header*1000 {
		t.Fatalf("ledger retryAfterMs = %d, header = %d s", recs[0].RetryAfterMs, header)
	}
}

func TestModelShedRejectsResolvedConcreteModel(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetRejectModels(map[string]bool{"gemma-4-26b-qat-4bit": true})
	w := httptest.NewRecorder()

	if !srv.shedIfModelRejected(w, modelShedRequest(), nil, selfRoutePolicy{}, "gemma-4-26b", "gemma-4-26b-qat-4bit", false, 100, 64, false, false) {
		t.Fatal("shedIfModelRejected = false, want true")
	}
	if w.Code != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429", w.Code)
	}
}

func TestModelShedDoesNotRejectOtherModels(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetRejectModels(map[string]bool{"gemma-4-26b": true})
	w := httptest.NewRecorder()

	if srv.shedIfModelRejected(w, modelShedRequest(), nil, selfRoutePolicy{}, "gpt-oss-20b", "gpt-oss-20b", false, 100, 64, false, false) {
		t.Fatal("shedIfModelRejected = true for non-shed model")
	}
	if w.Code == http.StatusTooManyRequests {
		t.Fatal("non-shed model was written as a 429")
	}
}

func TestModelShedPolicySelfRouteBypassesPreferOwnerSheds(t *testing.T) {
	srv, st := testServer(t)
	srv.SetRejectModels(map[string]bool{"gemma-4-26b": true})
	self := httptest.NewRecorder()
	prefer := httptest.NewRecorder()

	if srv.shedIfModelRejected(self, modelShedRequest(), nil, selfRoutePolicy{enabled: true}, "gemma-4-26b", "gemma-4-26b-qat-4bit", false, 100, 64, false, false) {
		t.Fatal("exclusive self-route should bypass model shed")
	}
	if !srv.shedIfModelRejected(prefer, modelShedRequest(), nil, selfRoutePolicy{prefer: true}, "gemma-4-26b", "gemma-4-26b-qat-4bit", false, 100, 64, false, false) {
		t.Fatal("prefer-owner should be model-shed because it can fall back to public fleet")
	}
	waitForRejectionCount(t, srv, 1)
	rec := st.RejectionRecordsSince(time.Time{})[0]
	if !rec.PreferOwner || rec.SelfRouteOnly {
		t.Fatalf("policy telemetry = %+v", rec)
	}
}
