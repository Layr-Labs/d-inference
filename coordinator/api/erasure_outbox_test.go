package api

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/datadog"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// fakeStripe answers Stripe paths from a per-test table of handlers and
// records each request.
type fakeStripe struct {
	mu       sync.Mutex
	routes   map[string]func(w http.ResponseWriter, r *http.Request, body string)
	requests []string
	bodies   map[string]string
	headers  map[string]http.Header
}

func newFakeStripe(t *testing.T) (*fakeStripe, *httptest.Server) {
	f := &fakeStripe{routes: map[string]func(http.ResponseWriter, *http.Request, string){}, bodies: map[string]string{}, headers: map[string]http.Header{}}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		key := r.Method + " " + r.URL.Path
		f.mu.Lock()
		f.requests = append(f.requests, key)
		f.bodies[key] = string(b)
		f.headers[key] = r.Header.Clone()
		h := f.routes[key]
		f.mu.Unlock()
		if h == nil {
			w.WriteHeader(http.StatusNotImplemented)
			return
		}
		h(w, r, string(b))
	}))
	t.Cleanup(srv.Close)
	return f, srv
}

func (f *fakeStripe) on(method, path string, status int, body string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.routes[method+" "+path] = func(w http.ResponseWriter, _ *http.Request, _ string) {
		w.WriteHeader(status)
		_, _ = io.WriteString(w, body)
	}
}

// outboxTestServer wires real Stripe clients to the fake.
func outboxTestServer(t *testing.T, mock bool) (*Server, *store.MemoryStore, *fakeStripe) {
	t.Helper()
	f, fake := newFakeStripe(t)
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)
	t.Cleanup(srv.Close)
	cfg := billing.Config{MockMode: mock}
	if !mock {
		cfg.StripeSecretKey, cfg.StripeConnectSecretKey = "sk_test_checkout", "sk_test_connect"
		cfg.StripeGlobalPayoutsSecretKey, cfg.StripeGlobalPayoutsFinancialAccount = "sk_test_global", "fa_test"
	}
	srv.SetBilling(billing.NewService(st, srv.ledger, logger, cfg))
	prev := billing.SetStripeAPIBaseForTest(fake.URL)
	t.Cleanup(func() { billing.SetStripeAPIBaseForTest(prev) })
	if gp := srv.billing.GlobalPayouts(); gp != nil {
		gp.BaseURL = fake.URL
	}
	return srv, st, f
}

func outboxRow(target store.ErasureTarget, externalID, jobID string) store.ErasureOutboxWork {
	return store.ErasureOutboxWork{ErasureOutboxItem: store.ErasureOutboxItem{
		ID: "ob-1", RequestID: "req-1", Target: target, State: store.ErasureOutboxPending,
		ExternalID: externalID, StripeJobID: jobID,
	}, AccountID: "acct-1", ErasedAt: time.Unix(1_800_000_000, 0)}
}

func TestErasureOutboxStripeAccount(t *testing.T) {
	srv, _, f := outboxTestServer(t, false)
	row := outboxRow(store.ErasureTargetStripeAccount, "acct_1Abc", "")
	for _, tc := range []struct {
		name   string
		status int
		body   string
		want   outboxKind
	}{
		{"success", 200, `{"id":"acct_1Abc","deleted":true}`, outboxDone},
		{"not found", 404, `{"error":{"type":"invalid_request_error","code":"resource_missing","message":"No such account: 'acct_1Abc'"}}`, outboxDone},
		{"balance not zero", 400, `{"error":{"type":"invalid_request_error","message":"This account cannot be deleted because it has a non-zero balance."}}`, outboxManual},
		{"server error", 500, `{"error":{"type":"api_error","message":"try again"}}`, outboxRetry},
		{"rate limited", 429, `{"error":{"type":"rate_limit_error","message":"slow down"}}`, outboxRetry},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f.on(http.MethodDelete, "/v1/accounts/acct_1Abc", tc.status, tc.body)
			if got := srv.deliverErasureOutbox(context.Background(), row); got.kind != tc.want {
				t.Fatalf("outcome = %+v, want kind %d", got, tc.want)
			}
		})
	}
	if got := f.headers["DELETE /v1/accounts/acct_1Abc"].Get("Authorization"); got != "Bearer sk_test_connect" {
		t.Fatalf("Connect key not used: %q", got)
	}
}

