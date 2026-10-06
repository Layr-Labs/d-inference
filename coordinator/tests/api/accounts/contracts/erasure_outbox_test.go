package accounts_test

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// The worker's retry and redaction policy (api/accounts/erasure), as the
// tests expect it.
const (
	outboxBaseBackoff   = time.Minute
	outboxMaxAttempts   = 8
	redactionPoll       = 5 * time.Minute
	redactionWait       = 7 * 24 * time.Hour
	redactionDeadline   = 105 * 24 * time.Hour
	redactionStuckAfter = 31 * 24 * time.Hour
	tooRecentErrors     = `{"object":"list","data":[{"code":"invalid_state","message":"This charge can be redacted 90 days after it was created."}]}`
)

func TestErasureOutboxStripeAccount(t *testing.T) {
	fx := newOutboxFixture(t, false)
	for i, tc := range []struct {
		name   string
		status int
		body   string
		check  func(*testing.T, store.ErasureOutboxItem)
	}{
		{"success", 200, `{"id":"acct_x","deleted":true}`, wantDone},
		{"not found", 404, `{"error":{"type":"invalid_request_error","code":"resource_missing","message":"No such account"}}`, wantDone},
		{"not found without code", 404, `{"error":{"type":"invalid_request_error","message":"No such account"}}`,
			func(t *testing.T, it store.ErasureOutboxItem) { wantManual(t, it, "No such account") }},
		{"permission denied without code", 404, `{"error":{"type":"invalid_request_error","message":"The provided key does not have access to account acct_existing."}}`,
			func(t *testing.T, it store.ErasureOutboxItem) { wantManual(t, it, "does not have access") }},
		{"account invalid without message", 404, `{"error":{"type":"invalid_request_error","code":"account_invalid"}}`,
			func(t *testing.T, it store.ErasureOutboxItem) { wantManual(t, it, "account_invalid") }},
		{"malformed not found", 404, `<html>Not found</html>`,
			func(t *testing.T, it store.ErasureOutboxItem) { wantManual(t, it, "Not found") }},
		{"resource missing", 400, `{"error":{"type":"invalid_request_error","code":"resource_missing","message":"No such account"}}`, wantDone},
		{"access denied", 403, `{"error":{"type":"invalid_request_error","message":"The provided key does not have access to account acct_existing."}}`,
			func(t *testing.T, it store.ErasureOutboxItem) { wantManual(t, it, "does not have access") }},
		{"account invalid", 400, `{"error":{"type":"invalid_request_error","code":"account_invalid","message":"The account is not connected to this platform."}}`,
			func(t *testing.T, it store.ErasureOutboxItem) { wantManual(t, it, "account_invalid") }},
		{"account invalid with not found status", 404, `{"error":{"type":"invalid_request_error","code":"account_invalid","message":"The account is not connected to this platform."}}`,
			func(t *testing.T, it store.ErasureOutboxItem) { wantManual(t, it, "account_invalid") }},
		{"missing message alone", 400, `{"error":{"type":"invalid_request_error","message":"No such account, or this platform does not have access to account acct_existing."}}`,
			func(t *testing.T, it store.ErasureOutboxItem) { wantManual(t, it, "No such account") }},
		{"permission failure with missing code", 403, `{"error":{"type":"invalid_request_error","code":"resource_missing","message":"Access denied."}}`,
			func(t *testing.T, it store.ErasureOutboxItem) { wantManual(t, it, "Access denied") }},
		{"balance not zero", 400, `{"error":{"type":"invalid_request_error","message":"This account cannot be deleted because it has a non-zero balance."}}`,
			func(t *testing.T, it store.ErasureOutboxItem) { wantManual(t, it, "non-zero balance") }},
		{"server error", 500, `{"error":{"type":"api_error","message":"try again"}}`, func(t *testing.T, it store.ErasureOutboxItem) { wantRetry(t, it, 1) }},
		{"transient missing message", 503, `{"error":{"type":"api_error","message":"No such account in upstream cache; try again."}}`, func(t *testing.T, it store.ErasureOutboxItem) { wantRetry(t, it, 1) }},
		{"rate limited", 429, `{"error":{"type":"rate_limit_error","message":"slow down"}}`, func(t *testing.T, it store.ErasureOutboxItem) { wantRetry(t, it, 1) }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			id := caseID("acct_1Abc", i)
			account := fx.scrub(t, outboxSeed{stripeAccount: id})
			fx.stripe.on(http.MethodDelete, "/v1/accounts/"+id, tc.status, tc.body)
			fx.pass(t, account)
			row := fx.row(t, account, store.ErasureTargetStripeAccount)
			tc.check(t, row)
			if row.State != store.ErasureOutboxDone && (row.ExternalID != id || !row.HasExternalID || row.DoneAt != nil) {
				t.Fatalf("unconfirmed deletion lost its account ID or set done_at: %+v", row)
			}
			if got := fx.stripe.header("DELETE /v1/accounts/"+id, "Authorization"); got != "Bearer sk_test_connect" {
				t.Fatalf("Connect key not used: %q", got)
			}
		})
	}
}

