package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestUptimeCountsAddDenominatorAndPct(t *testing.T) {
	var c uptimeCounts
	for _, cl := range []string{
		orClassSuccess, orClassSuccess, orClassSuccess,
		orClassProvider5xx, orClassMidStream, orClassTimeout,
		orClassRateLimited, orClassCancelled, orClassClientError,
	} {
		c.add(cl)
	}
	if c.Success != 3 || c.Provider5xx != 1 || c.MidStream != 1 || c.Timeout != 1 ||
		c.RateLimited != 1 || c.Cancelled != 1 || c.ClientError != 1 {
		t.Fatalf("unexpected counts: %+v", c)
	}
	// denominator excludes rate_limited / cancelled / client_error.
	if got := c.denominator(); got != 6 {
		t.Fatalf("denominator = %d, want 6", got)
	}
	p := c.uptimePct()
	if p == nil {
		t.Fatal("uptimePct = nil, want a value")
	}
	if *p < 49.99 || *p > 50.01 { // 3/6
		t.Fatalf("uptimePct = %v, want 50", *p)
	}
}

func TestUptimePctNilWhenNoScoredRequests(t *testing.T) {
	var c uptimeCounts
	c.add(orClassRateLimited)
	c.add(orClassCancelled)
	c.add(orClassClientError)
	if c.denominator() != 0 {
		t.Fatalf("denominator = %d, want 0", c.denominator())
	}
	if c.uptimePct() != nil {
		t.Fatal("uptimePct != nil, want nil when no scored requests")
	}
}

func TestDedupeRouteOutcomes(t *testing.T) {
	in := []store.InferenceRouteRecord{
		{RequestID: "a", Attempt: 0, FinalStatus: "error", ErrorCode: 503},
		{RequestID: "a", Attempt: 1, FinalStatus: "success"}, // failover success outranks the failed attempt
		{RequestID: "b", Attempt: 0, FinalStatus: ""},        // non-terminal, ignored
		{RequestID: "c", Attempt: 0, FinalStatus: "timeout", ErrorCode: 504},
		{RequestID: "c", Attempt: 1, FinalStatus: "error", ErrorCode: 500}, // timeout outranks error
	}
	got := map[string]string{}
	for _, rec := range dedupeRouteOutcomes(in) {
		got[rec.RequestID] = rec.FinalStatus
	}
	if len(got) != 2 {
		t.Fatalf("got %d deduped requests, want 2 (b has no terminal): %+v", len(got), got)
	}
	if got["a"] != "success" {
		t.Fatalf("request a = %q, want success", got["a"])
	}
	if got["c"] != "timeout" {
		t.Fatalf("request c = %q, want timeout", got["c"])
	}
}

func TestHandleAdminUptimeEndToEnd(t *testing.T) {
	srv, st := testServer(t)
	srv.adminKey = "admintest"

	seedRoute := func(reqID string, attempt int, model, finalStatus, errClass string, code int) {
		if err := st.RecordInferenceRoute(&store.InferenceRouteRecord{
			RequestID: reqID, Attempt: attempt, Model: model, CreatedAt: time.Now(),
		}); err != nil {
			t.Fatalf("RecordInferenceRoute: %v", err)
		}
		if err := st.UpdateInferenceRouteOutcome(reqID, attempt, &store.InferenceRouteOutcome{
			FinalStatus: finalStatus, ErrorClass: errClass, ErrorCode: code,
		}); err != nil {
			t.Fatalf("UpdateInferenceRouteOutcome: %v", err)
		}
	}

	// m1: r1 success; r2 failover (attempt0 error → attempt1 success) = 1 success; r3 hard 5xx.
	seedRoute("r1", 0, "m1", "success", "", 0)
	seedRoute("r2", 0, "m1", "error", "provider_error", 503)
	seedRoute("r2", 1, "m1", "success", "", 0)
	seedRoute("r3", 0, "m1", "error", "provider_error", 500)

	// A pre-dispatch 429 (excluded from the formula) and a dispatch-stage rejection
	// (must be skipped: r3 already counted via its route record).
	if err := st.RecordRejection(&store.RejectionRecord{
		Stage: "preflight_capacity", ReasonCode: "prompt_too_long", HTTPStatus: 429,
		ResolvedModel: "m1", CreatedAt: time.Now(),
	}); err != nil {
		t.Fatalf("RecordRejection: %v", err)
	}
	if err := st.RecordRejection(&store.RejectionRecord{
		Stage: "dispatch", ReasonCode: "dispatch_exhausted", HTTPStatus: 503,
		ResolvedModel: "m1", CreatedAt: time.Now(),
	}); err != nil {
		t.Fatalf("RecordRejection: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/v1/admin/uptime", nil)
	req.Header.Set("Authorization", "Bearer admintest")
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	var resp uptimeResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode: %v; body=%s", err, rec.Body.String())
	}

	// Overall: 2 success (r1, r2), 1 provider_5xx (r3), 1 rate_limited (excluded),
	// dispatch-stage rejection skipped. denominator = 3, uptime = 2/3.
	if resp.Overall.Counts.Success != 2 {
		t.Fatalf("overall success = %d, want 2 (resp=%+v)", resp.Overall.Counts.Success, resp.Overall)
	}
	if resp.Overall.Counts.Provider5xx != 1 {
		t.Fatalf("overall provider_5xx = %d, want 1", resp.Overall.Counts.Provider5xx)
	}
	if resp.Overall.Counts.RateLimited != 1 {
		t.Fatalf("overall rate_limited = %d, want 1 (dispatch-stage rejection must be skipped)", resp.Overall.Counts.RateLimited)
	}
	if resp.Overall.Denominator != 3 {
		t.Fatalf("overall denominator = %d, want 3", resp.Overall.Denominator)
	}
	if resp.Overall.UptimePct == nil || *resp.Overall.UptimePct < 66.6 || *resp.Overall.UptimePct > 66.7 {
		t.Fatalf("overall uptime_pct = %v, want ~66.67", resp.Overall.UptimePct)
	}
}

func TestHandleAdminUptimeRequiresAdmin(t *testing.T) {
	srv, _ := testServer(t)
	srv.adminKey = "admintest"
	req := httptest.NewRequest(http.MethodGet, "/v1/admin/uptime", nil) // no auth
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code == http.StatusOK {
		t.Fatalf("status = 200 without admin key, want non-200")
	}
}