func TestErasureOutboxGlobalRecipient(t *testing.T) {
	srv, _, f := outboxTestServer(t, false)
	row := outboxRow(store.ErasureTargetGlobalRecipient, "acct_recipient", "")
	path := "/v2/core/accounts/acct_recipient/close"
	for _, tc := range []struct {
		name   string
		status int
		body   string
		want   outboxKind
	}{
		{"success", 200, `{"id":"acct_recipient","applied_configurations":[]}`, outboxDone},
		{"not found", 404, `{"error":{"code":"not_found"}}`, outboxDone},
		{"balance", 400, `{"error":{"code":"cannot_delete_account_with_balance"}}`, outboxManual},
		{"transient", 503, `{"error":{"code":"unavailable"}}`, outboxRetry},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f.on(http.MethodPost, path, tc.status, tc.body)
			if got := srv.deliverErasureOutbox(context.Background(), row); got.kind != tc.want {
				t.Fatalf("outcome = %+v, want kind %d", got, tc.want)
			}
		})
	}
	var body struct {
		AppliedConfigurations []string `json:"applied_configurations"`
	}
	if err := json.Unmarshal([]byte(f.bodies["POST "+path]), &body); err != nil || len(body.AppliedConfigurations) != 1 || body.AppliedConfigurations[0] != "recipient" {
		t.Fatalf("close body = %q", f.bodies["POST "+path])
	}
}

func TestErasureOutboxRedactionJobLifecycle(t *testing.T) {
	srv, _, f := outboxTestServer(t, false)
	ctx := context.Background()
	row := outboxRow(store.ErasureTargetCheckoutSessions, "cs_test_1,cs_test_2", "")

	f.on(http.MethodPost, "/v1/privacy/redaction_jobs", 200, `{"id":"prj_1","status":"validating"}`)
	out := srv.deliverErasureOutbox(ctx, row)
	if out.kind != outboxProgress || out.jobID != "prj_1" {
		t.Fatalf("create = %+v", out)
	}
	form := f.bodies["POST /v1/privacy/redaction_jobs"]
	if !strings.Contains(form, "validation_behavior=fix") || strings.Count(form, "objects%5Bcheckout_sessions%5D%5B%5D=cs_test_") != 2 {
		t.Fatalf("create form = %q", form)
	}
	if got := f.headers["POST /v1/privacy/redaction_jobs"].Get("Idempotency-Key"); got != "erasure-redaction-ob-1" {
		t.Fatalf("idempotency key = %q", got)
	}

	row.StripeJobID = "prj_1"
	f.on(http.MethodGet, "/v1/privacy/redaction_jobs/prj_1", 200, `{"id":"prj_1","status":"validating"}`)
	if out := srv.deliverErasureOutbox(ctx, row); out.kind != outboxProgress || out.jobID != "prj_1" {
		t.Fatalf("validating = %+v", out)
	}
	f.on(http.MethodGet, "/v1/privacy/redaction_jobs/prj_1", 200, `{"id":"prj_1","status":"ready"}`)
	f.on(http.MethodPost, "/v1/privacy/redaction_jobs/prj_1/run", 200, `{"id":"prj_1","status":"redacting"}`)
	if out := srv.deliverErasureOutbox(ctx, row); out.kind != outboxProgress || out.jobID != "prj_1" {
		t.Fatalf("ready = %+v", out)
	}
	if !slices.Contains(f.requests, "POST /v1/privacy/redaction_jobs/prj_1/run") {
		t.Fatal("ready job was not run")
	}
	f.on(http.MethodGet, "/v1/privacy/redaction_jobs/prj_1", 200, `{"id":"prj_1","status":"succeeded"}`)
	if out := srv.deliverErasureOutbox(ctx, row); out.kind != outboxDone {
		t.Fatalf("succeeded = %+v", out)
	}
}

