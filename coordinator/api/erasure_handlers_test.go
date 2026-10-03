package api

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func erasureCall(t *testing.T, ts *httptest.Server, method, path, token string, body any) (int, map[string]any) {
	t.Helper()
	var buf bytes.Buffer
	if body != nil {
		if err := json.NewEncoder(&buf).Encode(body); err != nil {
			t.Fatal(err)
		}
	}
	req, err := http.NewRequest(method, ts.URL+path, &buf)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	out := map[string]any{}
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

func seedErasureHTTPAccount(t *testing.T, srv *Server, st *store.MemoryStore) (account, email, rawKey string) {
	t.Helper()
	account, email = "acct-erase-http", "person@example.com"
	if err := st.CreateUser(&store.User{AccountID: account, PrivyUserID: "did:privy:erase-http", Email: email}); err != nil {
		t.Fatal(err)
	}
	raw, _, err := st.CreateAPIKey(account, store.APIKeyCreate{Name: "work laptop"})
	if err != nil {
		t.Fatal(err)
	}
	if err := st.Credit(account, 4_000_000, store.LedgerDeposit, "seed"); err != nil {
		t.Fatal(err)
	}
	p := srv.registry.Register("erase-http-provider", nil, &protocol.RegisterMessage{})
	p.Mu().Lock()
	p.AccountID = account
	p.Mu().Unlock()
	return account, email, raw
}

func TestAdminErasureHTTPFlow(t *testing.T) {
	srv, st := testBillingServer(t)
	srv.SetAdminKey("admin-key")
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	account, email, rawKey := seedErasureHTTPAccount(t, srv, st)
	base := "/v1/admin/accounts/" + account + "/erasure"

	// The key works before the erasure (and is now in the server key cache).
	if code, _ := erasureCall(t, ts, http.MethodGet, "/v1/payments/balance", rawKey, nil); code != http.StatusOK {
		t.Fatalf("balance with the live key = %d", code)
	}

	if code, _ := erasureCall(t, ts, http.MethodPost, base+"/plan", "wrong-key", nil); code != http.StatusForbidden && code != http.StatusUnauthorized {
		t.Fatalf("plan without admin = %d", code)
	}
	if code, _ := erasureCall(t, ts, http.MethodPost, "/v1/admin/accounts/nobody/erasure/plan", "admin-key", nil); code != http.StatusNotFound {
		t.Fatalf("plan of an unknown account = %d", code)
	}
	code, plan := erasureCall(t, ts, http.MethodPost, base+"/plan", "admin-key", nil)
	if code != http.StatusOK || plan["email"] != email || plan["confirm_token"] == "" || plan["balance_micro_usd"] != float64(4_000_000) {
		t.Fatalf("plan = %d %v", code, plan)
	}
	if plan["grace_seconds"] != float64(defaultErasureGrace/time.Second) {
		t.Fatalf("grace_seconds = %v", plan["grace_seconds"])
	}
	token := plan["confirm_token"].(string)

	if code, body := erasureCall(t, ts, http.MethodPost, base, "admin-key", map[string]any{"confirm_token": token, "email": "other@example.com"}); code != http.StatusBadRequest {
		t.Fatalf("confirm with the wrong email = %d %v", code, body)
	}
	if code, _ := erasureCall(t, ts, http.MethodPost, base, "admin-key", map[string]any{"confirm_token": "nope", "email": email}); code != http.StatusForbidden {
		t.Fatalf("confirm with the wrong token = %d", code)
	}
	code, confirmed := erasureCall(t, ts, http.MethodPost, base, "admin-key", map[string]any{"confirm_token": token, "email": email, "reason": "ticket 42"})
	if code != http.StatusOK {
		t.Fatalf("confirm = %d %v", code, confirmed)
	}
	req := confirmed["request"].(map[string]any)
	if req["state"] != string(store.ErasurePending) || req["actor"] != "admin_key" {
		t.Fatalf("request = %v", req)
	}
	if srv.registry.GetProvider("erase-http-provider") != nil {
		t.Fatal("the account's provider is still connected")
	}
	// The cached key is dropped with the revocation.
	if code, _ := erasureCall(t, ts, http.MethodGet, "/v1/payments/balance", rawKey, nil); code != http.StatusUnauthorized {
		t.Fatalf("balance with the revoked key = %d", code)
	}

	code, status := erasureCall(t, ts, http.MethodGet, base, "admin-key", nil)
	if code != http.StatusOK || status["request"].(map[string]any)["state"] != string(store.ErasurePending) {
		t.Fatalf("status = %d %v", code, status)
	}

	code, canceled := erasureCall(t, ts, http.MethodPost, base+"/cancel", "admin-key", nil)
	if code != http.StatusOK || canceled["request"].(map[string]any)["state"] != string(store.ErasureCanceled) {
		t.Fatalf("cancel = %d %v", code, canceled)
	}
	if code, _ := erasureCall(t, ts, http.MethodPost, base+"/cancel", "admin-key", nil); code != http.StatusNotFound {
		t.Fatalf("second cancel = %d", code)
	}
	if _, err := st.GetUserByAccountID(account); err != nil {
		t.Fatalf("user after cancel: %v", err)
	}

	// force=true scrubs at once.
	_, plan = erasureCall(t, ts, http.MethodPost, base+"/plan", "admin-key", nil)
	code, forced := erasureCall(t, ts, http.MethodPost, base, "admin-key", map[string]any{"confirm_token": plan["confirm_token"], "email": email, "force": true})
	if code != http.StatusOK || forced["request"].(map[string]any)["state"] != string(store.ErasureErased) {
		t.Fatalf("forced erasure = %d %v", code, forced)
	}
	code, status = erasureCall(t, ts, http.MethodGet, base, "admin-key", nil)
	if code != http.StatusOK {
		t.Fatalf("status after scrub = %d", code)
	}
	outbox := status["outbox"].([]any)
	if len(outbox) != 1 || outbox[0].(map[string]any)["target"] != string(store.ErasureTargetErasureLog) {
		t.Fatalf("outbox = %v", outbox)
	}
	if st.GetBalance(account) != 0 {
		t.Fatalf("balance after scrub = %d", st.GetBalance(account))
	}
	if code, _ := erasureCall(t, ts, http.MethodPost, base+"/cancel", "admin-key", nil); code != http.StatusNotFound {
		t.Fatalf("cancel after scrub = %d", code)
	}
}

func TestAdminErasureRefusesOpenWithdrawalHTTP(t *testing.T) {
	srv, st := testBillingServer(t)
	srv.SetAdminKey("admin-key")
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	account, email, _ := seedErasureHTTPAccount(t, srv, st)
	if err := st.CreditWithdrawable(account, 2_000_000, store.LedgerAdminReward, "seed"); err != nil {
		t.Fatal(err)
	}
	wd := &store.StripeWithdrawal{ID: "wd-open", AccountID: account, StripeAccountID: "acct_x", AmountMicroUSD: 1_000_000, NetMicroUSD: 1_000_000, Method: "standard", Status: "transferred"}
	if err := st.CreateStripeWithdrawalWithDebit(wd, store.LedgerStripePayout, "stripe_withdraw:"+wd.ID); err != nil {
		t.Fatal(err)
	}
	base := "/v1/admin/accounts/" + account + "/erasure"
	_, plan := erasureCall(t, ts, http.MethodPost, base+"/plan", "admin-key", nil)
	if plan["open_withdrawals"] != float64(1) {
		t.Fatalf("plan open_withdrawals = %v", plan["open_withdrawals"])
	}
	if code, body := erasureCall(t, ts, http.MethodPost, base, "admin-key", map[string]any{"confirm_token": plan["confirm_token"], "email": email}); code != http.StatusConflict || body["error"].(map[string]any)["type"] != "open_withdrawal" {
		t.Fatalf("confirm with an open withdrawal = %d %v", code, body)
	}
}

// A Privy login of an account that waits for erasure gets 403
// account_pending_deletion instead of a second live account.
func TestPrivyLoginRefusedDuringErasureGrace(t *testing.T) {
	srv, st := testBillingServer(t)
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	user := &store.User{AccountID: "acct-grace", PrivyUserID: "did:privy:grace", Email: "grace@example.com"}
	if err := st.CreateUser(user); err != nil {
		t.Fatal(err)
	}
	token := privySession(t, srv, st, user)
	if code, _ := erasureCall(t, ts, http.MethodGet, "/v1/payments/balance", token, nil); code != http.StatusOK {
		t.Fatalf("login before erasure = %d", code)
	}
	ctx := context.Background()
	now := time.Now()
	plan, err := st.PlanAccountErasure(ctx, user.AccountID, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.SaveErasurePlan(ctx, user.AccountID, "admin_key", plan.ErasureCounts, "token", now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	if _, err := st.RequestAccountErasure(ctx, store.ErasureConfirm{AccountID: user.AccountID, ConfirmToken: "token", Email: user.Email, Now: now, Grace: time.Hour}); err != nil {
		t.Fatal(err)
	}
	code, body := erasureCall(t, ts, http.MethodGet, "/v1/payments/balance", token, nil)
	if code != http.StatusForbidden || body["error"].(map[string]any)["type"] != "account_pending_deletion" {
		t.Fatalf("login during grace = %d %v", code, body)
	}
	if _, err := st.GetUserByPrivyID(user.PrivyUserID); err == nil {
		t.Fatal("the refused login created a second live account")
	}
}

// The loop scrubs a request whose grace period ended and clears the
// in-memory usage history.
func TestRunDueErasuresScrubsAndForgets(t *testing.T) {
	srv, st := testBillingServer(t)
	account := "acct-due"
	if err := st.CreateUser(&store.User{AccountID: account, PrivyUserID: "did:privy:due", Email: "due@example.com"}); err != nil {
		t.Fatal(err)
	}
	srv.ledger.RecordUsage(account, payments.UsageEntry{JobID: "job-1", Model: "m"})
	ctx := context.Background()
	past := time.Now().Add(-2 * time.Hour)
	plan, err := st.PlanAccountErasure(ctx, account, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.SaveErasurePlan(ctx, account, "admin_key", plan.ErasureCounts, "token", past.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	if _, err := st.RequestAccountErasure(ctx, store.ErasureConfirm{AccountID: account, ConfirmToken: "token", Email: "due@example.com", Now: past, Grace: time.Hour}); err != nil {
		t.Fatal(err)
	}
	srv.runDueErasures(ctx)
	req, _, err := st.GetAccountErasure(ctx, account)
	if err != nil || req.State != store.ErasureErased {
		t.Fatalf("request after the loop = %+v, %v", req, err)
	}
	if got := srv.ledger.Usage(account); len(got) != 0 {
		t.Fatalf("in-memory usage after erasure = %v", got)
	}
}

// A Checkout Session that completes after the scrub is acknowledged, not
// retried, and credits nothing.
func TestCheckoutWebhookAcknowledgesErasedSession(t *testing.T) {
	s, st := stripePayoutsTestServer(t, true, nil)
	s.SetBilling(billing.NewService(st, s.billing.Ledger(), s.logger, billing.Config{StripeSecretKey: "rk_new", StripeWebhookSecret: "whsec_test"}))
	account := "acct-checkout-erased"
	if err := st.CreateUser(&store.User{AccountID: account, PrivyUserID: "did:privy:checkout", Email: "c@example.com"}); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateBillingSession(&store.BillingSession{ID: "late-session", ExternalID: "cs_late", AccountID: account, PaymentMethod: "stripe", AmountMicroUSD: 5_000_000, Status: "pending", CreatedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	now := time.Now()
	plan, err := st.PlanAccountErasure(ctx, account, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.SaveErasurePlan(ctx, account, "admin_key", plan.ErasureCounts, "token", now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	req, err := st.RequestAccountErasure(ctx, store.ErasureConfirm{AccountID: account, ConfirmToken: "token", Email: "c@example.com", Now: now})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.ScrubAccount(ctx, req.ID, now); err != nil {
		t.Fatal(err)
	}
	payload := []byte(`{"type":"checkout.session.completed","data":{"object":{"id":"cs_late","amount_total":500,"currency":"usd","payment_status":"paid","metadata":{"billing_session_id":"late-session","consumer_key":"` + account + `","app":"darkbloom"}}}}`)
	w := httptest.NewRecorder()
	s.handleStripeWebhook(w, signedConnectRequest(t, payload, "whsec_test"))
	if w.Code != http.StatusOK {
		t.Fatalf("late checkout webhook = %d %s", w.Code, w.Body.String())
	}
	if st.GetBalance(account) != 0 {
		t.Fatalf("late checkout credited %d", st.GetBalance(account))
	}
}

func TestErasureGraceFromEnv(t *testing.T) {
	for _, tc := range []struct {
		value   string
		want    time.Duration
		ignored bool
	}{
		{"", defaultErasureGrace, false},
		{"48h", 48 * time.Hour, false},
		{"0s", 0, false},
		{"30d", defaultErasureGrace, true},
		{"-1h", defaultErasureGrace, true},
	} {
		t.Setenv("EIGENINFERENCE_ERASURE_GRACE", tc.value)
		if got, ignored := erasureGraceFromEnv(); got != tc.want || ignored != tc.ignored {
			t.Errorf("%q: got %v, %v; want %v, %v", tc.value, got, ignored, tc.want, tc.ignored)
		}
	}
}