func TestErasureOutboxGlobalRecipient(t *testing.T) {
	fx := newOutboxFixture(t, false)
	for i, tc := range []struct {
		name   string
		status int
		body   string
		check  func(*testing.T, store.ErasureOutboxItem)
	}{
		{"success", 200, `{"id":"acct_recipient","applied_configurations":[]}`, wantDone},
		{"not found", 404, `{"error":{"code":"not_found"}}`, wantDone},
		{"balance", 400, `{"error":{"code":"cannot_delete_account_with_balance"}}`,
			func(t *testing.T, it store.ErasureOutboxItem) {
				wantManual(t, it, "cannot_delete_account_with_balance")
			}},
		{"transient", 503, `{"error":{"code":"unavailable"}}`, func(t *testing.T, it store.ErasureOutboxItem) { wantRetry(t, it, 1) }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			id := caseID("acct_recipient", i)
			path := "/v2/core/accounts/" + id + "/close"
			account := fx.scrub(t, outboxSeed{recipient: id})
			fx.stripe.on(http.MethodPost, path, tc.status, tc.body)
			fx.pass(t, account)
			tc.check(t, fx.row(t, account, store.ErasureTargetGlobalRecipient))
			var body struct {
				AppliedConfigurations []string `json:"applied_configurations"`
			}
			if err := json.Unmarshal([]byte(fx.stripe.body("POST "+path)), &body); err != nil || len(body.AppliedConfigurations) != 1 || body.AppliedConfigurations[0] != "recipient" {
				t.Fatalf("close body = %q", fx.stripe.body("POST "+path))
			}
		})
	}
}

func TestErasureOutboxRedactionJobLifecycle(t *testing.T) {
	fx := newOutboxFixture(t, false)
	account := fx.scrub(t, outboxSeed{sessions: []string{"cs_test_1", "cs_test_2"}})

	fx.stripe.on(http.MethodPost, "/v1/privacy/redaction_jobs", 200, `{"id":"prj_1","status":"validating"}`)
	start := fx.pass(t, account)
	row := fx.row(t, account, store.ErasureTargetCheckoutSessions)
	if row.State != store.ErasureOutboxPending || row.StripeJobID != "prj_1" || !row.HasStripeJob || row.JobStatus != "validating" || row.Attempts != 0 {
		t.Fatalf("after create = %+v", row)
	}
	wantNextAt(t, row, start, redactionPoll)
	form := fx.stripe.body("POST /v1/privacy/redaction_jobs")
	if !strings.Contains(form, "validation_behavior=fix") || strings.Count(form, "objects%5Bcheckout_sessions%5D%5B%5D=cs_test_") != 2 {
		t.Fatalf("create form = %q", form)
	}
	if got := fx.stripe.header("POST /v1/privacy/redaction_jobs", "Idempotency-Key"); got != "erasure-redaction-"+row.ID+"-0" {
		t.Fatalf("idempotency key = %q", got)
	}

	fx.stripe.on(http.MethodGet, "/v1/privacy/redaction_jobs/prj_1", 200, `{"id":"prj_1","status":"validating"}`)
	fx.setRow(t, row, nil)
	fx.pass(t, account)
	if row = fx.row(t, account, store.ErasureTargetCheckoutSessions); row.State != store.ErasureOutboxPending || row.StripeJobID != "prj_1" || row.JobStatus != "validating" {
		t.Fatalf("validating = %+v", row)
	}

	fx.stripe.on(http.MethodGet, "/v1/privacy/redaction_jobs/prj_1", 200, `{"id":"prj_1","status":"ready"}`)
	fx.stripe.on(http.MethodPost, "/v1/privacy/redaction_jobs/prj_1/run", 200, `{"id":"prj_1","status":"redacting"}`)
	fx.setRow(t, row, nil)
	fx.pass(t, account)
	if row = fx.row(t, account, store.ErasureTargetCheckoutSessions); row.State != store.ErasureOutboxPending || row.StripeJobID != "prj_1" || row.JobStatus != "redacting" {
		t.Fatalf("ready = %+v", row)
	}
	if fx.stripe.count("POST /v1/privacy/redaction_jobs/prj_1/run") != 1 {
		t.Fatal("ready job was not run")
	}

	fx.stripe.on(http.MethodGet, "/v1/privacy/redaction_jobs/prj_1", 200, `{"id":"prj_1","status":"succeeded"}`)
	fx.setRow(t, row, nil)
	fx.pass(t, account)
	wantDone(t, fx.row(t, account, store.ErasureTargetCheckoutSessions))
}