func TestErasureOutboxRedactionOutcomes(t *testing.T) {
	srv, _, f := outboxTestServer(t, false)
	ctx := context.Background()
	fresh := outboxRow(store.ErasureTargetCheckoutSessions, "cs_test_1", "")
	running := outboxRow(store.ErasureTargetCheckoutSessions, "cs_test_1", "prj_2")

	t.Run("feature not enabled", func(t *testing.T) {
		f.on(http.MethodPost, "/v1/privacy/redaction_jobs", 400, `{"error":{"type":"invalid_request_error","message":"Redaction jobs are not enabled for this account."}}`)
		out := srv.deliverErasureOutbox(ctx, fresh)
		if out.kind != outboxManual || !strings.Contains(out.err, "not enabled") {
			t.Fatalf("outcome = %+v", out)
		}
	})
	t.Run("session not found", func(t *testing.T) {
		f.on(http.MethodPost, "/v1/privacy/redaction_jobs", 404, `{"error":{"code":"resource_missing","message":"No such checkout session"}}`)
		if out := srv.deliverErasureOutbox(ctx, fresh); out.kind != outboxDone {
			t.Fatalf("outcome = %+v", out)
		}
	})
	t.Run("transient", func(t *testing.T) {
		f.on(http.MethodPost, "/v1/privacy/redaction_jobs", 502, `{"error":{"message":"bad gateway"}}`)
		if out := srv.deliverErasureOutbox(ctx, fresh); out.kind != outboxRetry {
			t.Fatalf("outcome = %+v", out)
		}
	})
	t.Run("too recent reschedules", func(t *testing.T) {
		f.on(http.MethodGet, "/v1/privacy/redaction_jobs/prj_2", 200, `{"id":"prj_2","status":"failed"}`)
		f.on(http.MethodGet, "/v1/privacy/redaction_jobs/prj_2/validation_errors", 200,
			`{"object":"list","data":[{"code":"invalid_state","message":"This charge can be redacted 90 days after it was created."}]}`)
		out := srv.deliverErasureOutbox(ctx, running)
		if out.kind != outboxReschedule || out.jobID != "" || out.next.Before(time.Now().Add(6*24*time.Hour)) {
			t.Fatalf("outcome = %+v", out)
		}
		r := outboxResult(running, out, time.Now())
		if r.State != store.ErasureOutboxPending || r.Attempts != 0 || r.StripeJobID != "" {
			t.Fatalf("stored result = %+v; a reschedule keeps the row pending and counts no attempt", r)
		}
	})
	t.Run("other validation error needs an operator", func(t *testing.T) {
		f.on(http.MethodGet, "/v1/privacy/redaction_jobs/prj_2/validation_errors", 200,
			`{"object":"list","data":[{"code":"locked_by_other_job","message":"The object is used in another redaction job."}]}`)
		if out := srv.deliverErasureOutbox(ctx, running); out.kind != outboxManual || !strings.Contains(out.err, "locked_by_other_job") {
			t.Fatalf("outcome = %+v", out)
		}
	})
	t.Run("canceled job", func(t *testing.T) {
		f.on(http.MethodGet, "/v1/privacy/redaction_jobs/prj_2", 200, `{"id":"prj_2","status":"canceled"}`)
		if out := srv.deliverErasureOutbox(ctx, running); out.kind != outboxManual {
			t.Fatalf("outcome = %+v", out)
		}
	})
}

type fakeErasureLog struct {
	enabled bool
	err     error
	entries []datadog.TelemetryLogEntry
	tags    [][]string
}

func (f *fakeErasureLog) LogsEnabled() bool { return f.enabled }
func (f *fakeErasureLog) SendLog(_ context.Context, e datadog.TelemetryLogEntry, tags ...string) error {
	f.entries, f.tags = append(f.entries, e), append(f.tags, tags)
	return f.err
}

func TestErasureOutboxErasureLog(t *testing.T) {
	srv, _, _ := outboxTestServer(t, false)
	ctx := context.Background()
	row := outboxRow(store.ErasureTargetErasureLog, "", "")

	sink := &fakeErasureLog{enabled: true}
	srv.erasureLog = sink
	if out := srv.deliverErasureOutbox(ctx, row); out.kind != outboxDone {
		t.Fatalf("outcome = %+v", out)
	}
	e := sink.entries[0]
	if e.Kind != "erasure_log" || e.Fields["request_id"] != "req-1" || e.Fields["account_id"] != "acct-1" || e.Fields["erased_at"] == "" || len(e.Fields) != 3 {
		t.Fatalf("record = %+v", e)
	}
	if len(sink.tags[0]) != 1 || sink.tags[0][0] != "erasure_log:true" {
		t.Fatalf("tags = %v", sink.tags)
	}
	sink.err = errors.New("datadog down")
	if out := srv.deliverErasureOutbox(ctx, row); out.kind != outboxRetry {
		t.Fatalf("failed send = %+v", out)
	}
	srv.erasureLog = &fakeErasureLog{enabled: false}
	if out := srv.deliverErasureOutbox(ctx, row); out.kind != outboxDone {
		t.Fatalf("without Datadog = %+v; the record goes to slog", out)
	}
}

