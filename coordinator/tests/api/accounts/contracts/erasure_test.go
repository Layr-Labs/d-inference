package accounts_test

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/api/readcache"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/erasurefixture"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
)

// defaultErasureGrace is the documented default grace period (30 days).
const defaultErasureGrace = 30 * 24 * time.Hour

// erasureServer is a composed server with an in-memory store and the ledger
// whose in-memory usage history the erasure clears.
type erasureServer struct {
	*api.Server
	registry *registry.Registry
	ledger   *payments.Ledger
}

func newErasureServer(t *testing.T) (*erasureServer, *memory.MemoryStore) {
	t.Helper()
	logger := slog.New(slog.DiscardHandler)
	st := memory.NewMemory(store.Config{})
	reg := registry.New(logger)
	ledger := payments.NewLedger(st)
	srv := api.NewRuntime(api.RuntimeDependencies{Registry: reg, Store: st, Ledger: ledger, ReadCache: readcache.New(), Logger: logger}, api.ServerConfig{}).Server
	t.Cleanup(srv.Close)
	srv.SetAdminKey("admin-key")
	return &erasureServer{Server: srv, registry: reg, ledger: ledger}, st
}

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

func seedErasureHTTPAccount(t *testing.T, srv *erasureServer, st *memory.MemoryStore) (account, email, rawKey string) {
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
	srv, st := newErasureServer(t)
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

	if code, body := erasureCall(t, ts, http.MethodPost, base, "admin-key", map[string]any{"account_id": account, "confirm_token": token, "email": "other@example.com"}); code != http.StatusBadRequest {
		t.Fatalf("confirm with the wrong email = %d %v", code, body)
	}
	if code, _ := erasureCall(t, ts, http.MethodPost, base, "admin-key", map[string]any{"account_id": account, "confirm_token": "nope", "email": email}); code != http.StatusForbidden {
		t.Fatalf("confirm with the wrong token = %d", code)
	}
	code, confirmed := erasureCall(t, ts, http.MethodPost, base, "admin-key", map[string]any{"account_id": account, "confirm_token": token, "email": email, "reason": "ticket 42"})
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
	code, forced := erasureCall(t, ts, http.MethodPost, base, "admin-key", map[string]any{"account_id": account, "confirm_token": plan["confirm_token"], "email": email, "force": true})
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
	srv, st := newErasureServer(t)
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
	if code, body := erasureCall(t, ts, http.MethodPost, base, "admin-key", map[string]any{"account_id": account, "confirm_token": plan["confirm_token"], "email": email}); code != http.StatusConflict || body["error"].(map[string]any)["type"] != "open_withdrawal" {
		t.Fatalf("confirm with an open withdrawal = %d %v", code, body)
	}
}