func TestErasureOutboxRedactionOutcomes(t *testing.T) {
	fx := newOutboxFixture(t, false)
	fresh := func(t *testing.T) string {
		return fx.scrub(t, outboxSeed{sessions: []string{"cs_test_1"}})
	}
	running := func(t *testing.T) string {
		account := fresh(t)
		fx.setRow(t, fx.row(t, account, store.ErasureTargetCheckoutSessions), func(r *store.ErasureOutboxResult) { r.StripeJobID = "prj_2" })
		return account
	}
	checkout := func(t *testing.T, account string) store.ErasureOutboxItem {
		return fx.row(t, account, store.ErasureTargetCheckoutSessions)
	}

	t.Run("feature not enabled", func(t *testing.T) {
		account := fresh(t)
		fx.stripe.on(http.MethodPost, "/v1/privacy/redaction_jobs", 400, `{"error":{"type":"invalid_request_error","message":"Redaction jobs are not enabled for this account."}}`)
		fx.pass(t, account)
		wantManual(t, checkout(t, account), "not enabled")
	})
	t.Run("single session not found needs an operator", func(t *testing.T) {
		account := fresh(t)
		fx.stripe.on(http.MethodPost, "/v1/privacy/redaction_jobs", 404, `{"error":{"code":"resource_missing","message":"No such checkout session"}}`)
		fx.pass(t, account)
		wantManual(t, checkout(t, account), "earlier Stripe account")
	})
	t.Run("transient", func(t *testing.T) {
		account := fresh(t)
		fx.stripe.on(http.MethodPost, "/v1/privacy/redaction_jobs", 502, `{"error":{"message":"bad gateway"}}`)
		fx.pass(t, account)
		wantRetry(t, checkout(t, account), 1)
	})
	t.Run("too recent reschedules", func(t *testing.T) {
		account := running(t)
		fx.stripe.on(http.MethodGet, "/v1/privacy/redaction_jobs/prj_2", 200, `{"id":"prj_2","status":"failed"}`)
		fx.stripe.on(http.MethodGet, "/v1/privacy/redaction_jobs/prj_2/validation_errors", 200, tooRecentErrors)
		start := fx.pass(t, account)
		row := checkout(t, account)
		if row.State != store.ErasureOutboxPending || row.Attempts != 0 || row.StripeJobID != "" || row.JobGeneration != 1 {
			t.Fatalf("row = %+v; a reschedule keeps the row pending, counts no attempt and drops the job", row)
		}
		wantNextAt(t, row, start, redactionWait)
	})
	t.Run("other validation error needs an operator", func(t *testing.T) {
		account := running(t)
		fx.stripe.on(http.MethodGet, "/v1/privacy/redaction_jobs/prj_2", 200, `{"id":"prj_2","status":"failed"}`)
		fx.stripe.on(http.MethodGet, "/v1/privacy/redaction_jobs/prj_2/validation_errors", 200,
			`{"object":"list","data":[{"code":"locked_by_other_job","message":"The object is used in another redaction job."}]}`)
		fx.pass(t, account)
		wantManual(t, checkout(t, account), "locked_by_other_job")
	})
	t.Run("canceled job", func(t *testing.T) {
		account := running(t)
		fx.stripe.on(http.MethodGet, "/v1/privacy/redaction_jobs/prj_2", 200, `{"id":"prj_2","status":"canceled"}`)
		fx.pass(t, account)
		wantManual(t, checkout(t, account), "canceled")
	})
}