func TestErasureOutboxRetryBackoffAndExhaustion(t *testing.T) {
	now := time.Now()
	row := outboxRow(store.ErasureTargetStripeAccount, "acct_1", "")
	r := outboxResult(row, outboxOutcome{kind: outboxRetry, err: "boom"}, now)
	if r.State != store.ErasureOutboxPending || r.Attempts != 1 || !r.NextAt.Equal(now.Add(erasureOutboxBaseBackoff)) {
		t.Fatalf("first retry = %+v", r)
	}
	row.Attempts = 5
	if r := outboxResult(row, outboxOutcome{kind: outboxRetry, err: "boom"}, now); !r.NextAt.Equal(now.Add(32 * time.Minute)) {
		t.Fatalf("sixth retry next_at = %v", r.NextAt.Sub(now))
	}
	row.Attempts = erasureOutboxMaxAttempts - 1
	r = outboxResult(row, outboxOutcome{kind: outboxRetry, err: "boom"}, now)
	if r.State != store.ErasureOutboxManualAction || !strings.Contains(r.LastError, "retries exhausted") {
		t.Fatalf("last retry = %+v", r)
	}
}

func TestErasureOutboxMockModeSkipsStripe(t *testing.T) {
	srv, _, f := outboxTestServer(t, true)
	for _, target := range []store.ErasureTarget{store.ErasureTargetStripeAccount, store.ErasureTargetGlobalRecipient, store.ErasureTargetCheckoutSessions} {
		if out := srv.deliverErasureOutbox(context.Background(), outboxRow(target, "x", "")); out.kind != outboxDone {
			t.Fatalf("%s in mock mode = %+v", target, out)
		}
	}
	if len(f.requests) != 0 {
		t.Fatalf("mock mode called Stripe: %v", f.requests)
	}
}

// End to end: a scrub queues rows, the loop delivers them, and a done row no
// longer holds its Stripe ID; the status endpoint shows the outcome.
func TestErasureOutboxLoopDeliversScrubRows(t *testing.T) {
	srv, st, f := outboxTestServer(t, false)
	srv.SetAdminKey("admin-key")
	srv.erasureLog = &fakeErasureLog{enabled: true}
	ctx := context.Background()
	account := "acct-outbox"
	if err := st.CreateUser(&store.User{AccountID: account, PrivyUserID: "did:privy:outbox", Email: "o@example.com"}); err != nil {
		t.Fatal(err)
	}
	if err := st.SetUserStripeAccount(account, "acct_1Outbox", "ready", "US", "bank", "1234", false); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateBillingSession(&store.BillingSession{ID: "bs-1", AccountID: account, PaymentMethod: "stripe", AmountMicroUSD: 1, ExternalID: "cs_test_outbox", Status: "completed", CreatedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	plan, err := st.PlanAccountErasure(ctx, account, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.SaveErasurePlan(ctx, account, "admin_key", plan.ErasureCounts, "token", now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	req, err := st.RequestAccountErasure(ctx, store.ErasureConfirm{AccountID: account, ConfirmToken: "token", Email: "o@example.com", Now: now})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.ScrubAccount(ctx, req.ID, now); err != nil {
		t.Fatal(err)
	}
	f.on(http.MethodDelete, "/v1/accounts/acct_1Outbox", 200, `{"id":"acct_1Outbox","deleted":true}`)
	f.on(http.MethodPost, "/v1/privacy/redaction_jobs", 200, `{"id":"prj_9","status":"validating"}`)

	srv.runErasureOutbox(ctx)

	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	code, status := erasureCall(t, ts, http.MethodGet, "/v1/admin/accounts/"+account+"/erasure", "admin-key", nil)
	if code != http.StatusOK {
		t.Fatalf("status = %d", code)
	}
	got := map[string]map[string]any{}
	for _, o := range status["outbox"].([]any) {
		m := o.(map[string]any)
		got[m["target"].(string)] = m
	}
	if a := got["stripe_account"]; a["state"] != "done" || a["has_external_id"] != false {
		t.Fatalf("stripe_account row = %v", a)
	}
	if l := got["erasure_log"]; l["state"] != "done" {
		t.Fatalf("erasure_log row = %v", l)
	}
	if c := got["checkout_sessions"]; c["state"] != "pending" || c["has_stripe_job"] != true || c["has_external_id"] != true {
		t.Fatalf("checkout_sessions row = %v", c)
	}
	// The running job is not due again until the poll interval passes.
	srv.runErasureOutbox(ctx)
	if n := strings.Count(strings.Join(f.requests, "\n"), "POST /v1/privacy/redaction_jobs"); n != 1 {
		t.Fatalf("redaction job created %d times", n)
	}
}