// A Privy login of an account that waits for erasure gets 403
// account_pending_deletion instead of a second live account.
func TestPrivyLoginRefusedDuringErasureGrace(t *testing.T) {
	srv, st := newErasureServer(t)
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	user := &store.User{AccountID: "acct-grace", PrivyUserID: "did:privy:grace", Email: "grace@example.com"}
	if err := st.CreateUser(user); err != nil {
		t.Fatal(err)
	}
	token := testkit.NewSessions(t, srv.Server, st).Token(user.AccountID)
	if code, _ := erasureCall(t, ts, http.MethodGet, "/v1/payments/balance", token, nil); code != http.StatusOK {
		t.Fatalf("login before erasure = %d", code)
	}
	ctx := context.Background()
	now := time.Now()
	plan, err := st.PlanAccountErasure(ctx, user.AccountID, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.SaveErasurePlan(ctx, user.AccountID, "admin_key", plan.ErasureCounts, nil, "token", now.Add(time.Minute)); err != nil {
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

// The confirm call must repeat the account ID, so an account without an email
// is never confirmed by two empty strings; it must also repeat the planned
// wallet list. The plan shows each wallet's row counts, and the status lists
// credits refused after the erasure.
func TestAdminErasureConfirmBindsAccountAndWallets(t *testing.T) {
	srv, st := newErasureServer(t)
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	account := "acct-no-email"
	if err := st.CreateUser(&store.User{AccountID: account, PrivyUserID: "did:privy:no-email"}); err != nil {
		t.Fatal(err)
	}
	base := "/v1/admin/accounts/" + account + "/erasure"
	code, plan := erasureCall(t, ts, http.MethodPost, base+"/plan", "admin-key", map[string]any{"wallet_addresses": []string{"0xwallet"}})
	if code != http.StatusOK {
		t.Fatalf("plan = %d %v", code, plan)
	}
	wallets := plan["wallets"].([]any)
	if len(wallets) != 1 || wallets[0].(map[string]any)["address"] != "0xwallet" {
		t.Fatalf("plan wallets = %v", plan["wallets"])
	}
	token := plan["confirm_token"]
	for _, body := range []map[string]any{
		{"confirm_token": token, "email": "", "wallet_addresses": []string{"0xwallet"}},
		{"account_id": "acct-other", "confirm_token": token, "wallet_addresses": []string{"0xwallet"}},
	} {
		if code, resp := erasureCall(t, ts, http.MethodPost, base, "admin-key", body); code != http.StatusBadRequest {
			t.Fatalf("confirm without the account id = %d %v", code, resp)
		}
	}
	if code, resp := erasureCall(t, ts, http.MethodPost, base, "admin-key", map[string]any{"account_id": account, "confirm_token": token, "wallet_addresses": []string{"0xother"}}); code != http.StatusBadRequest || resp["error"].(map[string]any)["type"] != "wallet_mismatch" {
		t.Fatalf("confirm with other wallets = %d %v", code, resp)
	}
	code, resp := erasureCall(t, ts, http.MethodPost, base, "admin-key", map[string]any{"account_id": account, "confirm_token": token, "wallet_addresses": []string{"0xwallet"}, "force": true})
	if code != http.StatusOK || resp["request"].(map[string]any)["state"] != string(store.ErasureErased) {
		t.Fatalf("confirm = %d %v", code, resp)
	}
	if err := st.Credit(account, 9, store.LedgerRefund, "late-refund"); err != nil {
		t.Fatal(err)
	}
	_, status := erasureCall(t, ts, http.MethodGet, base, "admin-key", nil)
	refused := status["refused_credits"].([]any)
	if len(refused) != 1 || refused[0].(map[string]any)["amount_micro_usd"] != float64(9) || st.GetBalance(account) != 0 {
		t.Fatalf("refused credits = %v, balance %d", refused, st.GetBalance(account))
	}
}

// The loop scrubs a request whose grace period ended, at its first pass,
// and clears the in-memory usage history.
func TestAccountErasureLoopScrubsAndForgets(t *testing.T) {
	srv, st := newErasureServer(t)
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
	if _, err := st.SaveErasurePlan(ctx, account, "admin_key", plan.ErasureCounts, nil, "token", past.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	if _, err := st.RequestAccountErasure(ctx, store.ErasureConfirm{AccountID: account, ConfirmToken: "token", Email: "due@example.com", Now: past, Grace: time.Hour}); err != nil {
		t.Fatal(err)
	}
	loopCtx, stop := context.WithCancel(ctx)
	t.Cleanup(stop)
	srv.StartAccountErasureLoop(loopCtx)
	deadline := time.Now().Add(5 * time.Second)
	for {
		req, _, err := st.GetAccountErasure(ctx, account)
		if err == nil && req.State == store.ErasureErased {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("request after the loop = %+v, %v", req, err)
		}
		time.Sleep(10 * time.Millisecond)
	}
	// The usage history is cleared after the scrub commits; wait for it.
	for len(srv.ledger.Usage(account)) != 0 {
		if time.Now().After(deadline) {
			t.Fatalf("in-memory usage after erasure = %v", srv.ledger.Usage(account))
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// EIGENINFERENCE_ERASURE_GRACE sets the grace period that the plan reports.
// Invalid and negative values fall back to the default.
func TestErasureGraceFromEnv(t *testing.T) {
	for _, tc := range []struct {
		value string
		want  time.Duration
	}{
		{"", defaultErasureGrace},
		{"48h", 48 * time.Hour},
		{"0s", 0},
		{"30d", defaultErasureGrace},
		{"-1h", defaultErasureGrace},
	} {
		t.Setenv("EIGENINFERENCE_ERASURE_GRACE", tc.value)
		srv, st := newErasureServer(t)
		ts := httptest.NewServer(srv.Handler())
		account := erasurefixture.UniqueID("acct-grace")
		if err := st.CreateUser(&store.User{AccountID: account, PrivyUserID: "did:privy:" + account}); err != nil {
			t.Fatal(err)
		}
		code, plan := erasureCall(t, ts, http.MethodPost, "/v1/admin/accounts/"+account+"/erasure/plan", "admin-key", nil)
		ts.Close()
		if code != http.StatusOK || plan["grace_seconds"] != float64(tc.want/time.Second) {
			t.Errorf("%q: plan = %d, grace_seconds %v; want %v", tc.value, code, plan["grace_seconds"], tc.want)
		}
	}
}