func TestErasureOutboxErasureLog(t *testing.T) {
	fx := newOutboxFixture(t, false)
	dd, intake := newDatadogClient(t)
	fx.srv.SetDatadog(dd)

	account := fx.scrub(t, outboxSeed{})
	fx.pass(t, account)
	row := fx.row(t, account, store.ErasureTargetErasureLog)
	wantDone(t, row)
	events := intake.erasureLogEvents()
	if len(events) != 1 {
		t.Fatalf("erasure_log events = %+v", events)
	}
	e := events[0]
	if e.DDTags != "kind:erasure_log,severity:info,erasure_log:true" || e.Message != "account erased" {
		t.Fatalf("record = %+v", e)
	}
	if e.Attrs["request_id"] != row.RequestID || e.Attrs["account_id"] != account || e.Attrs["erased_at"] == "" || len(e.Attrs) != 3 {
		t.Fatalf("record fields = %v; want only request_id, account_id and erased_at", e.Attrs)
	}

	intake.setStatus(http.StatusInternalServerError)
	failed := fx.scrub(t, outboxSeed{})
	fx.pass(t, failed)
	wantRetry(t, fx.row(t, failed, store.ErasureTargetErasureLog), 1)

	// Without Datadog the record goes to the process log.
	plain := newOutboxFixture(t, false)
	account = plain.scrub(t, outboxSeed{})
	plain.pass(t, account)
	wantDone(t, plain.row(t, account, store.ErasureTargetErasureLog))
}

func TestErasureOutboxRetryBackoffAndExhaustion(t *testing.T) {
	fx := newOutboxFixture(t, false)
	account := fx.scrub(t, outboxSeed{stripeAccount: "acct_1Backoff"})
	fx.stripe.on(http.MethodDelete, "/v1/accounts/acct_1Backoff", 500, `{"error":{"type":"api_error","message":"boom"}}`)

	start := fx.pass(t, account)
	row := fx.row(t, account, store.ErasureTargetStripeAccount)
	wantRetry(t, row, 1)
	wantNextAt(t, row, start, outboxBaseBackoff)

	fx.setRow(t, row, func(r *store.ErasureOutboxResult) { r.Attempts = 5 })
	start = fx.pass(t, account)
	row = fx.row(t, account, store.ErasureTargetStripeAccount)
	wantRetry(t, row, 6)
	wantNextAt(t, row, start, 32*time.Minute)

	fx.setRow(t, row, func(r *store.ErasureOutboxResult) { r.Attempts = outboxMaxAttempts - 1 })
	fx.pass(t, account)
	wantManual(t, fx.row(t, account, store.ErasureTargetStripeAccount), "retries exhausted")
}

func TestErasureOutboxMockModeSkipsStripe(t *testing.T) {
	fx := newOutboxFixture(t, true)
	account := fx.scrub(t, outboxSeed{stripeAccount: "acct_1Mock", recipient: "acct_recipient_mock", sessions: []string{"cs_test_mock"}})
	fx.pass(t, account)
	for _, target := range []store.ErasureTarget{store.ErasureTargetStripeAccount, store.ErasureTargetGlobalRecipient, store.ErasureTargetCheckoutSessions} {
		wantDone(t, fx.row(t, account, target))
	}
	if n := fx.stripe.total(); n != 0 {
		t.Fatalf("mock mode called Stripe %d times", n)
	}
}

// End to end: a scrub queues rows, the loop delivers them, and a done row no
// longer holds its Stripe ID; the status endpoint shows the outcome.
func TestErasureOutboxLoopDeliversScrubRows(t *testing.T) {
	fx := newOutboxFixture(t, false)
	dd, _ := newDatadogClient(t)
	fx.srv.SetDatadog(dd)
	account := fx.scrub(t, outboxSeed{stripeAccount: "acct_1Outbox", sessions: []string{"cs_test_outbox"}})
	fx.stripe.on(http.MethodDelete, "/v1/accounts/acct_1Outbox", 200, `{"id":"acct_1Outbox","deleted":true}`)
	fx.stripe.on(http.MethodPost, "/v1/privacy/redaction_jobs", 200, `{"id":"prj_9","status":"validating"}`)

	fx.pass(t, account)

	ts := httptest.NewServer(fx.srv.Handler())
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
	due, err := fx.st.LeaseDueErasureOutbox(context.Background(), time.Now().UTC(), time.Now().UTC(), time.Minute, 20)
	if err != nil || len(due) != 0 {
		t.Fatalf("due rows after the pass = %+v, %v", due, err)
	}
	if n := fx.stripe.count("POST /v1/privacy/redaction_jobs"); n != 1 {
		t.Fatalf("redaction job created %d times", n)
	}
}

