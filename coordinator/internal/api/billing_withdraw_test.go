package api

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/eigeninference/coordinator/internal/auth"
	"github.com/eigeninference/coordinator/internal/billing"
	"github.com/eigeninference/coordinator/internal/payments"
	"github.com/eigeninference/coordinator/internal/registry"
	"github.com/eigeninference/coordinator/internal/store"
)

// testWithdrawServer creates a Server with mock billing enabled and returns it
// along with the underlying store. The billing service has Solana in mock mode.
func testWithdrawServer(t *testing.T) (*Server, *store.MemoryStore) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)

	ledger := payments.NewLedger(st)
	billingSvc := billing.NewService(st, ledger, logger, billing.Config{
		SolanaRPCURL:             "http://localhost:8899",
		SolanaCoordinatorAddress: "CoordAddress1111111111111111111111111111111",
		SolanaUSDCMint:           "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
		SolanaMnemonic:           "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
		MockMode:                 true,
	})
	srv.SetBilling(billingSvc)
	return srv, st
}

// withPrivyUser returns a request with the given user set in context, simulating
// Privy authentication without requiring JWT verification.
func withPrivyUser(r *http.Request, user *store.User) *http.Request {
	ctx := context.WithValue(r.Context(), ctxKeyConsumer, user.AccountID)
	ctx = context.WithValue(ctx, auth.CtxKeyUser, user)
	return r.WithContext(ctx)
}

func TestWithdrawRequiresPrivyAuth(t *testing.T) {
	srv, _ := testWithdrawServer(t)

	body := `{"wallet_address":"SomeWallet111111111111111111111111111111111","amount_usd":"5.00"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/solana", strings.NewReader(body))
	// No Privy user in context — simulates API-key-only auth.
	req = req.WithContext(context.WithValue(req.Context(), ctxKeyConsumer, "api-key-user"))
	w := httptest.NewRecorder()

	// Call the handler directly (bypassing requireAuth middleware).
	srv.handleSolanaWithdraw(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Errorf("expected 401, got %d: %s", w.Code, w.Body.String())
	}

	var resp map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	errObj, _ := resp["error"].(map[string]any)
	if errObj == nil {
		t.Fatal("expected error object in response")
	}
	if errObj["type"] != "auth_error" {
		t.Errorf("expected error type auth_error, got %v", errObj["type"])
	}
}

func TestWithdrawWalletMismatch(t *testing.T) {
	srv, _ := testWithdrawServer(t)

	user := &store.User{
		AccountID:           "acct-123",
		PrivyUserID:         "did:privy:abc",
		SolanaWalletAddress: "UserWallet1111111111111111111111111111111111",
	}

	body := `{"wallet_address":"WrongWallet111111111111111111111111111111111","amount_usd":"5.00"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/solana", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()

	srv.handleSolanaWithdraw(w, req)

	if w.Code != http.StatusForbidden {
		t.Errorf("expected 403, got %d: %s", w.Code, w.Body.String())
	}

	var resp map[string]any
	json.Unmarshal(w.Body.Bytes(), &resp)
	errObj, _ := resp["error"].(map[string]any)
	if errObj == nil {
		t.Fatal("expected error object in response")
	}
	if errObj["type"] != "wallet_mismatch" {
		t.Errorf("expected error type wallet_mismatch, got %v", errObj["type"])
	}
	msg, _ := errObj["message"].(string)
	if !strings.Contains(msg, "linked Solana wallet") {
		t.Errorf("expected message about linked wallet, got %q", msg)
	}
}

func TestWithdrawBelowMinimum(t *testing.T) {
	srv, _ := testWithdrawServer(t)

	user := &store.User{
		AccountID:           "acct-123",
		PrivyUserID:         "did:privy:abc",
		SolanaWalletAddress: "UserWallet1111111111111111111111111111111111",
	}

	// $0.50 = 500,000 micro-USD, below the $1.00 minimum
	body := `{"wallet_address":"UserWallet1111111111111111111111111111111111","amount_usd":"0.50"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/solana", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()

	srv.handleSolanaWithdraw(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("expected 400, got %d: %s", w.Code, w.Body.String())
	}

	var resp map[string]any
	json.Unmarshal(w.Body.Bytes(), &resp)
	errObj, _ := resp["error"].(map[string]any)
	if errObj == nil {
		t.Fatal("expected error object in response")
	}
	msg, _ := errObj["message"].(string)
	if !strings.Contains(msg, "minimum withdrawal") {
		t.Errorf("expected message about minimum withdrawal, got %q", msg)
	}
}

func TestWithdrawAutoPopulatesWallet(t *testing.T) {
	srv, st := testWithdrawServer(t)

	user := &store.User{
		AccountID:           "acct-auto",
		PrivyUserID:         "did:privy:auto",
		SolanaWalletAddress: "AutoWallet11111111111111111111111111111111",
	}

	// Seed balance so the withdrawal can succeed.
	st.Credit(user.AccountID, 10_000_000, store.LedgerDeposit, "seed")

	// Omit wallet_address — it should be filled from user.SolanaWalletAddress.
	body := `{"amount_usd":"2.00"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/solana", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()

	srv.handleSolanaWithdraw(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}

	var resp map[string]any
	json.Unmarshal(w.Body.Bytes(), &resp)

	if resp["wallet_address"] != user.SolanaWalletAddress {
		t.Errorf("expected wallet_address %q, got %v", user.SolanaWalletAddress, resp["wallet_address"])
	}
	if resp["status"] != "withdrawn" {
		t.Errorf("expected status withdrawn, got %v", resp["status"])
	}
}

func TestWithdrawSuccessMockMode(t *testing.T) {
	srv, st := testWithdrawServer(t)

	user := &store.User{
		AccountID:           "acct-success",
		PrivyUserID:         "did:privy:success",
		SolanaWalletAddress: "SuccessWallet111111111111111111111111111111",
	}

	// Seed balance.
	st.Credit(user.AccountID, 50_000_000, store.LedgerDeposit, "seed")

	body := `{"wallet_address":"SuccessWallet111111111111111111111111111111","amount_usd":"5.00"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/solana", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()

	srv.handleSolanaWithdraw(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}

	var resp map[string]any
	json.Unmarshal(w.Body.Bytes(), &resp)

	if resp["status"] != "withdrawn" {
		t.Errorf("expected status withdrawn, got %v", resp["status"])
	}
	if resp["chain"] != "solana" {
		t.Errorf("expected chain solana, got %v", resp["chain"])
	}
	if resp["wallet_address"] != user.SolanaWalletAddress {
		t.Errorf("expected wallet %q, got %v", user.SolanaWalletAddress, resp["wallet_address"])
	}

	// amount_micro_usd should be 5_000_000
	amountMicro, ok := resp["amount_micro_usd"].(float64)
	if !ok || int64(amountMicro) != 5_000_000 {
		t.Errorf("expected amount_micro_usd 5000000, got %v", resp["amount_micro_usd"])
	}

	// tx_signature should be present (mock mode generates one)
	txSig, _ := resp["tx_signature"].(string)
	if txSig == "" {
		t.Error("expected non-empty tx_signature in mock mode")
	}

	// Balance should be reduced: 50_000_000 - 5_000_000 = 45_000_000
	balanceMicro, ok := resp["balance_micro_usd"].(float64)
	if !ok || int64(balanceMicro) != 45_000_000 {
		t.Errorf("expected remaining balance 45000000, got %v", resp["balance_micro_usd"])
	}
}