// One missing session in a batch must not stop the others: they stay on the
// row for a new job, and the missing one moves to a manual_action row.
func TestErasureOutboxRedactionSplitsMissingSessions(t *testing.T) {
	fx := newOutboxFixture(t, false)
	account := fx.scrub(t, outboxSeed{sessions: []string{"cs_test_a", "cs_test_old", "cs_test_b"}})
	fx.stripe.on(http.MethodPost, "/v1/privacy/redaction_jobs", 404, `{"error":{"code":"resource_missing","message":"No such checkout.session: 'cs_test_old'"}}`)
	fx.stripe.on(http.MethodGet, "/v1/checkout/sessions/cs_test_a", 200, `{"id":"cs_test_a"}`)
	fx.stripe.on(http.MethodGet, "/v1/checkout/sessions/cs_test_b", 200, `{"id":"cs_test_b"}`)
	fx.stripe.on(http.MethodGet, "/v1/checkout/sessions/cs_test_old", 404, `{"error":{"code":"resource_missing","message":"No such checkout.session"}}`)
	original := fx.row(t, account, store.ErasureTargetCheckoutSessions)

	fx.pass(t, account)
	var kept, split store.ErasureOutboxItem
	for _, it := range fx.items(t, account) {
		switch {
		case it.Target != store.ErasureTargetCheckoutSessions:
		case it.ID == original.ID:
			kept = it
		default:
			split = it
		}
	}
	if kept.State != store.ErasureOutboxPending || kept.ExternalID != "cs_test_a,cs_test_b" || kept.JobGeneration != 1 || kept.StripeJobID != "" {
		t.Fatalf("kept row = %+v", kept)
	}
	if split.State != store.ErasureOutboxManualAction || split.ExternalID != "cs_test_old" || split.RequestID != original.RequestID || !strings.Contains(split.LastError, "earlier Stripe account") {
		t.Fatalf("split row = %+v", split)
	}

	// The next create uses a new idempotency key for the smaller batch.
	fx.stripe.on(http.MethodPost, "/v1/privacy/redaction_jobs", 200, `{"id":"prj_5","status":"validating"}`)
	fx.pass(t, account)
	for _, it := range fx.items(t, account) {
		if it.ID == original.ID && (it.State != store.ErasureOutboxPending || it.StripeJobID != "prj_5") {
			t.Fatalf("second create = %+v", it)
		}
	}
	if got := fx.stripe.header("POST /v1/privacy/redaction_jobs", "Idempotency-Key"); got != "erasure-redaction-"+original.ID+"-1" {
		t.Fatalf("idempotency key = %q", got)
	}
}

// A job that disappears gets a new idempotency key, a job stuck in one
// status escalates, and the 90-day waits end at a deadline.
func TestErasureOutboxRedactionEscalation(t *testing.T) {
	fx := newOutboxFixture(t, false)

	t.Run("gone job gets a new key", func(t *testing.T) {
		account := fx.scrub(t, outboxSeed{sessions: []string{"cs_test_1"}})
		fx.setRow(t, fx.row(t, account, store.ErasureTargetCheckoutSessions), func(r *store.ErasureOutboxResult) { r.StripeJobID = "prj_dead" })
		fx.stripe.on(http.MethodGet, "/v1/privacy/redaction_jobs/prj_dead", 404, `{"error":{"code":"resource_missing","message":"No such job"}}`)
		fx.pass(t, account)
		if row := fx.row(t, account, store.ErasureTargetCheckoutSessions); row.State != store.ErasureOutboxPending || row.StripeJobID != "" || row.JobGeneration != 1 || row.Attempts != 0 {
			t.Fatalf("row = %+v", row)
		}
	})
	t.Run("status clock", func(t *testing.T) {
		account := fx.scrub(t, outboxSeed{sessions: []string{"cs_test_1"}})
		fx.setRow(t, fx.row(t, account, store.ErasureTargetCheckoutSessions), func(r *store.ErasureOutboxResult) { r.StripeJobID = "prj_slow" })
		fx.stripe.on(http.MethodGet, "/v1/privacy/redaction_jobs/prj_slow", 200, `{"id":"prj_slow","status":"validating"}`)
		start := fx.pass(t, account)
		row := fx.row(t, account, store.ErasureTargetCheckoutSessions)
		if row.JobStatus != "validating" || row.JobStatusSince == nil || row.JobStatusSince.Before(start) {
			t.Fatalf("first poll = %+v", row)
		}
		since := *row.JobStatusSince
		fx.setRow(t, row, nil)
		fx.pass(t, account)
		if row = fx.row(t, account, store.ErasureTargetCheckoutSessions); row.JobStatusSince == nil || !row.JobStatusSince.Equal(since) {
			t.Fatalf("unchanged status restarted the clock: %+v", row)
		}
		old := time.Now().UTC().Add(-redactionStuckAfter - time.Hour)
		fx.setRow(t, row, func(r *store.ErasureOutboxResult) { r.JobStatusSince = &old })
		fx.pass(t, account)
		wantManual(t, fx.row(t, account, store.ErasureTargetCheckoutSessions), "validating since")
	})
	t.Run("90-day waits end", func(t *testing.T) {
		account := fx.scrub(t, outboxSeed{sessions: []string{"cs_test_1"}, scrubAt: time.Now().UTC().Add(-redactionDeadline - time.Hour)})
		fx.setRow(t, fx.row(t, account, store.ErasureTargetCheckoutSessions), func(r *store.ErasureOutboxResult) { r.StripeJobID = "prj_young" })
		fx.stripe.on(http.MethodGet, "/v1/privacy/redaction_jobs/prj_young", 200, `{"id":"prj_young","status":"failed"}`)
		fx.stripe.on(http.MethodGet, "/v1/privacy/redaction_jobs/prj_young/validation_errors", 200, tooRecentErrors)
		fx.pass(t, account)
		wantManual(t, fx.row(t, account, store.ErasureTargetCheckoutSessions), "still too recent")
	})
}

// A transient Stripe error while a job runs must not restart the job's
// status clock; otherwise retried errors postpone the stuck-job escalation
// forever.
func TestErasureOutboxTransientErrorKeepsJobStatusClock(t *testing.T) {
	fx := newOutboxFixture(t, false)
	transient := `{"error":{"type":"api_error","message":"try again"}}`

	t.Run("job read fails", func(t *testing.T) {
		account := fx.scrub(t, outboxSeed{sessions: []string{"cs_test_1"}})
		since := time.Now().UTC().Add(-redactionStuckAfter - time.Hour)
		fx.setRow(t, fx.row(t, account, store.ErasureTargetCheckoutSessions), func(r *store.ErasureOutboxResult) {
			r.StripeJobID, r.JobStatus, r.JobStatusSince = "prj_flaky", "validating", &since
		})
		fx.stripe.on(http.MethodGet, "/v1/privacy/redaction_jobs/prj_flaky", 500, transient)
		for attempt := 1; attempt <= 3; attempt++ {
			fx.pass(t, account)
			row := fx.row(t, account, store.ErasureTargetCheckoutSessions)
			wantRetry(t, row, attempt)
			if row.StripeJobID != "prj_flaky" || row.JobStatus != "validating" || row.JobStatusSince == nil || !row.JobStatusSince.Equal(since) {
				t.Fatalf("after transient error %d = %+v; the job status clock moved", attempt, row)
			}
			fx.setRow(t, row, nil)
		}
		fx.stripe.on(http.MethodGet, "/v1/privacy/redaction_jobs/prj_flaky", 200, `{"id":"prj_flaky","status":"validating"}`)
		fx.pass(t, account)
		wantManual(t, fx.row(t, account, store.ErasureTargetCheckoutSessions), "validating since")
	})
	t.Run("job run fails", func(t *testing.T) {
		account := fx.scrub(t, outboxSeed{sessions: []string{"cs_test_1"}})
		since := time.Now().UTC().Add(-24 * time.Hour)
		fx.setRow(t, fx.row(t, account, store.ErasureTargetCheckoutSessions), func(r *store.ErasureOutboxResult) {
			r.StripeJobID, r.JobStatus, r.JobStatusSince = "prj_ready", "ready", &since
		})
		fx.stripe.on(http.MethodGet, "/v1/privacy/redaction_jobs/prj_ready", 200, `{"id":"prj_ready","status":"ready"}`)
		fx.stripe.on(http.MethodPost, "/v1/privacy/redaction_jobs/prj_ready/run", 500, transient)
		fx.pass(t, account)
		row := fx.row(t, account, store.ErasureTargetCheckoutSessions)
		wantRetry(t, row, 1)
		if row.JobStatus != "ready" || row.JobStatusSince == nil || !row.JobStatusSince.Equal(since) {
			t.Fatalf("after a failed run = %+v; the job status clock moved", row)
		}
	})
}
